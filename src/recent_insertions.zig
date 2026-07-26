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
const grapheme = @import("grapheme.zig");

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
    /// Set true by `markUndone` after a committed Undo (#225, single-shot model): the record
    /// is **kept and flagged**, not removed, so a second `⌃⌘⌫` on an already-undone newest
    /// record refuses instead of eating earlier text, and the masked View renders it dimmed
    /// where a re-insert acts as a redo. Explicitly reset in `record` on slot reuse so an
    /// evicted-then-reused slot never inherits a stale flag.
    undone: bool = false,
    /// One `⌫` per extended grapheme cluster of `inserted` (#220), counted at `record` time —
    /// the one moment the bytes are guaranteed in hand, which is what lets a **withheld**
    /// record still be an Undo target (#286). Zero for a degenerate record.
    clusters: usize = 0,
    /// The Utterance was spoken while Secure Event Input was held (#286), so its words are
    /// presumed a secret and **no transcript bytes are stored**: `inserted_len` and `raw_len`
    /// are both zero however long the transcript was. The record itself is kept — the row says
    /// so, and `clusters` keeps it deletable — but reveal, Copy and Re-insert have nothing to
    /// serve. Reset in `record` on slot reuse, like `undone`.
    withheld: bool = false,

    /// The with-space bytes that hit the cursor — empty for a `withheld` record, which stores
    /// none.
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

/// What `newestForUndo` hands the Undo trigger: **how many clusters to delete**, the record's
/// stored App Identity for the focus gate (#224), and — for the single-shot model (#225) — its
/// stable `timestamp` (so a committed Undo can flag *this* record via `markUndone`) and whether
/// it is `undone` already (so a second `⌃⌘⌫` on an already-undone newest record refuses instead
/// of eating earlier text).
///
/// It carries no transcript bytes, and the Undo path reads none: deleting text needs its
/// *count*, never its content (#286). Counting at `record` time is what makes that available —
/// and it is what lets a withheld record, which stores no bytes at all, still be deleted.
pub const UndoTarget = struct {
    /// Extended grapheme clusters to backspace — `Record.clusters`, counted where the bytes
    /// were.
    clusters: usize,
    focused_app: ?coord.AppIdentity,
    timestamp: i64,
    undone: bool,
    /// Whether this record's bytes ever reached the cursor. The ring retains records that
    /// never inserted — `.failed` (the mechanism could not post) and `.refused` (the Focused
    /// Target gate stopped the paste) — because those are the recovery cases the Recent
    /// Insertions submenu exists for (§2.2). But Undo deletes by *count*: backspacing N
    /// clusters for text that was never placed eats N clusters of whatever the user did write.
    /// So the outcome travels with the target and the Undo Runner refuses on it.
    landed: bool,
};

/// One record's cluster count, from the bytes it is being built out of. The single home of the
/// count, called under the leaf lock at `record` — the same bounded single pass over the same
/// bytes the memcpy beside it makes, so it keeps the ADR-0006 promise that a write does not
/// block the machine.
fn clusterCount(inserted: []const u8) usize {
    return grapheme.graphemeCount(inserted);
}

/// Did this outcome put bytes at the cursor? The single home of that reading, so a future
/// `InsertResult` variant has to answer the question rather than default into "deletable".
fn landed(outcome: coord.InsertResult) bool {
    return switch (outcome) {
        .ok, .degraded => true,
        .failed, .refused => false,
    };
}

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
        // Counted before anything is withheld, from the bytes the Coordinator is handing over:
        // this is the only moment they are in hand for a withheld record (#286), and the count
        // is what Undo needs — never the words. Counted over the **capped** slice, so a
        // transcript too long for the record can never authorize backspacing past what the ring
        // kept (the cap does not bind in practice — an `inserted` reaches at most `max_bytes` —
        // but the count and the stored bytes must not be able to disagree).
        const stored = @min(rec.inserted.len, slot.inserted_bytes.len);
        slot.clusters = clusterCount(rec.inserted[0..stored]);
        slot.withheld = rec.withheld;
        // An Utterance spoken under a held Secure Event Input stores **no** transcript bytes,
        // neither the inserted form nor the pre-Rewrite raw one. The row still exists and still
        // says what happened; there is simply nothing to reveal, copy or replay.
        const n = if (rec.withheld) 0 else stored;
        @memcpy(slot.inserted_bytes[0..n], rec.inserted[0..n]);
        slot.inserted_len = n;
        const raw_in: ?[]const u8 = if (rec.withheld) null else rec.raw;
        if (raw_in) |raw| {
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
        // Prefactor (#225): `record` does not reset every field on slot reuse, so a reused
        // slot could otherwise inherit a stale `undone` from the evicted record it overwrites.
        // Reset it explicitly — a fresh Insertion is never pre-undone.
        slot.undone = false;
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
    ///
    /// A **withheld** record (#286) yields 0 for the same reason an evicted stamp does: it
    /// holds no bytes. That is the floor under the menu's disabled reveal/Copy/Re-insert rather
    /// than the gate itself — the gate is the row's own `text_available` flag.
    pub fn textForStamp(self: *Ring, stamp: i64, out: []u8) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.indexForStamp(stamp) orelse return 0;
        const rec = &self.buf[idx];
        const n = @min(rec.inserted_len, out.len);
        @memcpy(out[0..n], rec.inserted_bytes[0..n]);
        return n;
    }

    /// The circular-buffer index of the live record with capture `stamp`, walking newest-first,
    /// or null when none matches (empty ring or the entry was evicted). The single home of the
    /// stamp→slot lookup shared by `textForStamp` and `setUndone`. **Assumes the leaf lock is
    /// already held** — every caller takes `self.mu` for its own bounded critical section, so
    /// this reads `head`/`count`/`buf` without locking (it must not, or it would deadlock the
    /// non-re-entrant `os_unfair_lock`).
    fn indexForStamp(self: *Ring, stamp: i64) ?usize {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + capacity - 1 - i) % capacity;
            if (self.buf[idx].timestamp == stamp) return idx;
        }
        return null;
    }

    /// The number of live records.
    pub fn len(self: *Ring) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.count;
    }

    /// The newest live record's **deletion target** — its cluster count, stored `focused_app`,
    /// stamp and flags, read under one hold of the leaf lock; null when the ring is empty. The
    /// Undo trigger's newest-record resolution (undo-spec, #223): the recovery chord targets
    /// the single newest Insertion only (#212), so this reads the head-1 entry straight from
    /// the authoritative ring rather than snapshotting all N and taking `[0]`. Count and
    /// identity come from the same record atomically — a concurrent Insertion between two
    /// separate reads could otherwise pair one record's length with another's app, defeating
    /// the focus gate (#224).
    ///
    /// It hands over **no transcript bytes** (#286): a deletion needs the count, so the count
    /// is the target, and the caller needs no buffer at all.
    pub fn newestForUndo(self: *Ring) ?UndoTarget {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count == 0) return null;
        const idx = (self.head + capacity - 1) % capacity;
        const rec = &self.buf[idx];
        return .{
            .clusters = rec.clusters,
            .focused_app = rec.focused_app,
            .timestamp = rec.timestamp,
            .undone = rec.undone,
            .landed = landed(rec.outcome),
        };
    }

    /// Flag the record with capture `stamp` as undone, walking newest-first under the leaf
    /// lock (#225). The Undo trigger path calls this on a committed Undo — the deletion
    /// mechanism (#222) deliberately never touches the ring, so the `undone` bookkeeping is
    /// the trigger's. Keyed by the stable `timestamp` (the same identity `textForStamp` and
    /// the menu's reveal use) so a concurrent Insertion shifting the newest-first order can
    /// never flag a neighbouring record; a stale stamp is a silent no-op. Undo pushes **no**
    /// new ring entry — the record is kept and flagged, never removed.
    pub fn markUndone(self: *Ring, stamp: i64) void {
        self.setUndone(stamp, true);
    }

    /// Clear the undone flag on the record with capture `stamp` — the redo edge (#225): a
    /// re-insert of an undone entry restores its text, so the masked View must stop rendering
    /// it dimmed. Same newest-first, stamp-keyed, leaf-locked walk as `markUndone`; a stamp
    /// that is missing or already un-undone is a silent no-op.
    pub fn clearUndone(self: *Ring, stamp: i64) void {
        self.setUndone(stamp, false);
    }

    fn setUndone(self: *Ring, stamp: i64, value: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.indexForStamp(stamp)) |idx| self.buf[idx].undone = value;
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

test "newestForUndo reports the newest record's cluster count, trailing space included" {
    var ring = Ring{};
    ring.record(plain("first ", .ok));
    ring.record(plain("second ", .ok));
    ring.record(plain("newest ", .ok));
    const target = ring.newestForUndo().?;
    try expectEqual(@as(usize, 7), target.clusters); // "newest " incl. trailing space
}

test "the count is clusters, not bytes or codepoints" {
    // The whole reason the ring counts rather than the Undo Runner: whatever it hands over must
    // already be in `⌫` units. A ZWJ family emoji plus a space is 25 + 1 bytes, 7 codepoints,
    // 2 clusters (#220).
    var ring = Ring{};
    ring.record(plain("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} ", .ok));
    try expectEqual(@as(usize, 2), ring.newestForUndo().?.clusters);
}

test "newestForUndo returns null on an empty ring (the Undo trigger's no-target case)" {
    var ring = Ring{};
    try expect(ring.newestForUndo() == null);
}

test "newestForUndo carries the newest record's stored App Identity for the focus gate" {
    var ring = Ring{};
    ring.record(.{
        .inserted = "older ",
        .raw = null,
        .timestamp = 0,
        .outcome = .ok,
        .focused_app = coord.AppIdentity.init("com.apple.Notes", "Notes"),
    });
    ring.record(.{
        .inserted = "newest text ",
        .raw = null,
        .timestamp = 0,
        .outcome = .ok,
        .focused_app = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack"),
    });
    const target = ring.newestForUndo().?;
    // The identity and the count come from the same (newest) record, read atomically.
    try expectEqual(@as(usize, 12), target.clusters);
    try expectEqualStrings("com.tinyspeck.slackmacgap", target.focused_app.?.bundleId());
    try expectEqualStrings("Slack", target.focused_app.?.displayName());
}

test "newestForUndo passes a record's null App Identity through as null (fail-closed input)" {
    var ring = Ring{};
    ring.record(plain("no hint ", .ok)); // plain() stores focused_app = null
    try expect(ring.newestForUndo().?.focused_app == null);
}

test "newestForUndo follows the newest across an eviction" {
    var ring = Ring{};
    var i: usize = 0;
    while (i < capacity + 1) : (i += 1) { // 21 records: e0 (evicted) … e20 (newest)
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "e{d} ", .{i}) catch unreachable;
        var rec = plain(text, .ok);
        rec.timestamp = @intCast(i);
        ring.record(rec);
    }
    const target = ring.newestForUndo().?;
    try expectEqual(@as(i64, capacity), target.timestamp); // e20's stamp, not e19's
    try expectEqual(@as(usize, 4), target.clusters); // "e20 "
}

test "the undo count comes from the with-space inserted, not the pre-Rewrite raw" {
    var ring = Ring{};
    ring.record(.{
        .inserted = "At 18:00 ",
        .raw = "at 20:00 no 18:00",
        .timestamp = 1,
        .outcome = .degraded,
        .focused_app = null,
    });
    // 9, not the raw's 17: Undo deletes what landed at the cursor.
    try expectEqual(@as(usize, 9), ring.newestForUndo().?.clusters);
}

test "a transcript longer than the record counts only the clusters the ring kept" {
    // The cap does not bind in practice (an `inserted` reaches at most `max_bytes`), but the
    // count and the stored bytes must not be able to disagree: a count over the uncapped slice
    // would authorize backspacing past text the ring never held.
    var ring = Ring{};
    var long: [max_bytes + 64]u8 = undefined;
    @memset(&long, 'a');
    ring.record(plain(&long, .ok));
    try expectEqual(@as(usize, max_bytes), ring.newestForUndo().?.clusters);
}

test "a fresh record starts un-undone (default false)" {
    var ring = Ring{};
    ring.record(stamped("hello ", 1));
    try expect(!ring.newestForUndo().?.undone);
}

test "markUndone flips the flag on the matching stamp only, leaving the others untouched" {
    var ring = Ring{};
    ring.record(stamped("first ", 100));
    ring.record(stamped("second ", 200));
    ring.record(stamped("third ", 300));

    ring.markUndone(200);

    var out: [capacity]Record = undefined;
    _ = ring.snapshot(&out); // newest-first: third(300), second(200), first(100)
    try expect(!out[0].undone); // 300 untouched
    try expect(out[1].undone); //  200 flipped
    try expect(!out[2].undone); // 100 untouched
}

test "markUndone on an unknown or evicted stamp is a silent no-op" {
    var ring = Ring{};
    ring.record(stamped("only ", 100));
    ring.markUndone(999); // never recorded
    var out: [capacity]Record = undefined;
    _ = ring.snapshot(&out);
    try expect(!out[0].undone);
}

test "newestForUndo reports the newest record's undone flag (the trigger's refuse input)" {
    var ring = Ring{};
    ring.record(stamped("target ", 7));
    try expect(!ring.newestForUndo().?.undone);
    ring.markUndone(7);
    try expect(ring.newestForUndo().?.undone);
    try expectEqual(@as(i64, 7), ring.newestForUndo().?.timestamp);
}

test "clearUndone un-flags a record (the redo edge) so it stops rendering dimmed" {
    var ring = Ring{};
    ring.record(stamped("redo me ", 42));
    ring.markUndone(42);
    try expect(ring.newestForUndo().?.undone);
    ring.clearUndone(42);
    try expect(!ring.newestForUndo().?.undone);
}

test "a reused slot starts un-undone — no stale flag inherited on eviction (#225 prefactor)" {
    var ring = Ring{};
    // Fill the ring, flag the oldest live slot, then push enough records to evict and reuse it.
    var i: usize = 0;
    while (i < capacity) : (i += 1) ring.record(stamped("x ", @intCast(i))); // stamps 0..19
    ring.markUndone(0); // flag the oldest
    // One more write reuses slot 0 (the evicted stamp-0 record's slot) for a fresh Insertion.
    ring.record(stamped("fresh ", 100));
    // The newest (stamp 100) landed in the reused slot and must not inherit stamp 0's flag.
    try expect(!ring.newestForUndo().?.undone);
}

// ---- withheld records: spoken under a held Secure Event Input (#286) ------------------

fn withheld(text: []const u8, ts: i64) coord.InsertionRecord {
    return .{ .inserted = text, .raw = null, .timestamp = ts, .outcome = .ok, .focused_app = null, .withheld = true };
}

test "a withheld record stores no transcript bytes, inserted or raw" {
    var ring = Ring{};
    ring.record(.{
        .inserted = "my bank password is hunter2 ",
        .raw = "my bank password is hunter two",
        .timestamp = 1,
        .outcome = .ok,
        .focused_app = null,
        .withheld = true,
    });

    var out: [capacity]Record = undefined;
    try expectEqual(@as(usize, 1), ring.snapshot(&out)); // the record is kept…
    try expect(out[0].withheld);
    try expectEqual(@as(usize, 0), out[0].inserted().len); // …but holds nothing
    try expect(out[0].raw() == null); // the pre-Rewrite form is withheld too

    // Nothing of either text survives in the snapshot's own bytes: the same three-byte-run
    // check the log's redaction test uses, applied to the record.
    const spoken = "my bank password is hunter2";
    var i: usize = 0;
    while (i + 3 <= spoken.len) : (i += 1)
        try expect(std.mem.indexOf(u8, out[0].inserted(), spoken[i..][0..3]) == null);
}

test "a withheld record is still deletable: the count survives the text" {
    // The whole reason the ring counts at record time. Undo's most valuable case is exactly
    // this one — a password just dictated into a field — and it needs the count, not the words.
    var ring = Ring{};
    ring.record(withheld("hunter2 ", 5));
    const target = ring.newestForUndo().?;
    try expectEqual(@as(usize, 8), target.clusters); // "hunter2 " incl. the trailing space
    try expect(target.landed); // .ok — the text did reach the cursor
    try expectEqual(@as(i64, 5), target.timestamp);
}

test "a withheld record yields no text for its stamp, like an evicted one" {
    var ring = Ring{};
    ring.record(withheld("secret ", 9));
    var out: [max_bytes]u8 = undefined;
    try expectEqual(@as(usize, 0), ring.textForStamp(9, &out));
}

test "a withheld record can be undone and re-flagged like any other" {
    var ring = Ring{};
    ring.record(withheld("secret ", 11));
    try expect(!ring.newestForUndo().?.undone);
    ring.markUndone(11);
    try expect(ring.newestForUndo().?.undone);
}

test "a slot reused by a normal Insertion does not inherit the withheld flag" {
    // The same stale-flag hazard `undone` has: a withheld record's slot comes back around, and
    // a fresh ordinary Insertion landing in it must be revealable.
    var ring = Ring{};
    var i: usize = 0;
    while (i < capacity) : (i += 1) ring.record(withheld("secret ", @intCast(i)));
    ring.record(stamped("ordinary ", 100)); // reuses the oldest withheld slot

    var out: [capacity]Record = undefined;
    _ = ring.snapshot(&out);
    try expect(!out[0].withheld);
    try expectEqualStrings("ordinary ", out[0].inserted());
}

test "a withheld record that never landed is withheld on the same terms" {
    // `.failed` and `.refused` records exist for recovery, which is exactly what a withheld one
    // cannot offer — there is no text either way, and the outcome does not change that.
    var ring = Ring{};
    for ([_]coord.InsertResult{ .failed, .refused }) |never_landed| {
        var rec = withheld("secret ", 1);
        rec.outcome = never_landed;
        ring.record(rec);
        var out: [capacity]Record = undefined;
        _ = ring.snapshot(&out);
        try expect(out[0].withheld);
        try expectEqual(@as(usize, 0), out[0].inserted().len);
        try expect(!ring.newestForUndo().?.landed); // and it is not an Undo target
    }
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
