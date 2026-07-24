//! undo_trigger.zig — the recovery-chord Undo trigger policy (undo-spec, #223).
//!
//! The walking-skeleton wire (#223): on the recovery chord `⌃⌘⌫` (#221), resolve the **newest**
//! Recent Insertions record (#212 — single newest Insertion, no stack) and submit its with-space
//! `inserted` bytes to the undo sink, which backspaces them out through the deletion engine
//! (#222/#214). Deliberately **unguarded** at this stage: no focus gate, no `undone` flag, no HUD
//! feedback — those graduate into the next three tickets.
//!
//! Factored out of `daemon.onRecoveryChord` so the chord → newest-record resolution → `submitUndo`
//! chain is testable without a live daemon: `sink` is duck-typed (anything exposing
//! `submitUndo([]const u8)`), so tests drive it with a fake while the daemon passes the real
//! `InsertionAdapter`.

const std = @import("std");
const recent_insertions = @import("recent_insertions.zig");

/// Resolve the newest live Insertion Record's with-space `inserted` bytes and submit them to the
/// undo sink for deletion. Empty ring / no record → nothing submitted (no-op, no crash). Runs on
/// the tap's run-loop thread; the ring read is a bounded memcpy under its leaf lock and the submit
/// only copies into the sink's slot, so the callback stays fast (a slow tap callback makes the OS
/// disable the tap). The byte slice → backspace-count conversion (grapheme clusters, #220) is the
/// sink's job in `runUndo`, not this trigger's.
pub fn trigger(ring: *recent_insertions.Ring, sink: anytype) void {
    var buf: [recent_insertions.max_bytes]u8 = undefined;
    const n = ring.newestInserted(&buf);
    if (n == 0) return; // empty ring / no record — nothing to undo
    sink.submitUndo(buf[0..n]);
}

// ============================================================================
// Tests — the chord → newest-record resolution → submitUndo chain, driven through a fake sink.
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// A stand-in for the InsertionAdapter's undo slot: captures the exact bytes handed to
/// `submitUndo` so a test can assert what the trigger resolved and submitted.
const FakeSink = struct {
    submits: usize = 0,
    last: [recent_insertions.max_bytes]u8 = undefined,
    last_len: usize = 0,

    fn submitUndo(self: *FakeSink, text: []const u8) void {
        self.submits += 1;
        @memcpy(self.last[0..text.len], text);
        self.last_len = text.len;
    }
    fn lastText(self: *const FakeSink) []const u8 {
        return self.last[0..self.last_len];
    }
};

test "trigger resolves the newest record and submits its with-space bytes to the sink" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "first ", .raw = null, .timestamp = 0, .outcome = .ok, .focused_app = null });
    ring.record(.{ .inserted = "newest ", .raw = null, .timestamp = 0, .outcome = .ok, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    // The newest Insertion's exact with-space text flows to the undo sink — "newest " (7 bytes,
    // 7 grapheme clusters incl. the trailing space → 7 backspaces downstream in runUndo, #220).
    try expectEqual(@as(usize, 1), sink.submits);
    try expectEqualStrings("newest ", sink.lastText());
}

test "trigger on an empty ring submits nothing (no record, no crash)" {
    var ring = recent_insertions.Ring{};
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqual(@as(usize, 0), sink.submits);
}

test "trigger targets only the newest, ignoring older records (single-shot, #212)" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "older one ", .raw = null, .timestamp = 0, .outcome = .ok, .focused_app = null });
    ring.record(.{ .inserted = "middle ", .raw = null, .timestamp = 0, .outcome = .ok, .focused_app = null });
    ring.record(.{ .inserted = "the last thing ", .raw = null, .timestamp = 0, .outcome = .ok, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqualStrings("the last thing ", sink.lastText());
}

test "trigger submits the with-space inserted, never the pre-Rewrite raw" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "At 18:00 ", .raw = "at 20:00 no 18:00", .timestamp = 0, .outcome = .degraded, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqualStrings("At 18:00 ", sink.lastText());
}
