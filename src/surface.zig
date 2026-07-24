//! surface.zig — the Feedback Surface: the one seam the Utterance Coordinator addresses
//! in lifecycle verbs (architecture review 2026-07-08, candidate 3, landed as part of
//! candidate 1). It owns the HUD-vs-cue arbitration that used to be re-decided at ~8 sites
//! inside the daemon:
//!
//!   - The waveform pill carries start/stop feedback when it is active; otherwise the
//!     sound cues do (wayfinder #22, silent waveform since #27 — the pill shows no text).
//!   - The error cue is *always* audible — the one signal that survives even with the pill.
//!   - The pill is hidden once the Utterance resolves (inserted / abandoned / empty / timed
//!     out).
//!
//! The Coordinator emits exactly one verb per lifecycle edge; this arbitration stays here,
//! not smeared through the state machine. Kept in its own module (not feedback.zig) so the
//! Coordinator's `feedback.log` dependency does not transitively drag AppKit into the
//! Coordinator's compilation — and, since the HUD Chrome seam landed, this module imports
//! neither half concretely, so the arbitration itself is exercised against fakes.

const std = @import("std");

/// Generic over both halves it arbitrates: the HUD pump (`hud.Hud(Chrome)`) and the sound
/// cues. Not a hypothetical seam — the HUD side already has two adapters below it, and
/// making this one generic is what lets the arbitration itself be tested, which is the whole
/// reason it was pulled out of the daemon in the first place.
pub fn Surface(comptime Hud: type, comptime Cues: type) type {
    return struct {
        const Self = @This();

        cues: *Cues,
        hud: *Hud,

        /// Utterance began, Capture is up. The pill (scrolling red waveform, fed levels by
        /// Capture's on_level) supersedes the start chime when the overlay is on — `isOn`
        /// consults the live Overlay toggle (#34), so a menu-disabled pill falls back to
        /// the chime like an overlay=false start.
        pub fn listening(self: *Self) void {
            if (self.hud.isOn()) self.hud.publish(.recording) else self.cues.start();
        }

        /// Talk Key released, Capture stopped, transcript pending. The pill flips to the green
        /// processing dots — held over the whole resolution (final, Insertion) — superseding
        /// the stop chime, same rule as `listening`.
        pub fn released(self: *Self) void {
            if (self.hud.isOn()) self.hud.publish(.processing) else self.cues.stop();
        }

        /// Insertion succeeded. Take the pill down; success is silent (the text landing is the
        /// signal). `hide` (not `isOn`-gated): a pill left up by a mid-Utterance disable
        /// still comes down.
        pub fn inserted(self: *Self) void {
            self.hud.hide();
        }

        /// Insertion succeeded, but with the *raw* Final Transcript because the Backtrack
        /// rewrite timed out or errored (docs/backtrack-spec.md §UX 4, ADR-0004). The text
        /// still landed, so — unlike `abandoned` — the error cue is deliberately silent; the
        /// only signal is a one-shot ~300 ms amber pulse on the processing dots, which then
        /// fades out. `pulseDegraded` self-hides, so this replaces the `inserted` silent hide.
        pub fn degraded(self: *Self) void {
            self.hud.pulseDegraded();
        }

        /// This Utterance produced no Insertion (no session, no audio, poison, empty/failed
        /// transcript, deadline, or a failed insert). Take the pill down and sound the error
        /// cue — always audible, even under the pill.
        pub fn abandoned(self: *Self) void {
            self.hud.hide();
            self.cues.err();
        }

        /// An Undo posted its backspaces (ADR-0007, #226): the HUD blooms a green single mark,
        /// then self-hides. Unlike the Coordinator's lifecycle verbs this rides no Utterance — it
        /// is driven from the recovery chord's worker/trigger — and it is HUD-only (no sound cue),
        /// so a disabled/headless overlay simply shows nothing (`undoConfirm` no-ops there).
        pub fn undoConfirmed(self: *Self) void {
            self.hud.undoConfirm();
        }

        /// An Undo was refused (ADR-0007, #226): the HUD blooms a red mark and shakes it, then
        /// self-hides. All refuse reasons (app-changed, focus null, no-target, already-undone)
        /// collapse to this one cue; the specific reason is logged only (#213). HUD-only, same as
        /// `undoConfirmed`.
        pub fn undoRefused(self: *Self) void {
            self.hud.undoRefuse();
        }
    };
}

// ============================================================================
// Tests — the HUD-vs-cue arbitration this module exists to own. Unreachable before the
// HUD Chrome seam made both halves substitutable.
// ============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const FakeHud = struct {
    on: bool = true,
    published: [8]u8 = @splat(0),
    n: usize = 0,
    hides: usize = 0,
    pulses: usize = 0,
    confirms: usize = 0,
    refuses: usize = 0,

    fn isOn(self: *FakeHud) bool {
        return self.on;
    }
    fn publish(self: *FakeHud, state: enum { hidden, recording, processing }) void {
        if (self.n < self.published.len) {
            self.published[self.n] = switch (state) {
                .hidden => 'h',
                .recording => 'r',
                .processing => 'p',
            };
            self.n += 1;
        }
    }
    fn hide(self: *FakeHud) void {
        self.hides += 1;
    }
    fn pulseDegraded(self: *FakeHud) void {
        self.pulses += 1;
    }
    fn undoConfirm(self: *FakeHud) void {
        self.confirms += 1;
    }
    fn undoRefuse(self: *FakeHud) void {
        self.refuses += 1;
    }
    fn sent(self: *const FakeHud) []const u8 {
        return self.published[0..self.n];
    }
};

const FakeCues = struct {
    starts: usize = 0,
    stops: usize = 0,
    errs: usize = 0,

    fn start(self: *FakeCues) void {
        self.starts += 1;
    }
    fn stop(self: *FakeCues) void {
        self.stops += 1;
    }
    fn err(self: *FakeCues) void {
        self.errs += 1;
    }
};

const TestSurface = Surface(FakeHud, FakeCues);

test "with the pill on, start/stop feedback is visual and the chimes stay silent" {
    var h = FakeHud{};
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.listening();
    s.released();

    try std.testing.expectEqualStrings("rp", h.sent());
    try expectEqual(@as(usize, 0), c.starts);
    try expectEqual(@as(usize, 0), c.stops);
}

test "with the overlay off, the same edges fall back to the chimes and publish nothing" {
    // The live Overlay toggle (#34): a menu-disabled pill behaves exactly like an
    // overlay=false start — which is also how a headless run reads, since the daemon
    // leaves `enabled` false when the Chrome could not be built.
    var h = FakeHud{ .on = false };
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.listening();
    s.released();

    try expectEqual(@as(usize, 0), h.n);
    try expectEqual(@as(usize, 1), c.starts);
    try expectEqual(@as(usize, 1), c.stops);
}

test "a successful Insertion is silent — the text landing is the signal" {
    var h = FakeHud{};
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.inserted();

    try expectEqual(@as(usize, 1), h.hides);
    try expectEqual(@as(usize, 0), c.errs);
}

test "the pill comes down on inserted even with the overlay off — hide is never isOn-gated" {
    // A pill left up by a mid-Utterance disable still has to come down.
    var h = FakeHud{ .on = false };
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.inserted();

    try expectEqual(@as(usize, 1), h.hides);
}

test "a degraded Insertion pulses instead of hiding, and stays silent (ADR-0004)" {
    var h = FakeHud{};
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.degraded();

    try expectEqual(@as(usize, 1), h.pulses);
    try expectEqual(@as(usize, 0), h.hides); // pulseDegraded self-hides; no second take-down
    try expectEqual(@as(usize, 0), c.errs); // the text still landed
}

test "the error cue is always audible — even under a live pill" {
    var h = FakeHud{};
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.abandoned();

    try expectEqual(@as(usize, 1), h.hides);
    try expectEqual(@as(usize, 1), c.errs);
}

test "the Undo cues are HUD-only — no sound in either direction (ADR-0007)" {
    var h = FakeHud{};
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.undoConfirmed();
    s.undoRefused();

    try expectEqual(@as(usize, 1), h.confirms);
    try expectEqual(@as(usize, 1), h.refuses);
    try expectEqual(@as(usize, 0), c.starts);
    try expectEqual(@as(usize, 0), c.stops);
    try expectEqual(@as(usize, 0), c.errs);
}

test "an Undo cue reaches the HUD unconditionally — the pump, not the Surface, drops it" {
    // Undo is deliberately not isOn-gated here: `requestCue` already refuses while the
    // overlay is off, and the pump drops a cue that cannot be shown this tick. Splitting
    // that decision across both modules is what this arbitration exists to prevent.
    var h = FakeHud{ .on = false };
    var c = FakeCues{};
    var s = TestSurface{ .hud = &h, .cues = &c };

    s.undoConfirmed();

    try expectEqual(@as(usize, 1), h.confirms);
}
