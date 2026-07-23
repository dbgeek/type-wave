//! recent_insertions.zig — the daemon-owned Recent Insertions ring (ADR-0006,
//! docs/recent-insertions-spec.md §3).
//!
//! A standalone, **heap-free** buffer of the last N=20 Insertion Records, newest-first. The
//! Coordinator writes it through the write-only recorder seam at `onInserted` — the
//! Coordinator holds `coordinator.mu` (outer) and this ring briefly takes its own
//! `os_unfair_lock` (inner) to memcpy the finished record in. The menu (later work) reads it
//! via a snapshot-copy under the **same lock, taken alone**.
//!
//! # Locking — the leaf-lock contract (ADR-0006)
//!
//! `lock` is used strictly as a **leaf lock**: it is the inner of the Coordinator's write
//! path and the sole lock of the menu's read path. It **never wraps `coordinator.mu`** — no
//! lock-ordering cycle, mirroring the codebase's "`out_mu` never nests with `write_mu`" rule
//! (`session.zig`). Both `record` and `snapshot` are just a bounded memcpy under the lock, so
//! neither the state machine nor the menu ever stalls the other.
//!
//! # Footprint
//!
//! Fixed inline string buffers, zero heap, no leak: `capacity` × (`inserted` + `raw` + small
//! fields) ≈ 20 × ~16.6 KB ≈ ~330 KB, bounded and consistent with the feature's
//! in-memory-only stance (spec §2.1). Cleared on daemon quit; never serialized.

const std = @import("std");
const coord = @import("coordinator.zig");

/// N = 20, fixed (spec §2.3): the ring keeps the newest 20 and evicts the oldest on the 21st.
pub const capacity = 20;

/// One stored Insertion Record — the authoritative, text-bearing entry the ring owns. Unlike
/// `coord.InsertionRecord` (borrowed slices crossing the seam) this holds its own inline
/// copies, sized like the Coordinator's `pending` / `raw` buffers so any transcript fits.
pub const Record = struct {
    inserted_bytes: [8192]u8 = undefined,
    inserted_len: usize = 0,
    raw_bytes: [8192]u8 = undefined,
    raw_len: usize = 0,
    has_raw: bool = false,
    timestamp: i64 = 0,
    outcome: coord.InsertResult = .ok,
    focused_app: ?coord.AppIdentity = null,

    /// The with-space bytes that hit the cursor.
    pub fn inserted(self: *const Record) []const u8 {
        return self.inserted_bytes[0..self.inserted_len];
    }
    /// The trimmed pre-Rewrite Final Transcript, or null when it equals `inserted`.
    pub fn raw(self: *const Record) ?[]const u8 {
        return if (self.has_raw) self.raw_bytes[0..self.raw_len] else null;
    }
};

/// A self-contained `os_unfair_lock` leaf lock — same primitive the Coordinator, rewrite
/// adapter, and HUD use; zero-initializable so the ring builds for free.
const Lock = struct {
    lock_: OsUnfairLock = .{},
    fn lock(self: *Lock) void {
        os_unfair_lock_lock(&self.lock_);
    }
    fn unlock(self: *Lock) void {
        os_unfair_lock_unlock(&self.lock_);
    }
};
const OsUnfairLock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *OsUnfairLock) void;
extern "c" fn os_unfair_lock_unlock(lock: *OsUnfairLock) void;

pub const Ring = struct {
    mu: Lock = .{},
    /// A circular buffer: writes advance `head`; the newest live entry is at `head - 1`.
    buf: [capacity]Record = undefined,
    head: usize = 0,
    count: usize = 0,

    /// The write-only recorder seam (ADR-0006). Runs under `coordinator.mu`; must not block.
    /// Copies the borrowed record into the newest slot under the leaf lock; on the 21st write
    /// the oldest entry is overwritten (evicted) for free.
    pub fn record(self: *Ring, rec: coord.InsertionRecord) void {
        self.mu.lock();
        defer self.mu.unlock();
        const slot = &self.buf[self.head];
        const n = @min(rec.inserted.len, slot.inserted_bytes.len);
        @memcpy(slot.inserted_bytes[0..n], rec.inserted[0..n]);
        slot.inserted_len = n;
        if (rec.raw) |raw| {
            const m = @min(raw.len, slot.raw_bytes.len);
            @memcpy(slot.raw_bytes[0..m], raw[0..m]);
            slot.raw_len = m;
            slot.has_raw = true;
        } else {
            slot.raw_len = 0;
            slot.has_raw = false;
        }
        slot.timestamp = rec.timestamp;
        slot.outcome = rec.outcome;
        slot.focused_app = rec.focused_app;
        self.head = (self.head + 1) % capacity;
        if (self.count < capacity) self.count += 1;
    }

    /// The number of live records.
    pub fn len(self: *Ring) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.count;
    }

    /// Snapshot-copy the live records **newest-first** into `out`, returning the count. The
    /// menu's sole read path — taken under the leaf lock alone, never while `coordinator.mu`
    /// is held (ADR-0006). `out` is a fixed `[capacity]Record`; only `[0..count]` is written.
    pub fn snapshot(self: *Ring, out: *[capacity]Record) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            // newest is head-1, then head-2, … wrapping around the circular buffer.
            const idx = (self.head + capacity - 1 - i) % capacity;
            out[i] = self.buf[idx];
        }
        return self.count;
    }
};

// ============================================================================
// Tests — the ring's retention, ordering, and self-contained locking.
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn plain(text: []const u8, outcome: coord.InsertResult) coord.InsertionRecord {
    return .{ .inserted = text, .raw = null, .timestamp = 0, .outcome = outcome, .focused_app = null };
}

test "an empty ring reports zero and snapshots nothing" {
    var ring = Ring{};
    try expectEqual(@as(usize, 0), ring.len());
    var out: [capacity]Record = undefined;
    try expectEqual(@as(usize, 0), ring.snapshot(&out));
}

test "records the full Insertion Record and reads it back" {
    var ring = Ring{};
    ring.record(.{
        .inserted = "At 18:00 ",
        .raw = "at 20:00 no 18:00",
        .timestamp = 1234,
        .outcome = .degraded,
        .focused_app = coord.AppIdentity.init("com.apple.Notes", "Notes"),
    });
    var out: [capacity]Record = undefined;
    try expectEqual(@as(usize, 1), ring.snapshot(&out));
    try expectEqualStrings("At 18:00 ", out[0].inserted());
    try expect(out[0].raw() != null);
    try expectEqualStrings("at 20:00 no 18:00", out[0].raw().?);
    try expectEqual(@as(i64, 1234), out[0].timestamp);
    try expectEqual(coord.InsertResult.degraded, out[0].outcome);
    try expect(out[0].focused_app != null);
    try expectEqualStrings("Notes", out[0].focused_app.?.displayName());
}

test "a record with no raw reads back null" {
    var ring = Ring{};
    ring.record(plain("hello ", .ok));
    var out: [capacity]Record = undefined;
    _ = ring.snapshot(&out);
    try expect(out[0].raw() == null);
}

test "entries come back newest-first" {
    var ring = Ring{};
    ring.record(plain("first ", .ok));
    ring.record(plain("second ", .ok));
    ring.record(plain("third ", .ok));
    var out: [capacity]Record = undefined;
    try expectEqual(@as(usize, 3), ring.snapshot(&out));
    try expectEqualStrings("third ", out[0].inserted()); // newest
    try expectEqualStrings("second ", out[1].inserted());
    try expectEqualStrings("first ", out[2].inserted()); // oldest
}

test "the ring keeps the newest 20 and evicts the oldest on the 21st" {
    var ring = Ring{};
    var i: usize = 0;
    while (i < capacity + 1) : (i += 1) { // 21 records: e0 … e20
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "e{d}", .{i}) catch unreachable;
        ring.record(plain(text, .ok));
    }
    try expectEqual(@as(usize, capacity), ring.len()); // capped at 20, not 21
    var out: [capacity]Record = undefined;
    try expectEqual(@as(usize, capacity), ring.snapshot(&out));
    try expectEqualStrings("e20", out[0].inserted()); // newest
    try expectEqualStrings("e1", out[capacity - 1].inserted()); // e0 was evicted
}

test "the ring is heap-free: a fixed, bounded inline footprint" {
    // No allocator is threaded anywhere in the API — the buffers are inline arrays. The
    // footprint is a compile-time constant, bounded near the spec's ~330 KB estimate.
    try expect(@sizeOf(Ring) <= capacity * 20 * 1024);
}

test "record then snapshot on the same ring does not self-deadlock (leaf lock is not re-entrant)" {
    // os_unfair_lock deadlocks on recursive acquisition; that this completes proves the two
    // seams each take the lock in a bounded, non-nested critical section.
    var ring = Ring{};
    ring.record(plain("one ", .ok));
    var out: [capacity]Record = undefined;
    _ = ring.snapshot(&out);
    ring.record(plain("two ", .ok));
    try expectEqual(@as(usize, 2), ring.len());
}
