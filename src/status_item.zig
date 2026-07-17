//! Pure presentation policy for the compact Status Item hierarchy.
//!
//! AppKit rendering lives in menu.zig. This module turns independent daemon state axes
//! into the one headline, one primary action, and privacy cues the user sees.

const std = @import("std");
const backend = @import("transcription_backend.zig");
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
    failed,
};

pub const Snapshot = struct {
    selected_backend: backend.Backend,
    health: readiness.Health,
    terminal_backend_failure: bool = false,
    installation: Installation = .absent,
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    installation_identity: ?InstallationIdentity = null,
};

pub const ByteProgress = struct { completed: u64, total: u64 };
pub const InstallationIdentity = struct { size: u64, sha256: [32]u8 };

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
};

pub fn derive(s: Snapshot) Presentation {
    const operation_active = switch (s.operation) {
        .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing => true,
        .idle, .paused, .failed => false,
    };
    return .{
        .headline = headline(s),
        .primary_action = primaryAction(s),
        .show_openai_controls = s.selected_backend == .openai,
        .audio_stays_on_mac = s.selected_backend == .local_kb_whisper and
            s.health.status == .ready_offline,
        .model_operation_uses_network = operation_active and switch (s.operation) {
            .installing, .updating => true,
            else => false,
        },
    };
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
    if (s.terminal_backend_failure or s.installation == .corrupt) return .backend_failure;
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
    if (s.operation == .failed) return .retry_model_operation;
    switch (s.operation) {
        .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing => return .operation_progress,
        .idle, .paused, .failed => {},
    }
    if (s.installation == .absent) return .install_local_model;
    if (s.installation == .corrupt) return .repair_local_model;
    if (s.terminal_backend_failure) return .retry_local_runtime;
    if (s.installation == .update_available) return .update_local_model;
    return .none;
}

fn snap(fields: struct {
    selected_backend: backend.Backend = .local_kb_whisper,
    health: readiness.Health = .{ .paused = false, .status = .ready_offline },
    terminal_backend_failure: bool = false,
    installation: Installation = .ready,
    operation: Operation = .idle,
}) Snapshot {
    return .{
        .selected_backend = fields.selected_backend,
        .health = fields.health,
        .terminal_backend_failure = fields.terminal_backend_failure,
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

test "local privacy cue survives a network-using Model Operation" {
    const p = derive(snap(.{ .operation = .updating }));
    try std.testing.expect(p.audio_stays_on_mac);
    try std.testing.expect(p.model_operation_uses_network);
    try std.testing.expectEqual(PrimaryAction.operation_progress, p.primary_action);
    try std.testing.expect(!p.show_openai_controls);
}

test "Local Model operation recovery stays in its submenu under OpenAI selection" {
    const p = derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
        .operation = .paused,
    }));
    try std.testing.expectEqual(PrimaryAction.none, p.primary_action);
    try std.testing.expect(p.show_openai_controls);
    try std.testing.expect(!p.audio_stays_on_mac);
}
