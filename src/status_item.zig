//! Pure presentation policy for the compact Status Item hierarchy.
//!
//! AppKit rendering lives in menu.zig. This module turns independent daemon state axes
//! into the one headline, one primary action, and privacy cues the user sees.

const std = @import("std");
const backend = @import("transcription_backend.zig");
const installation_identity = @import("installation_identity.zig");
const readiness = @import("readiness.zig");

pub const Installation = enum {
    absent,
    ready,
    update_available,
    corrupt,
};

pub const Operation = enum {
    idle,
    installing,
    updating,
    paused,
    verifying,
    smoke_testing,
    waiting_for_inference,
    activating,
    removing,
    discarding,
    failed,
    cancelled,

    pub fn isActive(self: Operation) bool {
        return switch (self) {
            .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing, .discarding => true,
            .idle, .paused, .failed, .cancelled => false,
        };
    }

    pub fn isCancellable(self: Operation) bool {
        return switch (self) {
            .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference => true,
            else => false,
        };
    }

    pub fn reportsByteProgress(self: Operation) bool {
        return self == .installing or self == .updating or self == .verifying;
    }
};

pub const ModelAction = enum {
    install,
    update,
    resume_operation,
    retry_operation,
    discard,
    verify,
    repair,
    remove,
    retry_runtime,
    cancel_operation,
    diagnostics,
};

pub const ModelFailure = enum {
    none,
    installation_corrupt,
    runtime_unavailable,
    operation_failed,
    operation_cancelled,
};

pub const Snapshot = struct {
    selected_backend: backend.Backend,
    health: readiness.Health,
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    installation: Installation = .absent,
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    installation_identity: ?InstallationIdentity = null,
    failure_detail: ?FailureDetail = null,
};

pub const ByteProgress = struct { completed: u64, total: u64 };
pub const InstallationIdentity = installation_identity.Identity;
pub const FailureDetail = struct {
    bytes: [256]u8 = @splat(0),
    len: u16 = 0,

    pub fn init(detail: []const u8) !FailureDetail {
        if (detail.len == 0 or detail.len > 256) return error.InvalidFailureDetail;
        var result = FailureDetail{ .len = @intCast(detail.len) };
        @memcpy(result.bytes[0..detail.len], detail);
        return result;
    }

    pub fn value(self: *const FailureDetail) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Headline = enum {
    paused,
    microphone_needed,
    input_monitoring_needed,
    accessibility_needed,
    selected_backend_prerequisite_missing,
    backend_failure,
    preparing,
    ready,
    ready_offline,
};

pub const PrimaryAction = enum {
    none,
    set_openai_api_key,
    install_local_model,
    update_local_model,
    resume_model_operation,
    retry_model_operation,
    repair_local_model,
    retry_local_runtime,
    operation_progress,
};

pub const Presentation = struct {
    headline: Headline,
    primary_action: PrimaryAction,
    show_openai_controls: bool,
    audio_stays_on_mac: bool,
    model_operation_uses_network: bool,
    model_actions: std.EnumSet(ModelAction),
    model_failure: ModelFailure,

    pub fn allowsModelAction(self: Presentation, action: ModelAction) bool {
        return self.model_actions.contains(action);
    }
};

pub fn derive(s: Snapshot) Presentation {
    const operation_active = s.operation.isActive();
    return .{
        .headline = headline(s),
        .primary_action = primaryAction(s),
        .show_openai_controls = s.selected_backend == .openai,
        .audio_stays_on_mac = s.selected_backend == .local and
            s.health.status == .ready_offline,
        .model_operation_uses_network = operation_active,
        .model_actions = modelActions(s, operation_active),
        .model_failure = if (s.operation == .failed)
            .operation_failed
        else if (s.operation == .cancelled)
            .operation_cancelled
        else if (s.installation == .corrupt)
            .installation_corrupt
        else if (s.local_runtime_failure)
            .runtime_unavailable
        else
            .none,
    };
}

fn modelActions(s: Snapshot, operation_active: bool) std.EnumSet(ModelAction) {
    var actions: std.EnumSet(ModelAction) = .empty;
    actions.insert(.diagnostics);
    switch (s.operation) {
        .paused => {
            actions.insert(.resume_operation);
            actions.insert(.discard);
            return actions;
        },
        .failed, .cancelled => {
            actions.insert(.retry_operation);
            return actions;
        },
        .idle => {},
        else => {
            if (s.operation.isCancellable()) actions.insert(.cancel_operation);
            return actions;
        },
    }
    std.debug.assert(!operation_active);
    switch (s.installation) {
        .absent => actions.insert(.install),
        .ready => {
            actions.insert(.verify);
            actions.insert(.remove);
        },
        .update_available => {
            actions.insert(.update);
            actions.insert(.verify);
            actions.insert(.remove);
        },
        .corrupt => {
            actions.insert(.verify);
            actions.insert(.repair);
            actions.insert(.remove);
        },
    }
    if (s.local_runtime_failure) actions.insert(.retry_runtime);
    return actions;
}

fn headline(s: Snapshot) Headline {
    if (s.health.paused) return .paused;
    switch (s.health.status) {
        .microphone_needed => return .microphone_needed,
        .input_monitoring_needed => return .input_monitoring_needed,
        .accessibility_needed => return .accessibility_needed,
        else => {},
    }
    switch (s.health.status) {
        .no_key, .no_local_installation => return .selected_backend_prerequisite_missing,
        else => {},
    }
    if (s.terminal_backend_failure or (s.selected_backend == .local and s.installation == .corrupt)) return .backend_failure;
    return switch (s.health.status) {
        .reconnecting, .preparing_local => .preparing,
        .ready => .ready,
        .ready_offline => .ready_offline,
        .no_key, .no_local_installation, .microphone_needed, .input_monitoring_needed, .accessibility_needed => unreachable,
    };
}

fn primaryAction(s: Snapshot) PrimaryAction {
    if (s.selected_backend == .openai)
        return if (s.health.status == .no_key) .set_openai_api_key else .none;
    if (s.operation == .paused) return .resume_model_operation;
    if (s.operation == .failed or s.operation == .cancelled) return .retry_model_operation;
    if (s.operation.isActive()) return .operation_progress;
    if (s.installation == .absent) return .install_local_model;
    if (s.installation == .corrupt) return .repair_local_model;
    if (s.terminal_backend_failure) return .retry_local_runtime;
    if (s.installation == .update_available) return .update_local_model;
    return .none;
}

fn snap(fields: struct {
    selected_backend: backend.Backend = .local,
    health: readiness.Health = .{ .paused = false, .status = .ready_offline },
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    installation: Installation = .ready,
    operation: Operation = .idle,
}) Snapshot {
    return .{
        .selected_backend = fields.selected_backend,
        .health = fields.health,
        .terminal_backend_failure = fields.terminal_backend_failure,
        .local_runtime_failure = fields.local_runtime_failure,
        .installation = fields.installation,
        .operation = fields.operation,
    };
}

test "compact headline follows pause, common prerequisite, selected prerequisite, failure, preparation, ready priority" {
    try std.testing.expectEqual(Headline.paused, derive(snap(.{ .health = .{ .paused = true, .status = .no_local_installation }, .terminal_backend_failure = true })).headline);
    try std.testing.expectEqual(Headline.microphone_needed, derive(snap(.{ .health = .{ .paused = false, .status = .microphone_needed }, .installation = .absent })).headline);
    try std.testing.expectEqual(Headline.input_monitoring_needed, derive(snap(.{ .health = .{ .paused = false, .status = .input_monitoring_needed }, .installation = .absent })).headline);
    try std.testing.expectEqual(Headline.selected_backend_prerequisite_missing, derive(snap(.{ .health = .{ .paused = false, .status = .no_local_installation }, .terminal_backend_failure = true, .installation = .absent })).headline);
    try std.testing.expectEqual(Headline.backend_failure, derive(snap(.{ .terminal_backend_failure = true })).headline);
    try std.testing.expectEqual(Headline.preparing, derive(snap(.{ .health = .{ .paused = false, .status = .preparing_local } })).headline);
    try std.testing.expectEqual(Headline.ready_offline, derive(snap(.{})).headline);
}

test "compact hierarchy exposes only the selected backend primary action" {
    try std.testing.expectEqual(PrimaryAction.set_openai_api_key, derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .no_key },
        .installation = .update_available,
    })).primary_action);
    try std.testing.expectEqual(PrimaryAction.install_local_model, derive(snap(.{
        .health = .{ .paused = false, .status = .no_local_installation },
        .installation = .absent,
    })).primary_action);
    try std.testing.expectEqual(PrimaryAction.update_local_model, derive(snap(.{ .installation = .update_available })).primary_action);
    try std.testing.expectEqual(PrimaryAction.repair_local_model, derive(snap(.{ .installation = .corrupt })).primary_action);
    try std.testing.expectEqual(PrimaryAction.retry_local_runtime, derive(snap(.{ .terminal_backend_failure = true })).primary_action);
}

test "local privacy cues survive every active Model Operation stage" {
    for ([_]Operation{ .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing, .discarding }) |operation| {
        const p = derive(snap(.{ .operation = operation }));
        try std.testing.expect(p.audio_stays_on_mac);
        try std.testing.expect(p.model_operation_uses_network);
        try std.testing.expectEqual(PrimaryAction.operation_progress, p.primary_action);
        try std.testing.expect(!p.show_openai_controls);
    }
}

test "local Model Operation recovery stays in its submenu under OpenAI selection" {
    const p = derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
        .operation = .paused,
    }));
    try std.testing.expectEqual(PrimaryAction.none, p.primary_action);
    try std.testing.expect(p.show_openai_controls);
    try std.testing.expect(!p.audio_stays_on_mac);
}

test "unselected local corruption and runtime failure do not change OpenAI headline" {
    const p = derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
        .installation = .corrupt,
        .local_runtime_failure = true,
    }));
    try std.testing.expectEqual(Headline.ready, p.headline);
    try std.testing.expectEqual(PrimaryAction.none, p.primary_action);
}

test "restart-paused Model Operation exposes only Resume and Discard recovery" {
    const p = derive(snap(.{ .operation = .paused }));

    try std.testing.expectEqual(PrimaryAction.resume_model_operation, p.primary_action);
    try std.testing.expect(p.allowsModelAction(.resume_operation));
    try std.testing.expect(p.allowsModelAction(.discard));
    try std.testing.expect(!p.allowsModelAction(.install));
    try std.testing.expect(!p.allowsModelAction(.cancel_operation));
}

test "failed and cancelled Model Operations retry instead of pretending to resume partial data" {
    for ([_]Operation{ .failed, .cancelled }) |operation| {
        const p = derive(snap(.{ .operation = operation }));

        try std.testing.expectEqual(PrimaryAction.retry_model_operation, p.primary_action);
        try std.testing.expect(p.allowsModelAction(.retry_operation));
        try std.testing.expect(!p.allowsModelAction(.resume_operation));
        try std.testing.expect(!p.allowsModelAction(.discard));
    }
}

test "Cancel is offered only while a Model Operation stage is cancellable" {
    for ([_]Operation{ .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference }) |operation|
        try std.testing.expect(derive(snap(.{ .operation = operation })).allowsModelAction(.cancel_operation));
    for ([_]Operation{ .activating, .removing, .discarding }) |operation|
        try std.testing.expect(!derive(snap(.{ .operation = operation })).allowsModelAction(.cancel_operation));
}

test "Local Model failures identify the actionable recovery" {
    try std.testing.expectEqual(ModelFailure.installation_corrupt, derive(snap(.{ .installation = .corrupt })).model_failure);
    try std.testing.expectEqual(ModelFailure.runtime_unavailable, derive(snap(.{ .local_runtime_failure = true })).model_failure);
    try std.testing.expectEqual(ModelFailure.operation_failed, derive(snap(.{ .operation = .failed })).model_failure);
    try std.testing.expectEqual(ModelFailure.operation_cancelled, derive(snap(.{ .operation = .cancelled })).model_failure);
    try std.testing.expectEqual(ModelFailure.none, derive(snap(.{})).model_failure);
}
