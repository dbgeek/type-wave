//! undo_gate.zig — the app-level focus gate's evaluation rule (undo-spec, #213/#224).
//!
//! The safety property that keeps a misfired `⌃⌘⌫` from eating text in some other app:
//! Undo proceeds only on positive evidence that the frontmost app is unchanged since the
//! Insertion. "Same app" is the strictest rule #213 offers — **both** the bundle id **and**
//! the display name must match the record's stored `focused_app` — and the gate is
//! **fail-closed**: `focused_app` is a best-effort nullable hint and `frontmost()` can
//! itself return null, so either side missing refuses. Backspaces are destructive and
//! irreversible; the gate never posts on missing evidence.
//!
//! This module is pure policy — no ObjC, no logging, no clock — so the rule is testable in
//! isolation. The *timing* half of the contract ("a fresh `frontmost()` read immediately
//! before posting any backspace") belongs to the caller: `insertion_adapter.runUndo`
//! evaluates this gate against a `focusedApp()` read taken on the worker right before
//! `deleteChars`, never against a value captured at trigger or record time.
//!
//! The gate is app-level only by design (map #209's out-of-scope: no Accessibility
//! field-level capture) — the residual "user kept typing in the same app" hazard is a
//! known, accepted limitation stated in the spec, not guarded here.

const std = @import("std");
const coord = @import("coordinator.zig");

/// Why an Undo refused — captured for the feedback layer (#226 renders; today the reason is
/// written to the log only, per #213: all reasons collapse to one refuse cue on the HUD).
/// `no_target` and `already_undone` are produced by the trigger (nothing to select, or the
/// newest record is already undone — #225's single-shot refuse); the other two by `evaluate`
/// below.
pub const RefuseReason = enum {
    /// The ring holds no Insertion to delete (trigger-side; never returned by `evaluate`).
    no_target,
    /// The newest record is already undone — a second `⌃⌘⌫` on it refuses rather than eating
    /// earlier text (trigger-side, #225's single-shot model; never returned by `evaluate`).
    already_undone,
    /// Missing evidence — the record has no stored `focused_app`, or `frontmost()` returned
    /// null (fail-closed, #213's null-evidence rule).
    focus_null,
    /// Positive evidence of a change: bundle id or display name differs from the record's.
    app_changed,
};

/// Evaluate the gate: `expected` is the record's stored `focused_app`, `fresh` the
/// `frontmost()` read taken immediately before posting. Returns null when the gate passes
/// (post the backspaces) or the refuse reason when it does not (post nothing).
pub fn evaluate(expected: ?coord.AppIdentity, fresh: ?coord.AppIdentity) ?RefuseReason {
    const e = expected orelse return .focus_null;
    const f = fresh orelse return .focus_null;
    if (!std.mem.eql(u8, e.bundleId(), f.bundleId())) return .app_changed;
    if (!std.mem.eql(u8, e.displayName(), f.displayName())) return .app_changed;
    return null;
}

// ============================================================================
// Tests — the equality rule and the fail-closed null handling (#213 / #224).
// ============================================================================

const expectEqual = std.testing.expectEqual;

const slack = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack");

test "the gate passes when bundle id AND display name both match" {
    const fresh = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack");
    try expectEqual(@as(?RefuseReason, null), evaluate(slack, fresh));
}

test "a changed bundle id refuses as app_changed, even with the name unchanged" {
    // Two apps can share a display name (e.g. a beta build); the bundle id catches it.
    const impostor = coord.AppIdentity.init("com.example.slack-beta", "Slack");
    try expectEqual(@as(?RefuseReason, .app_changed), evaluate(slack, impostor));
}

test "a changed display name refuses as app_changed, even with the bundle id unchanged" {
    // The strictest rule of #213: a mismatch on either field refuses.
    const renamed = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack Canary");
    try expectEqual(@as(?RefuseReason, .app_changed), evaluate(slack, renamed));
}

test "a null fresh read refuses as focus_null (fail-closed: no frontmost app)" {
    try expectEqual(@as(?RefuseReason, .focus_null), evaluate(slack, null));
}

test "a null stored identity refuses as focus_null (fail-closed: record has no evidence)" {
    try expectEqual(@as(?RefuseReason, .focus_null), evaluate(null, slack));
}

test "both sides null still refuses — null never matches null" {
    try expectEqual(@as(?RefuseReason, .focus_null), evaluate(null, null));
}
