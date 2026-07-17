//! Complete-Utterance adapter for the local KB Whisper Transcription Backend.

const std = @import("std");
const backend = @import("transcription_backend.zig");
const ipc = @import("whisper_ipc.zig");
const helper_core = @import("whisper_helper_core.zig");
const helper_supervisor = @import("whisper_supervisor.zig");
const coordinator = @import("coordinator.zig");

pub const local_deadline = backend.DeadlinePolicy{ .final_ms = 10_000 };

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

/// One warm, private helper process. It owns the pipe protocol and delivers only
/// identity-tagged terminal events; the Adapter above owns Capture buffering.
pub const ProcessHelper = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_fd: std.c.fd_t,
    stdout_fd: std.c.fd_t,
    supervisor: helper_supervisor.Supervisor,
    mu: std.Io.Mutex = .init,
    events: ?HelperEvents = null,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        executable: []const u8,
        model: []const u8,
    ) !*ProcessHelper {
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

        const self = try allocator.create(ProcessHelper);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
            .supervisor = helper_supervisor.Supervisor.init(helper_core.pinned_model_sha256),
        };

        var frame = (try ipc.readFd(allocator, self.stdout_fd)) orelse
            return error.HelperExitedBeforeReady;
        defer frame.deinit(allocator);
        const event = try self.supervisor.receive(frame);
        if (event != .ready) return error.HelperDidNotBecomeReady;
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

    pub fn submit(self: *ProcessHelper, id: backend.UtteranceId, language: ipc.Language, pcm: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.ready.load(.acquire)) return error.NotReady;
        try self.supervisor.begin(id);
        ipc.writeFd(self.allocator, self.stdin_fd, .{
            .transcribe = .{ .id = id, .language = language, .pcm = pcm },
        }) catch |failure| {
            _ = self.failLocked();
            return failure;
        };
    }

    pub fn cancel(self: *ProcessHelper, id: backend.UtteranceId) void {
        self.mu.lockUncancelable(self.io);
        if (!self.ready.load(.acquire)) {
            self.mu.unlock(self.io);
            return;
        }
        ipc.writeFd(self.allocator, self.stdin_fd, .{ .cancel = id }) catch {
            _ = self.failLocked();
            self.mu.unlock(self.io);
            return;
        };
        self.mu.unlock(self.io);
    }

    pub fn shutdown(self: *ProcessHelper) void {
        self.ready.store(false, .release);
        self.child.kill(self.io);
    }

    fn readerLoop(self: *ProcessHelper) void {
        while (true) {
            var frame = ipc.readFd(self.allocator, self.stdout_fd) catch {
                self.protocolFailed();
                return;
            } orelse {
                self.protocolFailed();
                return;
            };
            defer frame.deinit(self.allocator);

            const id: backend.UtteranceId = switch (frame) {
                .final => |value| value.id,
                .failed => |value| value.id,
                else => {
                    self.protocolFailed();
                    return;
                },
            };
            self.mu.lockUncancelable(self.io);
            const event = self.supervisor.receive(frame) catch {
                const sink = self.failLocked();
                self.mu.unlock(self.io);
                if (sink) |events| events.failed(events.ctx, id);
                return;
            };
            const events = self.events;
            self.mu.unlock(self.io);

            if (events) |sink| switch (event) {
                .final => |text| sink.final(sink.ctx, id, text),
                .failed => sink.failed(sink.ctx, id),
                else => unreachable,
            };
        }
    }

    fn protocolFailed(self: *ProcessHelper) void {
        self.mu.lockUncancelable(self.io);
        const id = self.supervisor.active_id orelse {
            self.ready.store(false, .release);
            self.supervisor.protocolFailure();
            self.mu.unlock(self.io);
            return;
        };
        const sink = self.failLocked();
        self.mu.unlock(self.io);
        if (sink) |events| events.failed(events.ctx, id);
    }

    fn failLocked(self: *ProcessHelper) ?HelperEvents {
        self.ready.store(false, .release);
        self.supervisor.protocolFailure();
        return self.events;
    }
};

const FakeHelper = struct {
    submits: usize = 0,
    id: backend.UtteranceId = 0,
    language: ipc.Language = .english,
    pcm: [32]u8 = undefined,
    pcm_len: usize = 0,
    cancels: usize = 0,

    fn isReady(_: *FakeHelper) bool {
        return true;
    }
    fn setEvents(_: *FakeHelper, _: HelperEvents) void {}

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
