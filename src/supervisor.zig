//! supervisor.zig — the Supervisor: the pure per-tick decider of the daemon's self-heal
//! nudges and the Capture-Enable Gate's one cached term.
//!
//! The daemon's self-heal loop (daemon.zig `supervisorLoop`) polls OS and adapter facts
//! ~every 3 s, drives the Backend Router and the grant sequence, then must decide four
//! things: whether to re-arm a dead Talk Key tap, whether to fire a PostEvent probe,
//! whether to reclaim model storage nobody owns, and — the load-bearing one — the one
//! tick-cached term of the Capture-Enable Gate (ADR-0013: `configured`, the only term
//! with no live owner; pause is read live at the tap and backend readiness is the
//! Utterance Coordinator's to refuse, audibly, at lease acquisition). Those decisions
//! used to live inline in the loop, reachable only by running the real daemon against live
//! TCC and the tap. They are now this one pure function, fed a `Facts` snapshot and
//! returning an `Actions` bundle the daemon thread executes.
//!
//! # What the Supervisor owns, and what it does not
//!
//! It owns only the residual self-heal *decisions*. It does NOT subsume the Configuration
//! Phase (configuration_phase.zig) or the grant sequence (grants.zig): those stay
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

/// One poll tick's live facts, gathered by the daemon after the grant sequence has
/// advanced (so `grants_reached_post_event` is current).
pub const Facts = struct {
    /// The Talk Key tap is live. False means Input Monitoring is denied or the port was
    /// created-while-denied; the re-arm is the only thing that re-consults tccd (#127).
    tap_enabled: bool,
    /// The grant sequence has advanced to its PostEvent step (#130): only then may the
    /// attempt-then-observe probe fire.
    grants_reached_post_event: bool,
    /// PostEvent is provably granted (observe latch OR a trustworthy-when-true preflight).
    post_event_granted: bool,
    /// No Utterance is in flight (Backend Router `activeId() == 0`), so deleting model
    /// storage nobody owns cannot disturb dictation.
    no_utterance_in_flight: bool,
    /// The menu-bar "Pause dictation" toggle is on (#34). Deliberately not a term in any
    /// decision here since ADR-0013 — the tap reads pause live, and the Capture watchdog
    /// must end a hold mid-pause — it stays a fact so the tests can pin that non-influence.
    paused: bool,
    /// A Talk Key hold is open (`tap.Hold`): the adapter forwarded a press and has not
    /// matched a release to it, so Capture is running.
    hold_open: bool,
    /// The key that opened that hold is still physically down, read from the HID state
    /// rather than from the tap — the evidence that survives a tap which stopped
    /// delivering edges (#272). False whenever no hold is open.
    talk_key_down: bool,
};

/// The complete end-of-tick effect bundle the daemon thread executes. `announce_ready`
/// and `report_missing` are forwarded verbatim from the Configuration Phase outcome — the
/// Supervisor does not decide them; it assembles them into the one bundle the loop runs.
pub const Actions = struct {
    /// Fire `tap.scheduleRecreate()` — the fresh-create re-arm (#127/#129).
    rearm_tap: bool,
    /// Fire `insertmod.postTaggedProbe()` — the PostEvent attempt-then-observe probe (#129).
    post_probe: bool,
    /// Fire `provisioner.reclaimModelStorage()` — reclaim model storage nobody owns: a
    /// superseded Model Installation, or one an interrupted removal never finished
    /// deleting (#276). *Which* reclaims exist is the model store's business; the
    /// Supervisor decides only that this is a tick where deleting model bytes is safe.
    reclaim_model_storage: bool,
    /// The Capture watchdog (#272): feed the Coordinator the `.release` the tap never
    /// delivered, ending a hold whose key is demonstrably up.
    end_lost_hold: bool,
    /// The Capture-Enable Gate's one cached term (ADR-0013): the Configuration Phase's
    /// `configured`, with no conjunction. The tap callback consults it before starting
    /// Capture, beside its live pause check; backend readiness is not consulted at all —
    /// the Utterance Coordinator's lease acquisition owns that refusal, and says so.
    capture_configured: bool,
    /// Forwarded from the Configuration Phase: log the READY line this tick.
    announce_ready: bool,
    /// Forwarded from the Configuration Phase: report the missing prerequisites this tick.
    report_missing: ?readiness.Report,
};

/// Decide this tick's self-heal nudges and the Capture-Enable Gate's cached term from the
/// live facts and the Configuration Phase outcome the Backend Router produced mid-tick.
pub fn tick(facts: Facts, outcome: configuration_phase.Outcome) Actions {
    return .{
        // A dead tap is re-armed unconditionally — the preflight the Configuration Phase
        // sees can lie stale, so only the fresh-create attempt is the grant detector.
        .rearm_tap = !facts.tap_enabled,
        // Probe once the sequence has reached PostEvent, the tap is live to observe the
        // round-trip, and the grant is not already proven.
        .post_probe = facts.grants_reached_post_event and facts.tap_enabled and !facts.post_event_granted,
        .reclaim_model_storage = facts.no_utterance_in_flight,
        // The Capture watchdog: a hold is open, and the key holding it open is up. Only
        // the release edge stops the microphone, so an edge the tap never delivered — a
        // dead tap, or a Talk Key change that predates the hold-matched release filter —
        // would otherwise leave Capture running until the daemon restarts. Duration is
        // deliberately not a term: a long hold is legitimate, and "the key is up" is
        // cheap, direct evidence that this one is not one.
        .end_lost_hold = facts.hold_open and !facts.talk_key_down,
        // The Capture-Enable Gate caches only what has no live owner (ADR-0013).
        .capture_configured = outcome.configured,
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

/// All-healthy facts: tap live, PostEvent granted, nothing in flight, not paused.
/// Tests override one axis at a time.
fn okFacts() Facts {
    return .{
        .tap_enabled = true,
        .grants_reached_post_event = true,
        .post_event_granted = true,
        .no_utterance_in_flight = true,
        .paused = false,
        .hold_open = false,
        .talk_key_down = false,
    };
}

test "capture_configured equals configured exactly, unmoved by the pause flag" {
    // ADR-0013: the gate's other two terms have live owners — pause is read at the tap,
    // and backend readiness is the Coordinator's lease acquisition to refuse — so the
    // cached term is `configured` alone, with no conjunction.
    for ([_]bool{ false, true }) |configured| {
        for ([_]bool{ false, true }) |paused| {
            var facts = okFacts();
            facts.paused = paused;
            const outcome = if (configured) configuredOutcome() else notConfiguredOutcome();

            const acts = tick(facts, outcome);
            try testing.expectEqual(configured, acts.capture_configured);
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

test "reclaim_model_storage is gated on no Utterance in flight" {
    var idle = okFacts();
    idle.no_utterance_in_flight = true;
    try testing.expect(tick(idle, configuredOutcome()).reclaim_model_storage);

    var busy = okFacts();
    busy.no_utterance_in_flight = false;
    try testing.expect(!tick(busy, configuredOutcome()).reclaim_model_storage);
}

test "end_lost_hold is exactly an open hold whose key is up" {
    for ([_]bool{ false, true }) |hold_open| {
        for ([_]bool{ false, true }) |key_down| {
            var facts = okFacts();
            facts.hold_open = hold_open;
            facts.talk_key_down = key_down;

            const acts = tick(facts, configuredOutcome());
            try testing.expectEqual(hold_open and !key_down, acts.end_lost_hold);
        }
    }
}

test "a legitimate hold is never cut, however long it lasts" {
    // Duration is not a term in the decision: the same held key, tick after tick, keeps
    // the Utterance alive — a two-minute dictation is exactly as valid as a two-second one.
    var facts = okFacts();
    facts.hold_open = true;
    facts.talk_key_down = true;
    for (0..100) |_| try testing.expect(!tick(facts, configuredOutcome()).end_lost_hold);
}

test "the watchdog is independent of pause and of the capture gate" {
    // The gate decides whether a *press* may start an Utterance; this ends one already
    // running. A pause mid-hold must still let that hold stop the microphone.
    var facts = okFacts();
    facts.hold_open = true;
    facts.talk_key_down = false;
    facts.paused = true;

    const acts = tick(facts, notConfiguredOutcome());
    try testing.expect(!acts.capture_configured);
    try testing.expect(acts.end_lost_hold);
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
