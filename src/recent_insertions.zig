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

/// The inline capacity of each record's `inserted` / `raw` byte buffer — single-homed so the
/// menu's on-demand fetch buffer (`textForStamp`'s caller) can size itself to match and never
/// truncate. The trimmed `raw` is capped here at the source (`coordinator.raw`), and the
/// with-space `inserted` reaches at most this many bytes too (see `Record`).
pub const max_bytes = 8192;

/// One stored Insertion Record — the authoritative, text-bearing entry the ring owns. Unlike
/// `coord.InsertionRecord` (borrowed slices crossing the seam) this holds its own inline
/// copies. Both buffers are `[8192]` and hold the whole transcript with no loss: the trimmed
/// `raw` is capped at 8192 bytes at the source (`coordinator.raw`), and the with-space
/// `inserted` reaches at most 8192 bytes too — the Coordinator's `pending` scratch buffer is
/// `[8193]` only to give `ensureTrailingSpace` room for content + space + a NUL it doesn't
/// store, so the returned slice never exceeds 8192.
pub const Record = struct {
    inserted_bytes: [max_bytes]u8 = undefined,
    inserted_len: usize = 0,
    raw_bytes: [max_bytes]u8 = undefined,
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

/// A self-contained `os_unfair_lock` wrapper — the same `Mutex` shape `coordinator.zig` uses,
/// here as the ring's leaf lock; zero-initializable so the ring builds for free.
const Mutex = struct {
    lock_: OsUnfairLock = .{},
    fn lock(self: *Mutex) void {
        os_unfair_lock_lock(&self.lock_);
    }
    fn unlock(self: *Mutex) void {
        os_unfair_lock_unlock(&self.lock_);
    }
};
const OsUnfairLock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *OsUnfairLock) void;
extern "c" fn os_unfair_lock_unlock(lock: *OsUnfairLock) void;

pub const Ring = struct {
    mu: Mutex = .{},
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

    /// Copy the **with-space `inserted` bytes** of the record whose capture `stamp` matches into
    /// `out`, under the leaf lock, returning the number of bytes written (0 when no live record
    /// has that stamp — e.g. it was evicted since the menu's projection was taken). This is the
    /// on-demand text fetch (spec §4.1 / §5): the menu's reveal path reads the `inserted` bytes
    /// straight from the authoritative ring under its lock, never from the text-free projected
    /// `Snapshot`. Keyed by the stable `timestamp` — the same identity the menu's reveal state
    /// uses — so a concurrent Insertion shifting the newest-first order can never return a
    /// neighbouring entry's text against this row's metadata; a stale stamp just yields 0.
    /// Truncates to `out.len`; the caller sizes `out` to `max_bytes` so no loss occurs.
    pub fn textForStamp(self: *Ring, stamp: i64, out: []u8) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + capacity - 1 - i) % capacity;
            const rec = &self.buf[idx];
            if (rec.timestamp == stamp) {
                const n = @min(rec.inserted_len, out.len);
                @memcpy(out[0..n], rec.inserted_bytes[0..n]);
                return n;
            }
        }
        return 0;
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

fn stamped(text: []const u8, ts: i64) coord.InsertionRecord {
    return .{ .inserted = text, .raw = null, .timestamp = ts, .outcome = .ok, .focused_app = null };
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

test "textForStamp fetches the matching entry's inserted bytes by timestamp" {
    var ring = Ring{};
    ring.record(stamped("first ", 100));
    ring.record(stamped("second ", 200));
    ring.record(stamped("third ", 300));
    var out: [max_bytes]u8 = undefined;
    try expectEqual(@as(usize, 6), ring.textForStamp(300, &out)); // "third "
    try expectEqualStrings("third ", out[0..6]);
    try expectEqualStrings("second ", out[0..ring.textForStamp(200, &out)]);
    try expectEqualStrings("first ", out[0..ring.textForStamp(100, &out)]);
}

test "textForStamp returns 0 when no live record carries that stamp (empty or evicted)" {
    var ring = Ring{};
    var out: [max_bytes]u8 = undefined;
    try expectEqual(@as(usize, 0), ring.textForStamp(100, &out)); // empty ring
    ring.record(stamped("only ", 100));
    try expectEqual(@as(usize, 0), ring.textForStamp(999, &out)); // unknown stamp
    try expectEqual(@as(usize, 5), ring.textForStamp(100, &out));
}

test "textForStamp does not return an evicted entry's bytes after the oldest rolls off" {
    var ring = Ring{};
    var i: usize = 0;
    while (i < capacity + 1) : (i += 1) ring.record(stamped("x ", @intCast(i))); // stamps 0..20; 0 evicted
    var out: [max_bytes]u8 = undefined;
    try expectEqual(@as(usize, 0), ring.textForStamp(0, &out)); // evicted → no text
    try expectEqual(@as(usize, 2), ring.textForStamp(20, &out)); // newest still resolves
}

test "textForStamp truncates to the caller's buffer without overrun" {
    var ring = Ring{};
    ring.record(stamped("abcdefgh", 7));
    var small: [3]u8 = undefined;
    try expectEqual(@as(usize, 3), ring.textForStamp(7, &small));
    try expectEqualStrings("abc", small[0..3]);
}

test "textForStamp returns the with-space inserted, not the pre-Rewrite raw" {
    var ring = Ring{};
    ring.record(.{
        .inserted = "At 18:00 ",
        .raw = "at 20:00 no 18:00",
        .timestamp = 1,
        .outcome = .degraded,
        .focused_app = null,
    });
    var out: [max_bytes]u8 = undefined;
    try expectEqualStrings("At 18:00 ", out[0..ring.textForStamp(1, &out)]);
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
