//! surface.zig — the Feedback Surface: the one seam the Utterance Coordinator addresses
//! in lifecycle verbs (architecture review 2026-07-08, candidate 3, landed as part of
//! candidate 1). It owns the HUD-vs-cue arbitration that used to be re-decided at ~8 sites
//! inside the daemon:
//!
//!   - The overlay pill carries start/stop feedback when it is active; otherwise the sound
//!     cues do (wayfinder #22).
//!   - The error cue is *always* audible — the one signal that survives even with the pill.
//!   - The pill is hidden once the Utterance resolves (inserted / abandoned / empty / timed
//!     out).
//!
//! The Coordinator emits exactly one verb per lifecycle edge; this arbitration stays here,
//! not smeared through the state machine. Kept in its own module (not feedback.zig) so the
//! Coordinator's `feedback.log` dependency does not transitively drag AppKit (hud.zig) into
//! the Coordinator's compilation.

const feedback = @import("feedback.zig");
const hud = @import("hud.zig");

pub const Surface = struct {
    cues: *feedback.Cues,
    hud: *hud.Hud,

    /// Utterance began, Capture is up. The pill (red, awaiting the first Partial
    /// Transcript) supersedes the start chime when the overlay is on.
    pub fn listening(self: *Surface) void {
        if (self.hud.active) self.hud.publish(.recording, "") else self.cues.start();
    }

    /// A Partial Transcript streamed in. Pill only — there is no partial cue.
    pub fn streaming(self: *Surface, text: []const u8) void {
        if (self.hud.active) self.hud.publish(.recording, text);
    }

    /// Talk Key released, Capture stopped, transcript pending. The pill stays up showing
    /// the last partial; only the stop chime carries this, and only when there is no pill.
    pub fn released(self: *Surface) void {
        if (!self.hud.active) self.cues.stop();
    }

    /// The Final Transcript arrived and is about to be inserted. Green flash on the pill;
    /// no cue (there was never a "final" chime).
    pub fn committed(self: *Surface, text: []const u8) void {
        if (self.hud.active) self.hud.publish(.final, text);
    }

    /// Insertion succeeded. Take the pill down; success is silent (the text landing is the
    /// signal).
    pub fn inserted(self: *Surface) void {
        if (self.hud.active) self.hud.hide();
    }

    /// This Utterance produced no Insertion (no session, no audio, poison, empty/failed
    /// transcript, deadline, or a failed insert). Take the pill down and sound the error
    /// cue — always audible, even under the pill.
    pub fn abandoned(self: *Surface) void {
        if (self.hud.active) self.hud.hide();
        self.cues.err();
    }
};
