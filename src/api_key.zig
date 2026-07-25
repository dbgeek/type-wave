//! api_key.zig — the **Key Holder**: the daemon's one plaintext copy of the OpenAI API
//! key, and the only thing that decides when a copy stops existing (#254).
//!
//! # Why a module, and not two lines in the supervisor's facts pass
//!
//! The facts pass needs one fact — *is a key configured?* — and the Backend Router needs
//! one value — *the key to connect with* — and both come from the same read of the login
//! keychain. So the poll loaded a fresh copy every ~3 s tick and parked it for a connect
//! that might never come, overwriting the previous copy without freeing it. Whenever a key
//! was configured but the Transcription Session was not up — network down, connect failing,
//! or the daemon still parked on Input Monitoring — that was a new plaintext copy of the
//! secret every few seconds, forever. An hour in that state leaves on the order of a
//! thousand of them scattered across the heap, and `free` alone would not have helped: it
//! returns the bytes to the allocator still holding the secret, for whatever later reads
//! that memory — a crash report, a core dump, a swapped page.
//!
//! Both halves of that are lifetime questions, and lifetime questions belong to one owner.
//! The Holder is it: exactly one copy exists at a time, every copy it finishes with is
//! zeroed before it is released, and the one moment a copy legitimately outlives the Holder
//! — a live Session retaining it for its reconnects — is a named hand-off rather than a
//! silent aliasing.
//!
//! # What stays deliberately un-scrubbed
//!
//! A connected Transcription Session holds its key for the process lifetime, the same
//! process-lifetime stance Settings Snapshots take. `handOff` is where that ownership
//! moves, so no later `refresh` or `drop` can pull the slice out from under a live holder.
//! The menu's key-entry path transits AppKit strings that cannot be scrubbed from this
//! code; that is inherent to `NSSecureTextField`, not something this owner can fix.
//!
//! Pure of the OS behind the `Source` seam, in the `grants.zig` / `undo.zig` idiom: the
//! daemon supplies the real keychain-then-env loader, and the lifetime rule is driven here
//! against a fake that hands out counted copies.

const std = @import("std");

/// Zero a key copy, then release it. Never `free` a key without this: the allocator hands
/// the block to the next caller with the secret still in it, and a freed block is exactly
/// what a core dump or a swapped page preserves. `secureZero` is the write the optimiser
/// is not allowed to elide — a plain `@memset` on a dying allocation is dead-store-eliminated.
pub fn scrub(gpa: std.mem.Allocator, key: [:0]u8) void {
    std.crypto.secureZero(u8, key);
    gpa.free(key);
}

/// The Holder's seam: one load of the secret from wherever the daemon keeps it (process
/// env override, then the login keychain, then the legacy env-file migration — config.zig).
/// Asserted by name here and invoked by `Holder` itself below, so a production adapter can
/// never skip the check.
pub fn assertSource(comptime Source: type) void {
    if (!@hasDecl(Source, "load"))
        @compileError("type '" ++ @typeName(Source) ++ "' is not a Key Source: missing method 'load'");
}

pub fn Holder(comptime Source: type) type {
    assertSource(Source);
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        source: Source,

        /// The one copy. Non-null only between a `refresh` that found a key and whichever
        /// comes first: the `handOff` that gives it to a Session, the next `refresh`, or
        /// the `drop` that ends its life unread.
        copy: ?[:0]u8 = null,

        pub fn init(gpa: std.mem.Allocator, source: Source) Self {
            return .{ .gpa = gpa, .source = source };
        }

        /// This tick could connect: scrub whatever the last tick loaded and nobody took,
        /// then load one fresh copy. Returns whether a key is now held — the Configuration
        /// Phase's *is a key configured?* fact, answered by the same read that produces the
        /// value, so the two can never disagree.
        pub fn refresh(self: *Self) bool {
            self.drop();
            self.copy = self.source.load(self.gpa);
            return self.copy != null;
        }

        /// This tick will not connect — the Session is already up, or the selected backend
        /// is the local one. A copy nobody is going to take must not sit in the heap
        /// waiting for a connect that is not coming.
        pub fn drop(self: *Self) void {
            const held = self.copy orelse return;
            self.copy = null;
            scrub(self.gpa, held);
        }

        /// Borrow the copy for a connect attempt. Still the Holder's until `handOff`, so a
        /// connect that fails leaves nothing behind: the next `refresh` scrubs it.
        pub fn borrow(self: *const Self) ?[:0]const u8 {
            return self.copy;
        }

        /// The borrow became a Session's. The Session retains the slice for the reconnects
        /// it may make for the rest of the process's life, so ownership moves out here —
        /// called only once a live holder provably exists, i.e. after `connect` returned.
        pub fn handOff(self: *Self) void {
            self.copy = null;
        }
    };
}

// ---- tests: the lifetime rule, driven against a counted fake source ------------------

const testing = std.testing;

/// Hands out a fresh copy of a fixed key per `load`, counting them, so a test can assert
/// how many times the daemon went to the keychain. `absent` drives the not-configured arm.
const FakeSource = struct {
    absent: bool = false,
    loads: usize = 0,

    const secret = "sk-test-0123456789";

    pub fn load(self: *FakeSource, gpa: std.mem.Allocator) ?[:0]u8 {
        self.loads += 1;
        if (self.absent) return null;
        return gpa.dupeSentinel(u8, secret, 0) catch null;
    }
};

const FakeHolder = Holder(FakeSource);

test "repeated facts passes with no connect hold exactly one copy" {
    // Finding 9's shape: a key is configured, the Session never comes up, and the poll
    // keeps asking. testing.allocator fails the test on any leaked copy, so this asserts
    // the unconsumed copy is released and not merely overwritten.
    var holder = FakeHolder.init(testing.allocator, .{});
    for (0..1000) |_| try testing.expect(holder.refresh());
    try testing.expectEqual(@as(usize, 1000), holder.source.loads);
    holder.drop();
    try testing.expect(holder.borrow() == null);
}

test "a copy the Holder finishes with is zeroed, not just freed" {
    // Read the secret back out of the allocator's own backing store after the release: a
    // fixed buffer allocator never clobbers a freed block, so whatever is left there is
    // exactly what a core dump or the next allocation would see.
    var backing: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    var holder = Holder(FakeSource).init(fba.allocator(), .{});
    try testing.expect(holder.refresh());
    try testing.expect(std.mem.indexOf(u8, &backing, FakeSource.secret) != null);

    holder.drop();
    try testing.expect(std.mem.indexOf(u8, &backing, FakeSource.secret) == null);
}

test "a refresh scrubs the copy the previous one left" {
    var backing: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    // A source whose second copy differs, so the first one's bytes are identifiable after
    // the second load — a FixedBufferAllocator reuses the block, which would hide the
    // difference, so the second key is deliberately longer and lands elsewhere.
    const Growing = struct {
        n: usize = 0,
        pub fn load(self: *@This(), gpa: std.mem.Allocator) ?[:0]u8 {
            self.n += 1;
            return gpa.dupeSentinel(u8, if (self.n == 1) "sk-first" else "sk-second-and-longer", 0) catch null;
        }
    };
    var holder = Holder(Growing).init(fba.allocator(), .{});

    try testing.expect(holder.refresh());
    try testing.expect(std.mem.indexOf(u8, &backing, "sk-first") != null);
    try testing.expect(holder.refresh());
    try testing.expect(std.mem.indexOf(u8, &backing, "sk-first") == null);

    holder.drop();
}

test "handOff moves ownership out, so no later drop reaches a live Session's key" {
    var holder = FakeHolder.init(testing.allocator, .{});
    try testing.expect(holder.refresh());

    const session_key = holder.borrow().?;
    holder.handOff();
    try testing.expect(holder.borrow() == null);

    // Neither of these may touch the slice the Session now owns — a double free or a
    // scrubbed-out Authorization header would surface here.
    holder.drop();
    try testing.expect(holder.refresh()); // the next tick loads its own, separate copy
    holder.drop();
    try testing.expectEqualStrings(FakeSource.secret, session_key);

    testing.allocator.free(session_key); // the Session's copy, released by the Session
}

test "an absent key holds nothing and reports the not-configured fact" {
    var holder = FakeHolder.init(testing.allocator, .{ .absent = true });
    try testing.expect(!holder.refresh());
    try testing.expect(holder.borrow() == null);
    holder.drop(); // a no-op on an empty Holder, not a null deref
}
