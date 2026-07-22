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

/// The two-tier menu-bar icon (CONTEXT.md, Status Item): `normal` when dictation can fire,
/// `dimmed` when it needs attention (paused / a missing grant / a backend failure).
pub const IconTier = enum { normal, dimmed };

pub const Presentation = struct {
    headline: Headline,
    icon_tier: IconTier,
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
    const hl = headline(s);
    return .{
        .headline = hl,
        // The dim tier folds the readiness attention signal with the backend-failure
        // headline into one field, so the menu no longer re-ORs two modules' terms.
        .icon_tier = if (s.health.needsAttention() or hl == .backend_failure) .dimmed else .normal,
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

/// The Model Operation Runner's live observation, in status_item-native types (mirrors
/// model_operation's `Current` so this module needn't import — and cycle with — that one).
pub const Observation = struct {
    active: bool,
    phase: Operation,
    bytes: ?ByteProgress,
    failure_detail: ?FailureDetail,
};

/// The daemon-gathered readings `project` assembles a `Snapshot` from. Everything here is
/// already mapped to status_item-native values by the daemon's gathering glue (the
/// model_store I/O and the recovery-phase -> Operation map); this struct carries no
/// model_store or provisioner types, so the projection policy stays pure and testable.
pub const Readings = struct {
    selected_backend: backend.Backend,
    health: readiness.Health,
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    /// The on-disk installation view before the corrupt override (absent/ready/update).
    installation: Installation = .absent,
    recovery_is_corrupt: bool = false,
    /// The on-disk operation view before the runner override.
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    installation_identity: ?InstallationIdentity = null,
    provisioner_failure_detail: ?FailureDetail = null,
    observed: ?Observation = null,
};

/// Assemble the `Snapshot` the menu renders from the daemon's readings — the corrupt
/// override and the runner-observation precedence that used to live inline in
/// daemon.menuStatus. Pure policy over already-mapped values; the I/O and the enum mapping
/// stay in the daemon.
pub fn project(r: Readings) Snapshot {
    var installation = r.installation;
    if (r.recovery_is_corrupt) installation = .corrupt;

    var operation = r.operation;
    var operation_bytes = r.operation_bytes;
    var failure_detail = r.provisioner_failure_detail;
    if (r.observed) |o| {
        // The Runner's live observation overrides the on-disk recovery view — except a
        // paused operation stays paused unless the Runner is actively driving one, so a
        // stale idle observation cannot erase a paused resume point.
        if (o.active or operation != .paused) {
            operation = o.phase;
            operation_bytes = o.bytes;
        }
        failure_detail = o.failure_detail;
    }

    return .{
        .selected_backend = r.selected_backend,
        .health = r.health,
        .terminal_backend_failure = r.terminal_backend_failure,
        .local_runtime_failure = r.local_runtime_failure,
        .installation = installation,
        .operation = operation,
        .operation_bytes = operation_bytes,
        .installation_identity = r.installation_identity,
        .failure_detail = failure_detail,
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

test "icon dims on the readiness attention signal and the backend-failure headline" {
    // Attention statuses dim the icon.
    try std.testing.expectEqual(IconTier.dimmed, derive(snap(.{ .health = .{ .paused = true, .status = .ready_offline } })).icon_tier);
    try std.testing.expectEqual(IconTier.dimmed, derive(snap(.{ .health = .{ .paused = false, .status = .microphone_needed }, .installation = .absent })).icon_tier);
    // A backend failure dims even when readiness alone would not (folds the second term).
    try std.testing.expectEqual(IconTier.dimmed, derive(snap(.{ .terminal_backend_failure = true })).icon_tier);
    // A ready backend keeps the icon normal.
    try std.testing.expectEqual(IconTier.normal, derive(snap(.{})).icon_tier);
    try std.testing.expectEqual(IconTier.normal, derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
    })).icon_tier);
}

fn reads(fields: struct {
    installation: Installation = .ready,
    recovery_is_corrupt: bool = false,
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    provisioner_failure_detail: ?FailureDetail = null,
    observed: ?Observation = null,
}) Readings {
    return .{
        .selected_backend = .local,
        .health = .{ .paused = false, .status = .ready_offline },
        .installation = fields.installation,
        .recovery_is_corrupt = fields.recovery_is_corrupt,
        .operation = fields.operation,
        .operation_bytes = fields.operation_bytes,
        .provisioner_failure_detail = fields.provisioner_failure_detail,
        .observed = fields.observed,
    };
}

test "project: the corrupt recovery flag overrides the on-disk installation view" {
    try std.testing.expectEqual(Installation.corrupt, project(reads(.{ .installation = .ready, .recovery_is_corrupt = true })).installation);
    try std.testing.expectEqual(Installation.ready, project(reads(.{ .installation = .ready, .recovery_is_corrupt = false })).installation);
}

test "project: an active runner observation overrides the on-disk operation and bytes" {
    const s = project(reads(.{
        .operation = .idle,
        .operation_bytes = null,
        .observed = .{ .active = true, .phase = .installing, .bytes = .{ .completed = 3, .total = 9 }, .failure_detail = null },
    }));
    try std.testing.expectEqual(Operation.installing, s.operation);
    try std.testing.expectEqual(@as(u64, 3), s.operation_bytes.?.completed);
}

test "project: a paused operation survives a stale inactive observation" {
    // observed.active = false AND on-disk op == .paused → the paused resume point stays.
    const s = project(reads(.{
        .operation = .paused,
        .operation_bytes = .{ .completed = 5, .total = 10 },
        .observed = .{ .active = false, .phase = .idle, .bytes = null, .failure_detail = null },
    }));
    try std.testing.expectEqual(Operation.paused, s.operation);
    try std.testing.expectEqual(@as(u64, 5), s.operation_bytes.?.completed);
}

test "project: a non-paused on-disk operation yields to an inactive observation" {
    // observed.active = false but on-disk op != .paused → the observation still wins.
    const s = project(reads(.{
        .operation = .installing,
        .observed = .{ .active = false, .phase = .idle, .bytes = null, .failure_detail = null },
    }));
    try std.testing.expectEqual(Operation.idle, s.operation);
}

test "project: failure_detail comes from the observation whenever one is present" {
    const provisioner_detail = try FailureDetail.init("provisioner");
    const observed_detail = try FailureDetail.init("runner");

    // No observation → the provisioner detail passes through.
    const without = project(reads(.{ .provisioner_failure_detail = provisioner_detail }));
    try std.testing.expectEqualStrings("provisioner", without.failure_detail.?.value());

    // Observation present → its detail replaces the provisioner's, regardless of activity.
    const with = project(reads(.{
        .provisioner_failure_detail = provisioner_detail,
        .observed = .{ .active = false, .phase = .idle, .bytes = null, .failure_detail = observed_detail },
    }));
    try std.testing.expectEqualStrings("runner", with.failure_detail.?.value());
}
