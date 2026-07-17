//! Complete-Utterance adapter for the local KB Whisper Transcription Backend.

const std = @import("std");
const backend = @import("transcription_backend.zig");
const ipc = @import("whisper_ipc.zig");
const helper_core = @import("whisper_helper_core.zig");
const helper_supervisor = @import("whisper_supervisor.zig");
const coordinator = @import("coordinator.zig");

extern "c" fn usleep(usec: c_uint) c_int;

pub const local_deadline = backend.DeadlinePolicy{ .cooperative_cancel_ms = 9_500, .final_ms = 10_000 };

pub const Events = struct {
    ctx: *anyopaque,
    final: *const fn (*anyopaque, backend.UtteranceId, []const u8) void,
    failed: *const fn (*anyopaque, backend.UtteranceId) void,
};

const HelperEvents = Events;

pub fn Adapter(comptime Helper: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        helper: *Helper,
        events: Events,
        mu: std.Io.Mutex = .init,
        pcm: std.ArrayList(u8) = .empty,
        active_id: ?backend.UtteranceId = null,
        language: ipc.Language = .english,
        released: bool = false,

        const commands = backend.Commands{
            .begin = beginCommand,
            .append_audio = appendCommand,
            .release = releaseCommand,
            .request_cancel = requestCancelCommand,
            .cancel = cancelCommand,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, helper: *Helper, events: Events) Self {
            return .{ .allocator = allocator, .io = io, .helper = helper, .events = events };
        }

        pub fn acquire(self: *Self, id: backend.UtteranceId, language: backend.Language) ?backend.Lease {
            if (!self.isReady()) return null;
            return .{
                .id = id,
                .backend = .local_kb_whisper,
                .language = language,
                .deadline = local_deadline,
                .ctx = self,
                .commands = &commands,
            };
        }

        pub fn bindHelperEvents(self: *Self) void {
            self.helper.setEvents(.{ .ctx = self, .final = helperFinal, .failed = helperFailed });
        }

        pub fn isReady(self: *Self) bool {
            return self.helper.isReady();
        }

        pub fn shutdown(self: *Self) void {
            self.helper.shutdown();
        }

        /// Recovery action exposed for the readiness/Status Item layer.
        pub fn retry(self: *Self) void {
            self.helper.retry();
        }

        pub fn begin(self: *Self, id: backend.UtteranceId, language: backend.Language) !void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != null) return error.Busy;
            if (!self.helper.isReady()) return error.NotReady;
            self.language = if (std.mem.eql(u8, language, "en"))
                .english
            else if (std.mem.eql(u8, language, "sv"))
                .swedish
            else if (language.len == 0)
                .auto_detect
            else
                return error.UnsupportedLanguage;
            try self.helper.reserveUtterance(id);
            self.pcm.clearRetainingCapacity();
            self.active_id = id;
            self.released = false;
        }

        pub fn appendAudio(self: *Self, id: backend.UtteranceId, pcm: []const u8) !void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != id or self.released) return error.WrongUtterance;
            if (self.pcm.items.len + pcm.len > @import("whisper_helper_core.zig").max_pcm_len)
                return error.CaptureTooLong;
            try self.pcm.appendSlice(self.allocator, pcm);
        }

        pub fn release(self: *Self, id: backend.UtteranceId) !void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != id or self.released) return error.WrongUtterance;
            if (self.pcm.items.len == 0) return error.EmptyCapture;
            try self.helper.submit(id, self.language, self.pcm.items);
            self.pcm.clearRetainingCapacity();
            self.released = true;
        }

        pub fn cancel(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != id) return;
            if (self.released) self.helper.cancel(id);
            self.pcm.clearRetainingCapacity();
            self.active_id = null;
            self.released = false;
        }

        pub fn requestCancel(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id == id and self.released) self.helper.requestCancel(id);
        }

        pub fn receiveFinal(self: *Self, id: backend.UtteranceId, text: []const u8) void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id != id or !self.released) {
                self.mu.unlock(self.io);
                return;
            }
            self.mu.unlock(self.io);
            self.events.final(self.events.ctx, id, text);
            self.clearAfterTerminal(id);
        }

        pub fn receiveFailed(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            if (self.active_id != id) {
                self.mu.unlock(self.io);
                return;
            }
            self.mu.unlock(self.io);
            self.events.failed(self.events.ctx, id);
            self.clearAfterTerminal(id);
        }

        fn clearAfterTerminal(self: *Self, id: backend.UtteranceId) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.active_id != id) return; // Coordinator cancellation already cleared it.
            self.pcm.clearRetainingCapacity();
            self.active_id = null;
            self.released = false;
        }

        fn from(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }
        fn beginCommand(ctx: *anyopaque, id: backend.UtteranceId, language: backend.Language) !void {
            try from(ctx).begin(id, language);
        }
        fn appendCommand(ctx: *anyopaque, id: backend.UtteranceId, pcm: []const u8) !void {
            try from(ctx).appendAudio(id, pcm);
        }
        fn releaseCommand(ctx: *anyopaque, id: backend.UtteranceId) !void {
            try from(ctx).release(id);
        }
        fn requestCancelCommand(ctx: *anyopaque, id: backend.UtteranceId) void {
            from(ctx).requestCancel(id);
        }
        fn cancelCommand(ctx: *anyopaque, id: backend.UtteranceId) void {
            from(ctx).cancel(id);
        }
        fn helperFinal(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
            from(ctx).receiveFinal(id, text);
        }
        fn helperFailed(ctx: *anyopaque, id: backend.UtteranceId) void {
            from(ctx).receiveFailed(id);
        }
    };
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

    var supervisor = helper_supervisor.Supervisor.init(helper_core.pinned_model_sha256);
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
    var process = try spawnWarm(allocator, io, executable, model, cancel);
    process.child.kill(io);
}

fn spawnWarmWithRecovery(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    model: []const u8,
) !RecoveredInstance {
    var recovery = helper_supervisor.RecoveryBudget{};
    while (true) {
        const process = spawnWarm(allocator, io, executable, model, null) catch |failure| {
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
    mu: std.Io.Mutex = .init,
    write_mu: std.Io.Mutex = .init,
    events: ?HelperEvents = null,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    recovery: helper_supervisor.RecoveryBudget = .{},
    failure_in_progress: bool = false,
    recovering: bool = false,
    generation: u64 = 1,

    const TerminalNotification = struct {
        events: HelperEvents,
        id: backend.UtteranceId,
    };

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        executable: []const u8,
        model: []const u8,
    ) !*ProcessHelper {
        const recovered = try spawnWarmWithRecovery(allocator, io, executable, model);
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

    pub fn reserveUtterance(self: *ProcessHelper, id: backend.UtteranceId) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.ready.load(.acquire)) return error.NotReady;
        if (self.lease_id != null) return error.Busy;
        self.lease_id = id;
    }

    pub fn submit(self: *ProcessHelper, id: backend.UtteranceId, language: ipc.Language, pcm: []const u8) !void {
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

        const writer = std.Thread.spawn(.{}, submitWorker, .{ self, id, language, owned_pcm, generation, fd }) catch |failure| {
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
        pcm: []u8,
        generation: u64,
        fd: std.c.fd_t,
    ) void {
        defer self.allocator.free(pcm);
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        self.mu.lockUncancelable(self.io);
        const current = self.generation == generation and self.supervisor.active_id == id;
        self.mu.unlock(self.io);
        if (!current) return;
        ipc.writeFd(self.allocator, fd, .{
            .transcribe = .{ .id = id, .language = language, .pcm = pcm },
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
        if (self.supervisor.active_id == id)
            _ = self.failActiveLocked(id)
        else
            self.lease_id = null;
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
        var instance = try spawnWarm(self.allocator, self.io, self.executable, self.model, null);
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

const FakeHelper = struct {
    activations: usize = 0,
    submits: usize = 0,
    id: backend.UtteranceId = 0,
    language: ipc.Language = .english,
    pcm: [32]u8 = undefined,
    pcm_len: usize = 0,
    cancellation_requests: usize = 0,
    cancels: usize = 0,
    retries: usize = 0,

    fn isReady(_: *FakeHelper) bool {
        return true;
    }
    fn setEvents(_: *FakeHelper, _: HelperEvents) void {}
    fn reserveUtterance(self: *FakeHelper, _: backend.UtteranceId) !void {
        self.activations += 1;
    }

    fn submit(self: *FakeHelper, id: backend.UtteranceId, language: ipc.Language, pcm: []const u8) !void {
        self.submits += 1;
        self.id = id;
        self.language = language;
        @memcpy(self.pcm[0..pcm.len], pcm);
        self.pcm_len = pcm.len;
    }
    fn cancel(self: *FakeHelper, _: backend.UtteranceId) void {
        self.cancels += 1;
    }
    fn requestCancel(self: *FakeHelper, _: backend.UtteranceId) void {
        self.cancellation_requests += 1;
    }
    fn retry(self: *FakeHelper) void {
        self.retries += 1;
    }
};

const EventRecorder = struct {
    finals: usize = 0,
    failures: usize = 0,
    id: backend.UtteranceId = 0,
    text: []const u8 = "",

    fn events(self: *EventRecorder) Events {
        return .{ .ctx = self, .final = final, .failed = failed };
    }
    fn final(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        self.finals += 1;
        self.id = id;
        self.text = text;
    }
    fn failed(ctx: *anyopaque, id: backend.UtteranceId) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        self.failures += 1;
        self.id = id;
    }
};

const IntegrationAudio = struct {
    captured: bool = true,
    pub fn start(_: *IntegrationAudio) !void {}
    pub fn stop(_: *IntegrationAudio) void {}
    pub fn capturedAudio(self: *IntegrationAudio) bool {
        return self.captured;
    }
    pub fn heardSound(_: *IntegrationAudio) bool {
        return true;
    }
};

const IntegrationBackends = struct {
    adapter: *Adapter(FakeHelper),
    pub fn acquire(self: *IntegrationBackends, id: backend.UtteranceId) ?backend.Lease {
        return self.adapter.acquire(id, "sv");
    }

    pub fn resolve(_: *IntegrationBackends, _: backend.UtteranceId) void {}
};

const IntegrationInsertion = struct {
    submits: usize = 0,
    id: backend.UtteranceId = 0,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    pub fn submit(self: *IntegrationInsertion, id: backend.UtteranceId, value: []const u8) void {
        self.submits += 1;
        self.id = id;
        @memcpy(self.text[0..value.len], value);
        self.text_len = value.len;
    }
};

const IntegrationDeadline = struct {
    pub fn arm(_: *IntegrationDeadline, _: backend.UtteranceId, _: backend.DeadlinePolicy) void {}
    pub fn cancel(_: *IntegrationDeadline, _: backend.UtteranceId) void {}
};

const IntegrationFeedback = struct {
    abandoned_count: usize = 0,
    pub fn listening(_: *IntegrationFeedback) void {}
    pub fn released(_: *IntegrationFeedback) void {}
    pub fn inserted(_: *IntegrationFeedback) void {}
    pub fn abandoned(self: *IntegrationFeedback) void {
        self.abandoned_count += 1;
    }
};

const IntegrationDeps = struct {
    audio: *IntegrationAudio,
    backends: *IntegrationBackends,
    insertion: *IntegrationInsertion,
    deadline: *IntegrationDeadline,
    feedback: *IntegrationFeedback,
};
const IntegrationCoordinator = coordinator.Coordinator(IntegrationDeps);

const CoordinatorBridge = struct {
    co: *IntegrationCoordinator = undefined,
    fn events(self: *CoordinatorBridge) Events {
        return .{ .ctx = self, .final = final, .failed = failed };
    }
    fn final(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
        const self: *CoordinatorBridge = @ptrCast(@alignCast(ctx));
        self.co.handle(.{ .final = .{ .id = id, .text = text } });
    }
    fn failed(ctx: *anyopaque, id: backend.UtteranceId) void {
        const self: *CoordinatorBridge = @ptrCast(@alignCast(ctx));
        self.co.handle(.{ .backend_failed = id });
    }
};

test "local Transcription Backend buffers complete Capture and submits once after release in every language mode" {
    const cases = .{
        .{ "en", ipc.Language.english },
        .{ "sv", ipc.Language.swedish },
        .{ "", ipc.Language.auto_detect },
    };
    inline for (cases) |case| {
        var helper = FakeHelper{};
        var events = EventRecorder{};
        var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
        defer adapter.pcm.deinit(std.testing.allocator);

        try adapter.begin(41, case[0]);
        try adapter.appendAudio(41, &.{ 1, 2 });
        try adapter.appendAudio(41, &.{ 3, 4, 5, 6 });
        try std.testing.expectEqual(@as(usize, 0), helper.submits);

        try adapter.release(41);
        try std.testing.expectEqual(@as(usize, 1), helper.submits);
        try std.testing.expectEqual(@as(backend.UtteranceId, 41), helper.id);
        try std.testing.expectEqual(case[1], helper.language);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, helper.pcm[0..helper.pcm_len]);
    }
}

test "local Transcription Backend emits only matching terminal events and cancellation never falls back" {
    var helper = FakeHelper{};
    var events = EventRecorder{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, events.events());
    defer adapter.pcm.deinit(std.testing.allocator);

    const empty = adapter.acquire(6, "en").?;
    try empty.begin();
    empty.cancel();
    try std.testing.expectEqual(@as(usize, 0), helper.submits);

    const lease = adapter.acquire(7, "sv").?;
    try lease.begin();
    try lease.appendAudio(&.{ 1, 2 });
    try lease.release();
    lease.requestCancellation();
    try std.testing.expectEqual(@as(usize, 1), helper.cancellation_requests);
    adapter.receiveFinal(6, "stale");
    try std.testing.expectEqual(@as(usize, 0), events.finals);
    adapter.receiveFinal(7, "Hej");
    try std.testing.expectEqual(@as(usize, 1), events.finals);
    try std.testing.expectEqualStrings("Hej", events.text);

    const failed = adapter.acquire(8, "").?;
    try failed.begin();
    try failed.appendAudio(&.{ 3, 4 });
    try failed.release();
    adapter.receiveFailed(8);
    try std.testing.expectEqual(@as(usize, 1), events.failures);

    const cancelled = adapter.acquire(9, "en").?;
    try cancelled.begin();
    try cancelled.appendAudio(&.{ 5, 6 });
    try cancelled.release();
    cancelled.cancel();
    try std.testing.expectEqual(@as(usize, 1), helper.cancels);
    adapter.receiveFinal(9, "late");
    try std.testing.expectEqual(@as(usize, 1), events.finals);

    adapter.retry();
    try std.testing.expectEqual(@as(usize, 1), helper.retries);
}

test "local Transcription Backend drives one Insertion and abandons empty or failed Utterances without OpenAI" {
    var helper = FakeHelper{};
    var bridge = CoordinatorBridge{};
    var adapter = Adapter(FakeHelper).init(std.testing.allocator, std.testing.io, &helper, bridge.events());
    defer adapter.pcm.deinit(std.testing.allocator);
    var audio = IntegrationAudio{};
    var backends = IntegrationBackends{ .adapter = &adapter };
    var insertion = IntegrationInsertion{};
    var deadline = IntegrationDeadline{};
    var surface = IntegrationFeedback{};
    var co = IntegrationCoordinator.init(.{
        .audio = &audio,
        .backends = &backends,
        .insertion = &insertion,
        .deadline = &deadline,
        .feedback = &surface,
    });
    bridge.co = &co;

    co.handle(.press);
    try adapter.appendAudio(1, &.{ 1, 2, 3, 4 });
    co.handle(.release);
    try std.testing.expectEqual(@as(usize, 1), helper.submits);
    adapter.receiveFinal(1, "Hej världen");
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);
    try std.testing.expectEqualStrings("Hej världen", insertion.text[0..insertion.text_len]);
    co.handle(.{ .inserted = .{ .id = 1, .result = .ok } });

    co.handle(.press);
    try adapter.appendAudio(2, &.{ 5, 6 });
    co.handle(.release);
    adapter.receiveFailed(2);
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);

    co.handle(.press);
    try adapter.appendAudio(3, &.{ 7, 8 });
    co.handle(.release);
    adapter.receiveFinal(3, "");
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);
    try std.testing.expectEqual(@as(usize, 2), helper.cancels);

    audio.captured = false;
    co.handle(.press);
    co.handle(.release);
    try std.testing.expectEqual(@as(usize, 3), helper.submits);
    try std.testing.expectEqual(@as(usize, 1), insertion.submits);
    try std.testing.expectEqual(@as(usize, 3), surface.abandoned_count);
}
