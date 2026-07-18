//! configuration_phase.zig - stateful Configuration Phase policy.
//!
//! The daemon observes OS and adapter facts, feeds them here, and receives semantic
//! actions to execute. This keeps the not-configured/configured phase memory out of the
//! daemon loop while leaving macOS, keychain, Session construction, logging, and cues in
//! the real adapters.

const std = @import("std");
const readiness = @import("readiness.zig");
const backend = @import("transcription_backend.zig");

pub const Facts = struct {
    selected_backend: backend.Backend,
    key_present: bool,
    local_installation_present: bool,
    microphone_granted: bool,
    backend_present: bool,
    input_monitoring_granted: bool,
    post_event_granted: bool,
    tap_enabled: bool,
    backend_ready: bool,
    paused: bool,
};

pub const Actions = struct {
    connect_session: bool = false,
    prepare_local: bool = false,
    enable_tap: bool = false,
    announce_ready: bool = false,
    report_missing: ?readiness.Report = null,
};

pub const Outcome = struct {
    actions: Actions,
    health: readiness.Health,
    configured: bool,
};

pub const ConfigurationPhase = struct {
    reporter: readiness.Reporter = .{},
    announced: bool = false,

    pub fn tick(self: *ConfigurationPhase, facts: Facts) Outcome {
        const snap = snapshot(facts);
        var actions = Actions{
            .connect_session = facts.selected_backend == .openai and facts.key_present and !facts.backend_present,
            .prepare_local = facts.selected_backend == .local and facts.local_installation_present and !facts.backend_present,
            .enable_tap = facts.input_monitoring_granted and !facts.tap_enabled,
        };
        const is_configured = readiness.configured(snap);

        if (is_configured) {
            _ = self.reporter.next(snap);
            // Backend preparation is an adapter effect that can fail. Do not advance
            // READY memory until daemon.zig has executed it and re-ticked.
            if (!actions.connect_session and !actions.prepare_local and facts.backend_ready and !self.announced) {
                actions.announce_ready = true;
                self.announced = true;
            }
        } else {
            self.announced = false;
            actions.report_missing = self.reporter.next(snap);
        }

        return .{
            .actions = actions,
            .health = readiness.health(snap),
            .configured = is_configured,
        };
    }
};

pub fn snapshot(facts: Facts) readiness.Snapshot {
    return .{
        .selected_backend = facts.selected_backend,
        .key_present = facts.key_present,
        .local_installation_present = facts.local_installation_present,
        .microphone_granted = facts.microphone_granted,
        .input_monitoring_granted = facts.input_monitoring_granted,
        .post_event_granted = facts.post_event_granted,
        .tap_enabled = facts.tap_enabled,
        .backend_ready = facts.backend_ready,
        .paused = facts.paused,
    };
}

pub fn health(facts: Facts) readiness.Health {
    return readiness.health(snapshot(facts));
}

fn makeFacts(fields: struct {
    selected_backend: backend.Backend = .openai,
    key_present: bool = true,
    local_installation_present: bool = false,
    microphone_granted: bool = true,
    backend_present: bool = true,
    input_monitoring_granted: bool = true,
    post_event_granted: bool = true,
    tap_enabled: bool = true,
    backend_ready: bool = true,
    paused: bool = false,
}) Facts {
    return .{
        .selected_backend = fields.selected_backend,
        .key_present = fields.key_present,
        .local_installation_present = fields.local_installation_present,
        .microphone_granted = fields.microphone_granted,
        .backend_present = fields.backend_present,
        .input_monitoring_granted = fields.input_monitoring_granted,
        .post_event_granted = fields.post_event_granted,
        .tap_enabled = fields.tap_enabled,
        .backend_ready = fields.backend_ready,
        .paused = fields.paused,
    };
}

test "missing prerequisites report once until the set changes" {
    var phase = ConfigurationPhase{};
    const missing = makeFacts(.{ .key_present = false, .post_event_granted = false });

    const first = phase.tick(missing);
    try std.testing.expect(!first.configured);
    try std.testing.expect(first.actions.report_missing != null);
    try std.testing.expectEqual(@as(usize, 2), first.actions.report_missing.?.count);

    const stable = phase.tick(missing);
    try std.testing.expect(stable.actions.report_missing == null);

    const changed = phase.tick(makeFacts(.{ .post_event_granted = false }));
    try std.testing.expect(changed.actions.report_missing != null);
    try std.testing.expectEqual(@as(usize, 1), changed.actions.report_missing.?.count);
}

test "READY announces once on configured entry and again after leaving" {
    var phase = ConfigurationPhase{};

    const first = phase.tick(makeFacts(.{}));
    try std.testing.expect(first.configured);
    try std.testing.expect(first.actions.announce_ready);

    const stable = phase.tick(makeFacts(.{}));
    try std.testing.expect(!stable.actions.announce_ready);

    _ = phase.tick(makeFacts(.{ .key_present = false }));

    const reentered = phase.tick(makeFacts(.{}));
    try std.testing.expect(reentered.actions.announce_ready);
}

test "session readiness affects health but not configured phase" {
    var phase = ConfigurationPhase{};
    const out = phase.tick(makeFacts(.{ .backend_ready = false }));

    try std.testing.expect(out.configured);
    try std.testing.expectEqual(readiness.Status.reconnecting, out.health.status);
}

test "commands Session construction and announces only after backend readiness" {
    var phase = ConfigurationPhase{};

    const before_connect = phase.tick(makeFacts(.{ .backend_present = false, .backend_ready = false }));
    try std.testing.expect(before_connect.configured);
    try std.testing.expect(before_connect.actions.connect_session);
    try std.testing.expect(!before_connect.actions.announce_ready);

    const preparing = phase.tick(makeFacts(.{ .backend_ready = false }));
    try std.testing.expect(!preparing.actions.announce_ready);

    const after_connect = phase.tick(makeFacts(.{}));
    try std.testing.expect(after_connect.actions.announce_ready);
}

test "commands tap enable and reports the current missing set" {
    var phase = ConfigurationPhase{};

    const out = phase.tick(makeFacts(.{ .tap_enabled = false }));
    try std.testing.expect(!out.configured);
    try std.testing.expect(out.actions.enable_tap);
    try std.testing.expect(out.actions.report_missing != null);
}

test "session construction and missing prerequisite reporting are independent" {
    var phase = ConfigurationPhase{};

    const out = phase.tick(makeFacts(.{
        .backend_present = false,
        .backend_ready = false,
        .input_monitoring_granted = false,
        .tap_enabled = false,
    }));
    try std.testing.expect(!out.configured);
    try std.testing.expect(out.actions.connect_session);
    try std.testing.expect(out.actions.report_missing != null);
}

test "local Configuration Phase prepares offline without an OpenAI key" {
    var phase = ConfigurationPhase{};
    const out = phase.tick(makeFacts(.{
        .selected_backend = .local,
        .key_present = false,
        .local_installation_present = true,
        .backend_present = false,
        .backend_ready = false,
    }));
    try std.testing.expect(out.configured);
    try std.testing.expect(out.actions.prepare_local);
    try std.testing.expect(!out.actions.connect_session);
}
