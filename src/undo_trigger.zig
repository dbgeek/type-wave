//! undo_trigger.zig — the recovery-chord Undo trigger policy (undo-spec, #223/#224).
//!
//! On the recovery chord `⌃⌘⌫` (#221), resolve the **newest** Recent Insertions record (#212 —
//! single newest Insertion, no stack) and submit its with-space `inserted` bytes **plus its
//! stored App Identity** to the undo sink, which gates on that identity (#224/#213) and
//! backspaces the bytes out through the deletion engine (#222/#214). The trigger deliberately
//! does **not** evaluate the focus gate itself: the gate's contract is a fresh `frontmost()`
//! read immediately before posting, and posting happens on the sink's worker — a gate here, on
//! the tap's run-loop thread, would both go stale in the trigger→worker gap and stall the tap
//! callback on a cross-process NSWorkspace query (app_focus.zig). The two trigger-side refusals
//! it resolves before any submit — no-target (empty ring) and already-undone (#225) — fire the
//! HUD refuse cue through the sink (`refuseUndo`, ADR-0007/#226); the confirm and the gate's own
//! refusals are the worker's (`runUndo`).
//!
//! Factored out of `daemon.onRecoveryChord` so the chord → newest-record resolution → `submitUndo`
//! chain is testable without a live daemon: `sink` is duck-typed (anything exposing
//! `submitUndo([]const u8, ?coord.AppIdentity)`), so tests drive it with a fake while the daemon
//! passes the real `InsertionAdapter`.

const std = @import("std");
const coord = @import("coordinator.zig");
const feedback = @import("feedback.zig");
const recent_insertions = @import("recent_insertions.zig");
const undo_gate = @import("undo_gate.zig");

/// Resolve the newest live Insertion Record and submit its with-space `inserted` bytes and
/// stored `focused_app` to the undo sink for gated deletion. Empty ring / no record → nothing
/// submitted; the `no_target` refuse reason is captured in the log for the feedback layer
/// (#213: reason-to-log; #226 renders the single refuse cue). Runs on the tap's run-loop
/// thread; the ring read is a bounded memcpy under its leaf lock and the submit only copies
/// into the sink's slot, so the callback stays fast (a slow tap callback makes the OS disable
/// the tap). The byte slice → backspace-count conversion (grapheme clusters, #220) and the
/// focus-gate evaluation (#224) are the sink's job in `runUndo`, not this trigger's.
pub fn trigger(ring: *recent_insertions.Ring, sink: anytype) void {
    var buf: [recent_insertions.max_bytes]u8 = undefined;
    const target = ring.newestForUndo(&buf) orelse {
        feedback.log("  undo refused: {s} — the ring holds no Insertion to delete\n", .{@tagName(undo_gate.RefuseReason.no_target)});
        // Refuse cue (ADR-0007, #226): no-target collapses to the one red-shake cue, reason
        // logged only (#213). The gate refusals fire it from the worker; this trigger-side
        // one fires it here, before any submit, through the sink.
        sink.refuseUndo();
        return;
    };
    // Single-shot (#225): the newest record is undone already, so a second `⌃⌘⌫` on it would
    // eat the *earlier* text. Refuse instead — the record stays flagged, re-insert redoes it.
    if (target.undone) {
        feedback.log("  undo refused: {s} — the newest Insertion is already undone\n", .{@tagName(undo_gate.RefuseReason.already_undone)});
        // Refuse cue (#226): already-undone is the fourth refuse reason, same single cue.
        sink.refuseUndo();
        return;
    }
    sink.submitUndo(buf[0..target.len], target.focused_app);
    // Flag the record undone (#225): Undo is single-shot and pushes no new ring entry, so the
    // record is kept and flagged in place. This is the trigger path's job on a committed Undo —
    // the deletion mechanism (#222) deliberately never touches the ring. Keyed by the record's
    // stable `timestamp` so a concurrent Insertion can't flag a neighbour. The worker-side focus
    // gate (#224) may still refuse to post the backspaces; a misfire in the wrong app dims the
    // record without deleting, an accepted edge of the app-level model (#209/#212).
    ring.markUndone(target.timestamp);
}

// ============================================================================
// Tests — the chord → newest-record resolution → submitUndo chain, driven through a fake sink.
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// A stand-in for the InsertionAdapter's undo slot: captures the exact bytes and App Identity
/// handed to `submitUndo` so a test can assert what the trigger resolved and submitted.
const FakeSink = struct {
    submits: usize = 0,
    refuses: usize = 0,
    last: [recent_insertions.max_bytes]u8 = undefined,
    last_len: usize = 0,
    last_app: ?coord.AppIdentity = null,

    fn submitUndo(self: *FakeSink, text: []const u8, expected_app: ?coord.AppIdentity) void {
        self.submits += 1;
        @memcpy(self.last[0..text.len], text);
        self.last_len = text.len;
        self.last_app = expected_app;
    }
    /// The Undo refuse cue the trigger fires on its no-target / already-undone refusals (#226).
    fn refuseUndo(self: *FakeSink) void {
        self.refuses += 1;
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
    // A resolved target submits; it does not fire the trigger-side refuse cue (#226) — the
    // worker decides confirm vs the gate's refuse once it drains the job.
    try expectEqual(@as(usize, 0), sink.refuses);
}

test "trigger submits the record's stored App Identity alongside the bytes (gate input, #224)" {
    var ring = recent_insertions.Ring{};
    ring.record(.{
        .inserted = "hello ",
        .raw = null,
        .timestamp = 0,
        .outcome = .ok,
        .focused_app = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack"),
    });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqualStrings("com.tinyspeck.slackmacgap", sink.last_app.?.bundleId());
    try expectEqualStrings("Slack", sink.last_app.?.displayName());
}

test "trigger passes a record's null App Identity through as null — the sink refuses it, not us" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "hello ", .raw = null, .timestamp = 0, .outcome = .ok, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    // The submit still happens: the fail-closed refusal is the gate's call at post time
    // (runUndo), so the trigger stays a pure resolver.
    try expectEqual(@as(usize, 1), sink.submits);
    try expect(sink.last_app == null);
}

test "trigger on an empty ring submits nothing (no_target) but fires the refuse cue (#226)" {
    var ring = recent_insertions.Ring{};
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqual(@as(usize, 0), sink.submits);
    // No-target collapses to the one red-shake cue, surfaced here on the trigger thread.
    try expectEqual(@as(usize, 1), sink.refuses);
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

test "trigger flags the newest record undone after submitting it (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "undo me ", .raw = null, .timestamp = 55, .outcome = .ok, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqual(@as(usize, 1), sink.submits);
    var out: [recent_insertions.max_bytes]u8 = undefined;
    try expect(ring.newestForUndo(&out).?.undone); // kept and flagged, not removed
}

test "a second fire on an already-undone newest record refuses — no submit (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "older ", .raw = null, .timestamp = 10, .outcome = .ok, .focused_app = null });
    ring.record(.{ .inserted = "newest ", .raw = null, .timestamp = 20, .outcome = .ok, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink); // first fire: submits the newest and flags it undone
    trigger(&ring, &sink); // second fire: newest is undone → refuse, don't eat "older "

    // Exactly one submit total: the second fire posted nothing rather than deleting earlier text.
    try expectEqual(@as(usize, 1), sink.submits);
    try expectEqualStrings("newest ", sink.lastText());
    // …and the second fire surfaced the already-undone refusal as the red-shake cue (#226).
    try expectEqual(@as(usize, 1), sink.refuses);
}

test "trigger adds no new ring entry — the record is kept and flagged, count unchanged (#225)" {
    var ring = recent_insertions.Ring{};
    ring.record(.{ .inserted = "solo ", .raw = null, .timestamp = 1, .outcome = .ok, .focused_app = null });
    var sink = FakeSink{};

    trigger(&ring, &sink);

    try expectEqual(@as(usize, 1), ring.len()); // still one record; Undo pushes nothing
}
