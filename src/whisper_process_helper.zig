//! The parent-side owner of one warm, private Whisper Helper process: it spawns the helper,
//! owns the pipe protocol and the two-lock write discipline, and drives the crash → fail-active
//! → backoff → relaunch recovery ladder, delivering only identity-tagged terminal events. The
//! segmenting `local_backend.Adapter` drives it across the `Helper` seam (whose contract lives
//! with that Adapter as `local_backend.assertHelper`); this file satisfies that contract.

const std = @import("std");
const backend = @import("transcription_backend.zig");
const ipc = @import("whisper_ipc.zig");
const helper_core = @import("whisper_helper_core.zig");
const helper_supervisor = @import("whisper_supervisor.zig");
const local_backend = @import("local_backend.zig");

const HelperEvents = local_backend.Events;

extern "c" fn usleep(usec: c_uint) c_int;

comptime {
    local_backend.assertHelper(ProcessHelper);
}

const startup_timeout_ms: u32 = 15_000;

const StartupRead = struct {
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    frame: ?ipc.Frame = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *StartupRead) void {
        self.frame = ipc.readFd(self.allocator, self.fd) catch |failure| {
            self.failure = failure;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }
};

const ProcessInstance = struct {
    child: std.process.Child,
    stdin_fd: std.c.fd_t,
    stdout_fd: std.c.fd_t,
    supervisor: helper_supervisor.Supervisor,
};

const RecoveredInstance = struct {
    process: ProcessInstance,
    recovery: helper_supervisor.RecoveryBudget,
};

fn spawnWarm(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    model: []const u8,
    artifact: helper_core.Artifact,
    cancel: ?*const std.atomic.Value(bool),
) !ProcessInstance {
    var helper_environment = std.process.Environ.Map.init(allocator);
    defer helper_environment.deinit();
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable, model },
        .environ_map = &helper_environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const stdout_fd = child.stdout.?.handle;
    var startup = StartupRead{ .allocator = allocator, .fd = stdout_fd };
    const reader = try std.Thread.spawn(.{}, StartupRead.run, .{&startup});
    var waited_ms: u32 = 0;
    while (!startup.done.load(.acquire) and waited_ms < startup_timeout_ms) : (waited_ms += 50) {
        if (cancel) |requested| if (requested.load(.acquire)) {
            child.kill(io);
            reader.join();
            if (startup.frame) |*frame| frame.deinit(allocator);
            return error.ModelOperationCancelled;
        };
        _ = usleep(50_000);
    }
    if (!startup.done.load(.acquire)) {
        child.kill(io);
        reader.join();
        if (startup.frame) |*frame| frame.deinit(allocator);
        return error.HelperStartupTimedOut;
    }
    reader.join();
    if (startup.failure) |failure| return failure;
    var frame = startup.frame orelse return error.HelperExitedBeforeReady;
    defer frame.deinit(allocator);

    var supervisor = helper_supervisor.Supervisor.init(artifact.sha256);
    const event = try supervisor.receive(frame);
    if (event != .ready) return error.HelperDidNotBecomeReady;
    return .{
        .child = child,
        .stdin_fd = child.stdin.?.handle,
        .stdout_fd = stdout_fd,
        .supervisor = supervisor,
    };
}

/// Model Operation smoke test: require the isolated helper to hash, load, warm, and emit
/// its matching ready frame, then terminate it before activation publishes the receipt.
pub fn smokeTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    model: []const u8,
    cancel: *const std.atomic.Value(bool),
) !void {
    var process = try spawnWarm(allocator, io, executable, model, helper_core.pinnedArtifact(), cancel);
    process.child.kill(io);
}

fn spawnWarmWithRecovery(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    model: []const u8,
    artifact: helper_core.Artifact,
) !RecoveredInstance {
    var recovery = helper_supervisor.RecoveryBudget{};
    while (true) {
        const process = spawnWarm(allocator, io, executable, model, artifact, null) catch |failure| {
            const delay = recovery.failed() orelse return failure;
            var waited_ms: u32 = 0;
            while (waited_ms < delay) : (waited_ms += 50) _ = usleep(50_000);
            continue;
        };
        return .{ .process = process, .recovery = recovery };
    }
}

/// One warm, private helper process. It owns the pipe protocol and delivers only
/// identity-tagged terminal events; the Adapter above owns Capture buffering.
pub const ProcessHelper = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_fd: std.c.fd_t,
    stdout_fd: std.c.fd_t,
    supervisor: helper_supervisor.Supervisor,
    lease_id: ?backend.UtteranceId = null,
    executable: []u8,
    model: []u8,
    artifact: helper_core.Artifact,
    mu: std.Io.Mutex = .init,
    write_mu: std.Io.Mutex = .init,
    events: ?HelperEvents = null,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    recovery: helper_supervisor.RecoveryBudget = .{},
    failure_in_progress: bool = false,
    recovering: bool = false,
    generation: u64 = 1,
    forced_terminations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    recovery_schedules: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const TerminalNotification = struct {
        events: HelperEvents,
        id: backend.UtteranceId,
    };

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        executable: []const u8,
        model: []const u8,
        artifact: helper_core.Artifact,
    ) !*ProcessHelper {
        const recovered = try spawnWarmWithRecovery(allocator, io, executable, model, artifact);
        var instance = recovered.process;
        errdefer instance.child.kill(io);

        const self = try allocator.create(ProcessHelper);
        errdefer allocator.destroy(self);
        const executable_copy = try allocator.dupe(u8, executable);
        errdefer allocator.free(executable_copy);
        const model_copy = try allocator.dupe(u8, model);
        errdefer allocator.free(model_copy);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = instance.child,
            .stdin_fd = instance.stdin_fd,
            .stdout_fd = instance.stdout_fd,
            .supervisor = instance.supervisor,
            .executable = executable_copy,
            .model = model_copy,
            .artifact = artifact,
            .recovery = recovered.recovery,
        };

        self.ready.store(true, .release);

        const reader = try std.Thread.spawn(.{}, readerLoop, .{self});
        reader.detach();
        return self;
    }

    pub fn setEvents(self: *ProcessHelper, events: HelperEvents) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.events = events;
    }

    pub fn isReady(self: *ProcessHelper) bool {
        return self.ready.load(.acquire);
    }

    pub fn usesModel(self: *const ProcessHelper, model: []const u8) bool {
        return std.mem.eql(u8, self.model, model);
    }

    pub fn reserveUtterance(self: *ProcessHelper, id: backend.UtteranceId) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.ready.load(.acquire)) return error.NotReady;
        if (self.lease_id != null) return error.Busy;
        self.lease_id = id;
    }

    pub fn submit(self: *ProcessHelper, id: backend.UtteranceId, language: ipc.Language, prompt: []const u8, pcm: []const u8) !void {
        // The glossary prompt (docs/vocab-biasing-spec.md §5) is copied alongside the PCM and
        // owned by the write worker, so it survives the caller's synchronously-freed buffers.
        const owned_prompt = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(owned_prompt);
        const owned_pcm = try self.allocator.dupe(u8, pcm);
        errdefer self.allocator.free(owned_pcm);

        self.mu.lockUncancelable(self.io);
        if (!self.ready.load(.acquire)) {
            self.mu.unlock(self.io);
            return error.NotReady;
        }
        if (self.lease_id != id) {
            self.mu.unlock(self.io);
            return error.WrongUtterance;
        }
        self.supervisor.begin(id) catch |failure| {
            self.mu.unlock(self.io);
            return failure;
        };
        const generation = self.generation;
        const fd = self.stdin_fd;
        self.mu.unlock(self.io);

        const writer = std.Thread.spawn(.{}, submitWorker, .{ self, id, language, owned_prompt, owned_pcm, generation, fd }) catch |failure| {
            self.mu.lockUncancelable(self.io);
            if (self.generation == generation and self.supervisor.active_id == id)
                _ = self.failActiveLocked(id);
            self.mu.unlock(self.io);
            return failure;
        };
        writer.detach();
    }

    fn submitWorker(
        self: *ProcessHelper,
        id: backend.UtteranceId,
        language: ipc.Language,
        prompt: []u8,
        pcm: []u8,
        generation: u64,
        fd: std.c.fd_t,
    ) void {
        defer self.allocator.free(prompt);
        defer self.allocator.free(pcm);
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        self.mu.lockUncancelable(self.io);
        const current = self.generation == generation and self.supervisor.active_id == id;
        self.mu.unlock(self.io);
        if (!current) return;
        ipc.writeFd(self.allocator, fd, .{
            .transcribe = .{ .id = id, .language = language, .prompt = prompt, .pcm = pcm },
        }) catch self.writeFailed(id, generation);
    }

    pub fn requestCancel(self: *ProcessHelper, id: backend.UtteranceId) void {
        self.mu.lockUncancelable(self.io);
        if (!self.ready.load(.acquire) or self.supervisor.active_id != id) {
            self.mu.unlock(self.io);
            return;
        }
        const generation = self.generation;
        const fd = self.stdin_fd;
        self.mu.unlock(self.io);

        const writer = std.Thread.spawn(.{}, cancelWorker, .{ self, id, generation, fd }) catch return;
        writer.detach();
    }

    fn cancelWorker(self: *ProcessHelper, id: backend.UtteranceId, generation: u64, fd: std.c.fd_t) void {
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        self.mu.lockUncancelable(self.io);
        const current = self.generation == generation and self.supervisor.active_id == id;
        self.mu.unlock(self.io);
        if (!current) return;
        ipc.writeFd(self.allocator, fd, .{ .cancel = id }) catch self.writeFailed(id, generation);
    }

    fn writeFailed(self: *ProcessHelper, id: backend.UtteranceId, generation: u64) void {
        self.mu.lockUncancelable(self.io);
        const failed = if (self.generation == generation and self.supervisor.active_id == id)
            self.failActiveLocked(id)
        else
            null;
        self.mu.unlock(self.io);
        if (failed) |value| value.events.failed(value.events.ctx, value.id);
    }

    /// Hard cancellation is the Coordinator's 10-second terminal action. It never waits
    /// behind an IPC write: killing the process closes the pipe and wakes any blocked writer.
    pub fn cancel(self: *ProcessHelper, id: backend.UtteranceId) void {
        self.mu.lockUncancelable(self.io);
        if (self.lease_id != id) {
            self.mu.unlock(self.io);
            return;
        }
        if (self.supervisor.active_id == id) {
            _ = self.failActiveLocked(id);
            _ = self.forced_terminations.fetchAdd(1, .release);
        } else self.lease_id = null;
        self.mu.unlock(self.io);
    }

    pub fn shutdown(self: *ProcessHelper) void {
        self.stopped.store(true, .release);
        self.ready.store(false, .release);
        self.mu.lockUncancelable(self.io);
        self.child.kill(self.io);
        self.mu.unlock(self.io);
    }

    /// Explicit Retry. Backend reselection obtains the same reset by constructing a fresh
    /// helper. A healthy helper ignores Retry; a latched helper starts a new recovery chain.
    pub fn retry(self: *ProcessHelper) void {
        self.mu.lockUncancelable(self.io);
        if (self.ready.load(.acquire) or self.stopped.load(.acquire)) {
            self.mu.unlock(self.io);
            return;
        }
        self.recovery.reset();
        if (self.recovering) {
            self.mu.unlock(self.io);
            return;
        }
        self.recovering = true;
        self.mu.unlock(self.io);
        const thread = std.Thread.spawn(.{}, recoveryEntry, .{self}) catch {
            self.mu.lockUncancelable(self.io);
            self.recovering = false;
            self.mu.unlock(self.io);
            return;
        };
        thread.detach();
    }

    fn readerLoop(self: *ProcessHelper) void {
        while (!self.stopped.load(.acquire)) {
            var frame = ipc.readFd(self.allocator, self.stdout_fd) catch {
                if (!self.handleProcessFailure(null)) return;
                continue;
            } orelse {
                if (!self.handleProcessFailure(null)) return;
                continue;
            };
            defer frame.deinit(self.allocator);

            self.mu.lockUncancelable(self.io);
            const active_id = self.supervisor.active_id;
            const event = self.supervisor.receive(frame) catch {
                const failed = self.beginProcessFailureLocked(active_id);
                self.mu.unlock(self.io);
                if (!self.finishProcessFailure(failed)) return;
                continue;
            };

            switch (event) {
                .final => |text| {
                    const id = active_id.?;
                    self.lease_id = null;
                    self.recovery.receivedFinal(text);
                    const events = self.events;
                    self.mu.unlock(self.io);
                    if (events) |sink| sink.final(sink.ctx, id, text);
                },
                .failed => {
                    const failed = self.beginProcessFailureLocked(active_id);
                    self.mu.unlock(self.io);
                    if (!self.finishProcessFailure(failed)) return;
                },
                else => unreachable,
            }
        }
    }

    /// Returns false when the recovery budget has latched or shutdown has begun.
    fn handleProcessFailure(self: *ProcessHelper, known_id: ?backend.UtteranceId) bool {
        self.mu.lockUncancelable(self.io);
        const failed = self.beginProcessFailureLocked(known_id);
        self.mu.unlock(self.io);
        return self.finishProcessFailure(failed);
    }

    fn beginProcessFailureLocked(self: *ProcessHelper, known_id: ?backend.UtteranceId) ?TerminalNotification {
        const failed = self.failActiveLocked(known_id);
        self.recovering = true;
        _ = self.recovery_schedules.fetchAdd(1, .release);
        return failed;
    }

    fn finishProcessFailure(self: *ProcessHelper, failed: ?TerminalNotification) bool {
        if (failed) |value| value.events.failed(value.events.ctx, value.id);
        return self.recover();
    }

    fn recoveryEntry(self: *ProcessHelper) void {
        if (self.recover()) self.readerLoop();
    }

    fn recover(self: *ProcessHelper) bool {
        while (!self.stopped.load(.acquire)) {
            self.mu.lockUncancelable(self.io);
            const delay = self.recovery.failed() orelse {
                self.recovering = false;
                self.mu.unlock(self.io);
                return false;
            };
            const terminal = self.recovery.latched();
            self.mu.unlock(self.io);

            var waited_ms: u32 = 0;
            while (waited_ms < delay and !self.stopped.load(.acquire)) : (waited_ms += 50)
                _ = usleep(50_000);
            if (self.stopped.load(.acquire)) return false;
            self.launch() catch {
                if (terminal) {
                    self.mu.lockUncancelable(self.io);
                    self.recovering = false;
                    self.mu.unlock(self.io);
                    return false;
                }
                continue;
            };
            self.mu.lockUncancelable(self.io);
            self.recovering = false;
            self.mu.unlock(self.io);
            return true;
        }
        return false;
    }

    fn launch(self: *ProcessHelper) !void {
        var instance = try spawnWarm(self.allocator, self.io, self.executable, self.model, self.artifact, null);
        errdefer instance.child.kill(self.io);

        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopped.load(.acquire)) return error.ShuttingDown;
        self.child = instance.child;
        self.stdin_fd = instance.stdin_fd;
        self.stdout_fd = instance.stdout_fd;
        self.supervisor = instance.supervisor;
        self.failure_in_progress = false;
        self.generation +%= 1;
        self.ready.store(true, .release);
    }

    fn failActiveLocked(self: *ProcessHelper, known_id: ?backend.UtteranceId) ?TerminalNotification {
        if (self.failure_in_progress) return null;
        self.failure_in_progress = true;
        self.generation +%= 1;
        const id = known_id orelse self.supervisor.active_id orelse self.lease_id;
        self.lease_id = null;
        _ = self.failLocked();
        self.child.kill(self.io);
        if (id) |active_id| if (self.events) |events| return .{ .events = events, .id = active_id };
        return null;
    }

    fn failLocked(self: *ProcessHelper) ?HelperEvents {
        self.ready.store(false, .release);
        self.supervisor.protocolFailure();
        return self.events;
    }
};

test "hard cancellation terminates a non-responsive helper process" {
    var helper = try ProcessHelper.start(
        std.testing.allocator,
        std.testing.io,
        "acceptance/local_backend/stalling_helper.py",
        "stall",
        helper_core.pinnedArtifact(),
    );
    defer {
        helper.shutdown();
        _ = usleep(200_000);
        std.testing.allocator.free(helper.executable);
        std.testing.allocator.free(helper.model);
        std.testing.allocator.destroy(helper);
    }
    try helper.reserveUtterance(991);
    try helper.submit(991, .english, "", &.{ 0, 0, 0, 0 });

    const started = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    _ = usleep(9_500_000);
    const cooperative_ms: u64 = @intCast(@divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - started, 1_000_000));
    helper.requestCancel(991);
    const remaining_ns = 10_000_000_000 -| (std.Io.Clock.now(.awake, std.testing.io).nanoseconds - started);
    if (remaining_ns > 0) _ = usleep(@intCast(@divTrunc(remaining_ns, 1_000)));
    helper.cancel(991);
    const terminated_ms: u64 = @intCast(@divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - started, 1_000_000));
    std.debug.print("ACCEPTANCE_TIMEOUT cooperative_ms={d} terminated_ms={d}\n", .{ cooperative_ms, terminated_ms });

    try std.testing.expectEqual(@as(usize, 1), helper.forced_terminations.load(.acquire));
    try std.testing.expect(!helper.isReady());
}

const AtomicFaultRecorder = struct {
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn events(self: *AtomicFaultRecorder) local_backend.Events {
        return .{ .ctx = self, .final = final, .failed = failed };
    }
    fn final(_: *anyopaque, _: backend.UtteranceId, _: []const u8) void {}
    fn failed(ctx: *anyopaque, _: backend.UtteranceId) void {
        const self: *AtomicFaultRecorder = @ptrCast(@alignCast(ctx));
        _ = self.failures.fetchAdd(1, .release);
    }
};

test "helper crash malformed IPC and inference failure abandon active Utterances and schedule restart" {
    for ([_][]const u8{ "crash", "malformed", "inference" }) |mode| {
        var helper = try ProcessHelper.start(
            std.testing.allocator,
            std.testing.io,
            "acceptance/local_backend/stalling_helper.py",
            mode,
            helper_core.pinnedArtifact(),
        );
        var events = AtomicFaultRecorder{};
        var adapter = local_backend.Adapter(ProcessHelper).init(std.testing.allocator, std.testing.io, helper, events.events());
        adapter.bindHelperEvents();
        defer adapter.deinit();

        try adapter.begin(881, "en", &.{});
        try adapter.appendAudio(881, &.{ 0, 0, 0, 0 });
        try adapter.release(881);
        var waited_ms: usize = 0;
        while (events.failures.load(.acquire) == 0 and waited_ms < 1_000) : (waited_ms += 10) _ = usleep(10_000);

        try std.testing.expectEqual(@as(usize, 1), events.failures.load(.acquire));
        try std.testing.expect(adapter.active_id == null);
        try std.testing.expect(helper.recovery_schedules.load(.acquire) >= 1);

        helper.shutdown();
        _ = usleep(200_000);
        std.testing.allocator.free(helper.executable);
        std.testing.allocator.free(helper.model);
        std.testing.allocator.destroy(helper);
    }
}
