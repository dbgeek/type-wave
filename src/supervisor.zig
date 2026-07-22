//! supervisor.zig — the Supervisor: the pure per-tick decider of the daemon's self-heal
//! nudges and the capture-enable gate.
//!
//! The daemon's self-heal loop (daemon.zig `supervisorLoop`) polls OS and adapter facts
//! ~every 3 s, drives the Backend Router and the grant sequence, then must decide four
//! things: whether to re-arm a dead Talk Key tap, whether to fire a PostEvent probe,
//! whether to reclaim a superseded Model Installation, and — the load-bearing one —
//! whether a Talk Key press may fire this tick (the capture-enable gate). Those decisions
//! used to live inline in the loop, reachable only by running the real daemon against live
//! TCC and the tap. They are now this one pure function, fed a `Facts` snapshot and
//! returning an `Actions` bundle the daemon thread executes.
//!
//! # What the Supervisor owns, and what it does not
//!
//! It owns only the residual self-heal *decisions*. It does NOT subsume the Configuration
//! Phase (configuration_phase.zig) or the grant sequence (grant_sequence.zig): those stay
//! peer machines the daemon drives. The Supervisor merely *reads* the Configuration Phase
//! `Outcome` — forwarding its `announce_ready` / `report_missing` and gating capture on its
//! `configured` — and reads whether the grant sequence has `reached` the PostEvent step.
//!
//! The `rearm_tap` / `post_probe` effects are asynchronous nudges: `scheduleRecreate`
//! posts to the tap's run-loop thread, `postTaggedProbe` posts a synthetic event, and both
//! outcomes are observed on the *next* tick (`tap.isEnabled()` / the PostEvent latch).
//! Because their results never land within the emitting tick, the daemon runs them at
//! end-of-tick with everything else — the ordering that let this collapse to one call.
//!
//! Pure by design (ADR-0005): the daemon keeps the impure fact-gathering (which OS probe
//! maps to which `Facts` field) and runs the effects, so the self-heal effect ordering
//! stays visible in the loop. This module is exercised by fed `Facts`, not hardware.

const std = @import("std");
const configuration_phase = @import("configuration_phase.zig");
const readiness = @import("readiness.zig");

/// One poll tick's live facts, gathered by the daemon after the Backend Router has ticked
/// (so `backend_available` reflects any resource warmed this tick) and after the grant
/// sequence has advanced (so `grants_reached_post_event` is current).
pub const Facts = struct {
    /// The Talk Key tap is live. False means Input Monitoring is denied or the port was
    /// created-while-denied; the re-arm is the only thing that re-consults tccd (#127).
    tap_enabled: bool,
    /// The grant sequence has advanced to its PostEvent step (#130): only then may the
    /// attempt-then-observe probe fire.
    grants_reached_post_event: bool,
    /// PostEvent is provably granted (observe latch OR a trustworthy-when-true preflight).
    post_event_granted: bool,
    /// No Utterance is in flight (Backend Router `activeId() == 0`), so reclaiming a
    /// superseded Model Installation cannot disturb dictation.
    no_utterance_in_flight: bool,
    /// The selected Transcription Backend has an authoritative resource this tick.
    backend_available: bool,
    /// The menu-bar "Pause dictation" toggle is on (#34).
    paused: bool,
};

/// The complete end-of-tick effect bundle the daemon thread executes. `announce_ready`
/// and `report_missing` are forwarded verbatim from the Configuration Phase outcome — the
/// Supervisor does not decide them; it assembles them into the one bundle the loop runs.
pub const Actions = struct {
    /// Fire `tap.scheduleRecreate()` — the fresh-create re-arm (#127/#129).
    rearm_tap: bool,
    /// Fire `insertmod.postTaggedProbe()` — the PostEvent attempt-then-observe probe (#129).
    post_probe: bool,
    /// Fire `provisioner.removeSuperseded()` — reclaim a superseded Model Installation.
    remove_superseded: bool,
    /// The Talk Key press gate: the tap callback consults this before starting Capture.
    capture_enabled: bool,
    /// Forwarded from the Configuration Phase: log the READY line this tick.
    announce_ready: bool,
    /// Forwarded from the Configuration Phase: report the missing prerequisites this tick.
    report_missing: ?readiness.Report,
};

/// Decide this tick's self-heal nudges and the capture-enable gate from the live facts and
/// the Configuration Phase outcome the Backend Router produced mid-tick.
pub fn tick(facts: Facts, outcome: configuration_phase.Outcome) Actions {
    return .{
        // A dead tap is re-armed unconditionally — the preflight the Configuration Phase
        // sees can lie stale, so only the fresh-create attempt is the grant detector.
        .rearm_tap = !facts.tap_enabled,
        // Probe once the sequence has reached PostEvent, the tap is live to observe the
        // round-trip, and the grant is not already proven.
        .post_probe = facts.grants_reached_post_event and facts.tap_enabled and !facts.post_event_granted,
        .remove_superseded = facts.no_utterance_in_flight,
        // The press gate: configured AND a live backend AND not paused.
        .capture_enabled = outcome.configured and facts.backend_available and !facts.paused,
        .announce_ready = outcome.actions.announce_ready,
        .report_missing = outcome.actions.report_missing,
    };
}

// ---- tests: the decisions on fed facts (the fact-gathering glue stays in the daemon) ----

const testing = std.testing;

/// A configured outcome with no pending config actions — the common case for gating tests.
fn configuredOutcome() configuration_phase.Outcome {
    return .{ .actions = .{}, .health = .{ .paused = false, .status = .ready }, .configured = true };
}

fn notConfiguredOutcome() configuration_phase.Outcome {
    return .{ .actions = .{}, .health = .{ .paused = false, .status = .no_key }, .configured = false };
}

/// All-healthy facts: tap live, PostEvent granted, nothing in flight, backend available,
/// not paused. Tests override one axis at a time.
fn okFacts() Facts {
    return .{
        .tap_enabled = true,
        .grants_reached_post_event = true,
        .post_event_granted = true,
        .no_utterance_in_flight = true,
        .backend_available = true,
        .paused = false,
    };
}

test "capture_enabled is the AND of configured, backend_available, and not-paused" {
    // The full truth table over the three inputs to the Talk Key press gate.
    for ([_]bool{ false, true }) |configured| {
        for ([_]bool{ false, true }) |available| {
            for ([_]bool{ false, true }) |paused| {
                var facts = okFacts();
                facts.backend_available = available;
                facts.paused = paused;
                const outcome = if (configured) configuredOutcome() else notConfiguredOutcome();

                const acts = tick(facts, outcome);
                try testing.expectEqual(configured and available and !paused, acts.capture_enabled);
            }
        }
    }
}

test "post_probe fires only when reached AND tap live AND not already granted" {
    for ([_]bool{ false, true }) |reached| {
        for ([_]bool{ false, true }) |tap_enabled| {
            for ([_]bool{ false, true }) |granted| {
                var facts = okFacts();
                facts.grants_reached_post_event = reached;
                facts.tap_enabled = tap_enabled;
                facts.post_event_granted = granted;

                const acts = tick(facts, configuredOutcome());
                try testing.expectEqual(reached and tap_enabled and !granted, acts.post_probe);
            }
        }
    }
}

test "rearm_tap is exactly a dead tap" {
    var live = okFacts();
    live.tap_enabled = true;
    try testing.expect(!tick(live, configuredOutcome()).rearm_tap);

    var dead = okFacts();
    dead.tap_enabled = false;
    try testing.expect(tick(dead, configuredOutcome()).rearm_tap);
}

test "remove_superseded is gated on no Utterance in flight" {
    var idle = okFacts();
    idle.no_utterance_in_flight = true;
    try testing.expect(tick(idle, configuredOutcome()).remove_superseded);

    var busy = okFacts();
    busy.no_utterance_in_flight = false;
    try testing.expect(!tick(busy, configuredOutcome()).remove_superseded);
}

test "announce_ready and report_missing are forwarded verbatim from the outcome" {
    var announcing = configuredOutcome();
    announcing.actions.announce_ready = true;
    try testing.expect(tick(okFacts(), announcing).announce_ready);
    try testing.expect(tick(okFacts(), configuredOutcome()).report_missing == null);

    var reporting = notConfiguredOutcome();
    reporting.actions.report_missing = .{ .count = 1, .lines = .{ "Input Monitoring", "", "", "" } };
    const acts = tick(okFacts(), reporting);
    try testing.expect(acts.report_missing != null);
    try testing.expectEqual(@as(usize, 1), acts.report_missing.?.count);
    try testing.expect(!acts.announce_ready);
}
