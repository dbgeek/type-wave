//! model_operation.zig — the Model Operation Runner (wayfinder #94).
//!
//! The daemon's one route from a Status Item action to a Model Operation child process,
//! and the owner of that operation's observation — the phase and byte progress the Status
//! Item reflects (CONTEXT.md). It drives one operation from launch to a terminal outcome
//! (success / cancelled / failed) and owns all the orchestration *policy*:
//!
//!   - action → argv / confirmation / initial-phase mapping,
//!   - the busy guard (one operation at a time),
//!   - `retry_operation` resolution back to the original action,
//!   - cancel routing (cancellable-phase gate, then kill the live child),
//!   - terminal-outcome classification (success clears; a non-zero exit is `failed`,
//!     or `cancelled` when a cancel was requested first).
//!
//! Like the Utterance Coordinator and the Backend Router, it reaches every *effect*
//! through an injected `Deps` seam, so the whole policy runs under scripted,
//! single-threaded tests with no subprocesses:
//!
//!   deps.launch(LaunchRequest) ?c_int — spawn the child for `request.argument`, writing
//!     `request.confirmation` to its stdin when present; return its pid, or null when the
//!     spawn failed (the provisioner reports its own details, like the Backend Router).
//!   deps.kill(pid) — deliver the cancel signal to a live child.
//!   deps.log(Note) — narration for the caller's log (child stderr prose; the terminal
//!     finished/failed line).
//!
//! It is *driven* by fed events — `onChannelEvent` (a decoded operation-channel event),
//! `onStderr`, `onTerminal` — so it is exercised by scripted events, not real subprocesses.
//! It consumes the operation-channel wire (operation_channel.zig); it does NOT warm the
//! local helper — that is the Backend Router's path.
//!
//! # Threads & the atomic observation
//!
//! In the daemon these entry points run on two thread groups: the main thread calls
//! `startAction` / `requestCancel` / `retryAction` / `current`, while the child's
//! pipe-reader / waiter threads feed `onChannelEvent` / `onStderr` / `onTerminal`. So the
//! observation is a set of atomics plus a `FailureObservation` (#93) — the exact reason
//! that leaf stands alone, importable without dragging in daemon.zig. A Runner instance is
//! handed out by pointer and must not move: the observation's atomics are addressed
//! in place. (`begin` runs immediately after `launch` returns, before the child can emit;
//! the pipe buffers anything that races ahead.)

const std = @import("std");
const operation_channel = @import("operation_channel.zig");
const status_item = @import("status_item.zig");
const failure_observation = @import("failure_observation.zig");

const FailureObservation = failure_observation.FailureObservation;

/// The Status Item action set. Re-exported so callers (and Deps implementers) name one type.
pub const ModelAction = status_item.ModelAction;

/// What `startAction` hands the seam to spawn: the CLI flag and, for the destructive
/// operations, the confirmation answer piped to the child's stdin.
pub const LaunchRequest = struct {
    argument: []const u8,
    confirmation: ?[]const u8,
};

/// Narration for the caller's log — every effect the Runner surfaces beyond launch/kill.
pub const Note = union(enum) {
    /// One line of the child's stderr prose (the daemon log; also the failure fallback).
    stderr: []const u8,
    /// The operation reached its terminal outcome.
    finished: struct { action: ModelAction, succeeded: bool },
};

/// The Status Item's read-model of the current operation.
pub const Current = struct {
    phase: status_item.Operation,
    bytes: ?status_item.ByteProgress,
    active: bool,
    failure_detail: ?status_item.FailureDetail,
};

/// The cross-thread operation observation: phase, byte progress, and failure detail, plus
/// the bookkeeping the policy reads back (the live pid, the retry target, whether a cancel
/// was requested, whether a typed failure already won). Lifted verbatim from daemon.zig's
/// `ModelOperationObservation`; the Runner owns exactly one and delegates to it.
const Observation = struct {
    pid: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(status_item.Operation.idle)),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    retry_action: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(ModelAction.install)),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    typed_failure: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failure: FailureObservation = .{},

    fn current(self: *Observation) ?Current {
        const active = self.pid.load(.acquire) != 0;
        const phase = std.enums.fromInt(status_item.Operation, self.phase.load(.acquire)) orelse .installing;
        if (!active and phase != .failed and phase != .cancelled) return null;
        const total = self.total.load(.acquire);
        return .{
            .phase = phase,
            .bytes = if (!phase.reportsByteProgress() or total == 0) null else .{ .completed = self.completed.load(.acquire), .total = total },
            .active = active,
            .failure_detail = self.failure.current(),
        };
    }

    fn begin(self: *Observation, pid: c_int, phase: status_item.Operation, action: ModelAction) void {
        self.phase.store(@intFromEnum(phase), .release);
        self.retry_action.store(@intFromEnum(action), .release);
        self.cancel_requested.store(false, .release);
        self.completed.store(0, .release);
        self.total.store(0, .release);
        self.typed_failure.store(false, .release);
        self.failure.clear();
        self.pid.store(pid, .release);
    }

    /// A decoded typed event from the child's stdout channel — the only source of
    /// phase and byte progress. Stderr prose is log and failure fallback, never
    /// mined for numbers.
    fn apply(self: *Observation, event: operation_channel.Event) void {
        switch (event) {
            .operation => |op| switch (op) {
                .downloading => |bytes| self.setProgress(bytes.completed, bytes.total),
                // A retry carries its own byte position — attempt/budget never
                // masquerades as progress (the old prose mining's latent bug).
                .retrying => |retry| self.setProgress(retry.bytes.completed, retry.bytes.total),
                .verifying => |bytes| {
                    self.setPhase(.verifying);
                    self.setProgress(bytes.completed, bytes.total);
                },
                .smoke_testing => self.setPhase(.smoke_testing),
                .waiting_for_inference => self.setPhase(.waiting_for_inference),
                .activating => self.setPhase(.activating),
                .removing => self.setPhase(.removing),
            },
            .failed => |name| {
                self.typed_failure.store(true, .release);
                self.failure.set(name);
            },
        }
    }

    /// Stderr fallback for deaths that never emit a typed `failed` event (a panic,
    /// OOM): retain the last non-progress line. A typed failure is authoritative.
    fn observeFailure(self: *Observation, line: []const u8) void {
        if (std.mem.indexOf(u8, line, "Model Operation:") != null) return;
        if (self.typed_failure.load(.acquire)) return;
        self.failure.set(line);
    }

    fn finish(self: *Observation, succeeded: bool) void {
        self.phase.store(@intFromEnum(if (succeeded)
            status_item.Operation.idle
        else if (self.cancel_requested.load(.acquire))
            status_item.Operation.cancelled
        else
            status_item.Operation.failed), .release);
        self.completed.store(0, .release);
        self.total.store(0, .release);
        self.pid.store(0, .release);
    }

    fn setPhase(self: *Observation, phase: status_item.Operation) void {
        self.phase.store(@intFromEnum(phase), .release);
        if (phase != .installing and phase != .updating and phase != .verifying) {
            self.completed.store(0, .release);
            self.total.store(0, .release);
        }
    }

    fn setProgress(self: *Observation, completed: u64, total: u64) void {
        self.completed.store(completed, .release);
        self.total.store(total, .release);
    }

    fn busy(self: *Observation) bool {
        return self.pid.load(.acquire) != 0;
    }

    /// The pid to kill, or null when the current phase can't be cancelled or no child
    /// is live. Marks the cancel so `finish` classifies the eventual death as cancelled.
    fn requestCancel(self: *Observation) ?c_int {
        const phase = std.enums.fromInt(status_item.Operation, self.phase.load(.acquire)) orelse return null;
        if (!phase.isCancellable()) return null;
        const pid = self.pid.load(.acquire);
        if (pid == 0) return null;
        self.cancel_requested.store(true, .release);
        return pid;
    }

    /// The action a Retry resolves to — only after a failed/cancelled operation.
    fn retryAction(self: *const Observation) ?ModelAction {
        const phase = std.enums.fromInt(status_item.Operation, self.phase.load(.acquire)) orelse return null;
        if (phase != .failed and phase != .cancelled) return null;
        return std.enums.fromInt(ModelAction, self.retry_action.load(.acquire));
    }

    /// The action of the operation in flight — for the terminal narration.
    fn inFlightAction(self: *const Observation) ModelAction {
        return std.enums.fromInt(ModelAction, self.retry_action.load(.acquire)) orelse .install;
    }
};

/// The launch policy for one action: the CLI flag, the confirmation answer piped to the
/// child's stdin (destructive operations only), and the phase the Status Item shows the
/// instant it launches. These three always travel together, so one table maps them.
const LaunchSpec = struct {
    argument: []const u8,
    confirmation: ?[]const u8,
    phase: status_item.Operation,
};

/// The launch policy for `action`, or null for the actions that never spawn a child
/// (retry_runtime, retry_operation, cancel_operation, diagnostics — routed elsewhere).
fn launchSpec(action: ModelAction) ?LaunchSpec {
    return switch (action) {
        .install => .{ .argument = "--install-model", .confirmation = null, .phase = .installing },
        .update => .{ .argument = "--update-model", .confirmation = null, .phase = .updating },
        .resume_operation => .{ .argument = "--resume-model", .confirmation = null, .phase = .installing },
        .discard => .{ .argument = "--discard-model", .confirmation = null, .phase = .discarding },
        .verify => .{ .argument = "--verify-model", .confirmation = null, .phase = .verifying },
        .repair => .{ .argument = "--repair-model", .confirmation = "yes\n", .phase = .installing },
        .remove => .{ .argument = "--remove-model", .confirmation = "remove\n", .phase = .removing },
        .retry_runtime, .retry_operation, .cancel_operation, .diagnostics => null,
    };
}

pub fn Runner(comptime Deps: type) type {
    return struct {
        const Self = @This();

        deps: *Deps,
        observation: Observation = .{},

        pub fn init(deps: *Deps) Self {
            return .{ .deps = deps };
        }

        /// Launch (or Retry) a Model Operation. `retry_operation` resolves to the original
        /// failed/cancelled action; the busy guard drops the call while one is in flight;
        /// the action maps to argv / confirmation / initial phase, launches through the
        /// seam, and — only on a successful launch — begins the observation.
        pub fn startAction(self: *Self, requested: ModelAction) void {
            const action = if (requested == .retry_operation)
                (self.observation.retryAction() orelse return)
            else
                requested;
            const spec = launchSpec(action) orelse return; // not a launchable action
            if (self.observation.busy()) return; // one operation at a time
            const pid = self.deps.launch(.{
                .argument = spec.argument,
                .confirmation = spec.confirmation,
            }) orelse return; // spawn failed — the seam reported its own detail
            self.observation.begin(pid, spec.phase, action);
        }

        /// Cancel routing: if the phase is cancellable and a child is live, mark the
        /// cancel and kill it through the seam. Returns whether a kill was issued.
        pub fn requestCancel(self: *Self) bool {
            const pid = self.observation.requestCancel() orelse return false;
            self.deps.kill(pid);
            return true;
        }

        /// The action a Retry resolves to after a failed/cancelled operation (null if none).
        pub fn retryAction(self: *Self) ?ModelAction {
            return self.observation.retryAction();
        }

        /// The Status Item's read-model (null = nothing to show).
        pub fn current(self: *Self) ?Current {
            return self.observation.current();
        }

        // ---- fed-event hooks: the daemon's pipe-reader / waiter threads ---------------

        /// A decoded operation-channel event — the sole source of phase and byte progress.
        pub fn onChannelEvent(self: *Self, event: operation_channel.Event) void {
            self.observation.apply(event);
        }

        /// One line of the child's stderr: the failure fallback, and log narration.
        pub fn onStderr(self: *Self, line: []const u8) void {
            self.observation.observeFailure(line);
            self.deps.log(.{ .stderr = line });
        }

        /// The child exited: classify the terminal outcome and narrate it.
        pub fn onTerminal(self: *Self, succeeded: bool) void {
            const action = self.observation.inFlightAction();
            self.observation.finish(succeeded);
            self.deps.log(.{ .finished = .{ .action = action, .succeeded = succeeded } });
        }
    };
}

// ---- scripted scenarios (FakeDeps: no threads, no subprocesses) -----------------

const FakeDeps = struct {
    const RecordedLaunch = struct { argument: []const u8, confirmation: ?[]const u8, pid: c_int };

    launches: [8]RecordedLaunch = undefined,
    launch_count: usize = 0,
    next_pid: c_int = 1_000,
    /// Simulate a spawn that never started (the seam returns null).
    launch_fails: bool = false,

    kills: [8]c_int = undefined,
    kill_count: usize = 0,

    notes: [32]Note = undefined,
    note_count: usize = 0,

    pub fn launch(self: *FakeDeps, request: LaunchRequest) ?c_int {
        if (self.launch_fails) return null;
        const pid = self.next_pid;
        self.next_pid += 1;
        self.launches[self.launch_count] = .{ .argument = request.argument, .confirmation = request.confirmation, .pid = pid };
        self.launch_count += 1;
        return pid;
    }
    pub fn kill(self: *FakeDeps, pid: c_int) void {
        self.kills[self.kill_count] = pid;
        self.kill_count += 1;
    }
    pub fn log(self: *FakeDeps, note: Note) void {
        self.notes[self.note_count] = note;
        self.note_count += 1;
    }

    fn lastLaunch(self: *const FakeDeps) ?RecordedLaunch {
        if (self.launch_count == 0) return null;
        return self.launches[self.launch_count - 1];
    }
    fn sawStderr(self: *const FakeDeps, line: []const u8) bool {
        for (self.notes[0..self.note_count]) |note| switch (note) {
            .stderr => |seen| if (std.mem.eql(u8, seen, line)) return true,
            else => {},
        };
        return false;
    }
    fn sawFinished(self: *const FakeDeps, action: ModelAction, succeeded: bool) bool {
        for (self.notes[0..self.note_count]) |note| switch (note) {
            .finished => |fin| if (fin.action == action and fin.succeeded == succeeded) return true,
            else => {},
        };
        return false;
    }
};

const TestRunner = Runner(FakeDeps);

// ---- the observation's own behaviour (moved from daemon.zig) --------------------

test "the Runner retains the actionable terminal failure" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    runner.startAction(.install);
    runner.onStderr("--install-model: ModelDownloadRejected");
    runner.onTerminal(false);

    const current = runner.current().?;
    try std.testing.expectEqual(status_item.Operation.failed, current.phase);
    try std.testing.expectEqualStrings("--install-model: ModelDownloadRejected", current.failure_detail.?.value());
}

test "typed channel events drive phase and bytes; a retry never corrupts progress" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    runner.startAction(.install);

    runner.onChannelEvent(.{ .operation = .{ .downloading = .{ .completed = 100, .total = 1_000 } } });
    var current = runner.current().?;
    try std.testing.expectEqual(status_item.Operation.installing, current.phase);
    try std.testing.expectEqualDeep(status_item.ByteProgress{ .completed = 100, .total = 1_000 }, current.bytes.?);

    // The prose mining this replaced read "retry 2/5" as 2/5 bytes.
    runner.onChannelEvent(.{ .operation = .{ .retrying = .{ .attempt = 2, .budget = 5, .delay_ms = 4_000, .bytes = .{ .completed = 100, .total = 1_000 } } } });
    current = runner.current().?;
    try std.testing.expectEqualDeep(status_item.ByteProgress{ .completed = 100, .total = 1_000 }, current.bytes.?);

    runner.onChannelEvent(.{ .operation = .{ .verifying = .{ .completed = 1_000, .total = 1_000 } } });
    try std.testing.expectEqual(status_item.Operation.verifying, runner.current().?.phase);
}

test "a typed failure beats trailing stderr prose" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    runner.startAction(.install);
    runner.onChannelEvent(.{ .failed = "ModelDownloadRejected" });
    runner.onStderr("--install-model: ModelDownloadRejected"); // prose may still trail in
    runner.onTerminal(false);

    const current = runner.current().?;
    try std.testing.expectEqual(status_item.Operation.failed, current.phase);
    try std.testing.expectEqualStrings("ModelDownloadRejected", current.failure_detail.?.value());
}

// ---- orchestration policy -------------------------------------------------------

test "each action maps to its argv, confirmation, and initial phase" {
    const Case = struct { action: ModelAction, argument: []const u8, confirmation: ?[]const u8, phase: status_item.Operation };
    const cases = [_]Case{
        .{ .action = .install, .argument = "--install-model", .confirmation = null, .phase = .installing },
        .{ .action = .update, .argument = "--update-model", .confirmation = null, .phase = .updating },
        .{ .action = .resume_operation, .argument = "--resume-model", .confirmation = null, .phase = .installing },
        .{ .action = .discard, .argument = "--discard-model", .confirmation = null, .phase = .discarding },
        .{ .action = .verify, .argument = "--verify-model", .confirmation = null, .phase = .verifying },
        .{ .action = .repair, .argument = "--repair-model", .confirmation = "yes\n", .phase = .installing },
        .{ .action = .remove, .argument = "--remove-model", .confirmation = "remove\n", .phase = .removing },
    };
    for (cases) |case| {
        var deps = FakeDeps{};
        var runner = TestRunner.init(&deps);
        runner.startAction(case.action);
        const launched = deps.lastLaunch().?;
        try std.testing.expectEqualStrings(case.argument, launched.argument);
        if (case.confirmation) |expected|
            try std.testing.expectEqualStrings(expected, launched.confirmation.?)
        else
            try std.testing.expect(launched.confirmation == null);
        try std.testing.expectEqual(case.phase, runner.current().?.phase);
    }
}

test "the busy guard admits one operation at a time" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    runner.startAction(.install);
    runner.startAction(.update); // dropped — an operation is already in flight
    try std.testing.expectEqual(@as(usize, 1), deps.launch_count);
    try std.testing.expectEqual(status_item.Operation.installing, runner.current().?.phase);

    runner.onTerminal(true); // the slot frees on the terminal outcome
    runner.startAction(.update);
    try std.testing.expectEqual(@as(usize, 2), deps.launch_count);
}

test "a failed launch leaves nothing observed" {
    var deps = FakeDeps{ .launch_fails = true };
    var runner = TestRunner.init(&deps);
    runner.startAction(.install);
    try std.testing.expectEqual(@as(usize, 0), deps.launch_count);
    try std.testing.expect(runner.current() == null); // never began — no phantom operation
}

test "retry_operation resolves to the original failed action" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    runner.startAction(.update);
    runner.onTerminal(false); // failed
    try std.testing.expectEqual(ModelAction.update, runner.retryAction().?);

    runner.startAction(.retry_operation);
    try std.testing.expectEqualStrings("--update-model", deps.lastLaunch().?.argument);
    try std.testing.expectEqual(status_item.Operation.updating, runner.current().?.phase);
}

test "retry with nothing to retry is a no-op" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    try std.testing.expect(runner.retryAction() == null); // idle: nothing to retry
    runner.startAction(.retry_operation);
    try std.testing.expectEqual(@as(usize, 0), deps.launch_count);
}

test "cancel routing kills a cancellable operation and classifies it cancelled" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    runner.startAction(.install); // .installing is cancellable
    try std.testing.expect(runner.requestCancel());
    try std.testing.expectEqual(@as(usize, 1), deps.kill_count);
    try std.testing.expectEqual(deps.lastLaunch().?.pid, deps.kills[0]);

    runner.onTerminal(false); // the killed child exits non-zero
    try std.testing.expectEqual(status_item.Operation.cancelled, runner.current().?.phase);
}

test "cancel is refused when idle or in a non-cancellable phase" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);
    try std.testing.expect(!runner.requestCancel()); // nothing running
    try std.testing.expectEqual(@as(usize, 0), deps.kill_count);

    runner.startAction(.remove); // .removing is not cancellable
    try std.testing.expect(!runner.requestCancel());
    try std.testing.expectEqual(@as(usize, 0), deps.kill_count);
}

test "terminal outcomes classify as success, failure, or cancellation" {
    // Success clears the observation — nothing for the Status Item to show.
    {
        var deps = FakeDeps{};
        var runner = TestRunner.init(&deps);
        runner.startAction(.install);
        runner.onTerminal(true);
        try std.testing.expect(runner.current() == null);
        try std.testing.expect(deps.sawFinished(.install, true));
    }
    // A plain non-zero exit is a failure.
    {
        var deps = FakeDeps{};
        var runner = TestRunner.init(&deps);
        runner.startAction(.install);
        runner.onTerminal(false);
        try std.testing.expectEqual(status_item.Operation.failed, runner.current().?.phase);
        try std.testing.expect(deps.sawFinished(.install, false));
    }
    // A non-zero exit after a requested cancel is a cancellation.
    {
        var deps = FakeDeps{};
        var runner = TestRunner.init(&deps);
        runner.startAction(.install);
        _ = runner.requestCancel();
        runner.onTerminal(false);
        try std.testing.expectEqual(status_item.Operation.cancelled, runner.current().?.phase);
    }
}

test "a full install lifecycle drives phase, bytes, prose, and a clean finish" {
    var deps = FakeDeps{};
    var runner = TestRunner.init(&deps);

    runner.startAction(.install);
    try std.testing.expectEqual(status_item.Operation.installing, runner.current().?.phase);
    try std.testing.expect(runner.current().?.bytes == null); // no progress yet

    runner.onChannelEvent(.{ .operation = .{ .downloading = .{ .completed = 500, .total = 1_000 } } });
    try std.testing.expectEqualDeep(status_item.ByteProgress{ .completed = 500, .total = 1_000 }, runner.current().?.bytes.?);

    runner.onChannelEvent(.{ .operation = .{ .verifying = .{ .completed = 1_000, .total = 1_000 } } });
    try std.testing.expectEqual(status_item.Operation.verifying, runner.current().?.phase);

    runner.onChannelEvent(.{ .operation = .smoke_testing });
    try std.testing.expectEqual(status_item.Operation.smoke_testing, runner.current().?.phase);
    try std.testing.expect(runner.current().?.bytes == null); // a smoke test reports no bytes

    runner.onChannelEvent(.{ .operation = .activating });
    try std.testing.expectEqual(status_item.Operation.activating, runner.current().?.phase);

    runner.onStderr("Model Operation: preparing model files"); // progress prose, not a failure
    runner.onTerminal(true);
    try std.testing.expect(runner.current() == null); // success clears the observation
    try std.testing.expect(deps.sawStderr("Model Operation: preparing model files"));
    try std.testing.expect(deps.sawFinished(.install, true));
}
