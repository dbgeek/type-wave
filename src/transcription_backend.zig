//! Backend-neutral Transcription contract pinned to one accepted Utterance.

const std = @import("std");

pub const UtteranceId = u64;

pub const Backend = enum {
    openai,
    local,
};

/// Empty means automatic language detection. The slice belongs to the immutable
/// Settings Snapshot from which the lease was acquired.
pub const Language = []const u8;

pub const DeadlinePolicy = struct {
    cooperative_cancel_ms: ?u32 = null,
    final_ms: u32,
};

pub const openai_deadline = DeadlinePolicy{ .final_ms = 15_000 };

/// Which wait a deadline bounds. An Utterance arms two in sequence — the
/// release-anchored `.release` deadline (awaiting the Final Transcript) and, under
/// Backtrack, the `.rewrite` budget (docs/backtrack-spec.md §failure policy). The kind
/// rides the fired action so a stale claim of one can never be mistaken for the other:
/// the claim and the Coordinator's phase change race on different locks, and the
/// Utterance id alone does not tell them apart.
pub const DeadlineKind = enum { release, rewrite };

/// Mutable timer state. The real adapter protects this value with one mutex so the
/// fire time, identity, and kind are armed, cancelled, and claimed as one generation.
pub const DeadlineState = struct {
    cooperative_at_ms: i64 = 0,
    fire_at_ms: i64 = 0,
    id: UtteranceId = 0,
    kind: DeadlineKind = .release,

    pub const Action = union(enum) {
        cooperative_cancel: UtteranceId,
        final: struct { id: UtteranceId, kind: DeadlineKind },
    };

    pub fn arm(self: *DeadlineState, id: UtteranceId, kind: DeadlineKind, now_ms: i64, policy: DeadlinePolicy) void {
        self.id = id;
        self.kind = kind;
        self.cooperative_at_ms = if (policy.cooperative_cancel_ms) |delay| now_ms + delay else 0;
        self.fire_at_ms = now_ms + policy.final_ms;
    }

    pub fn cancel(self: *DeadlineState, id: UtteranceId) void {
        if (self.id == id) self.* = .{};
    }

    pub fn claim(self: *DeadlineState, now_ms: i64) ?Action {
        if (self.fire_at_ms == 0) return null;
        if (now_ms >= self.fire_at_ms) {
            const fired = Action{ .final = .{ .id = self.id, .kind = self.kind } };
            self.* = .{};
            return fired;
        }
        if (self.cooperative_at_ms != 0 and now_ms >= self.cooperative_at_ms) {
            self.cooperative_at_ms = 0;
            return .{ .cooperative_cancel = self.id };
        }
        return null;
    }
};

/// Commands implemented by a concrete Transcription Backend. A Lease pins this
/// table, its context, language, and deadline for the full Utterance lifecycle.
pub const Commands = struct {
    begin: *const fn (ctx: *anyopaque, id: UtteranceId, language: Language) anyerror!void,
    append_audio: *const fn (ctx: *anyopaque, id: UtteranceId, pcm: []const u8) anyerror!void,
    release: *const fn (ctx: *anyopaque, id: UtteranceId) anyerror!void,
    request_cancel: *const fn (ctx: *anyopaque, id: UtteranceId) void,
    cancel: *const fn (ctx: *anyopaque, id: UtteranceId) void,
};

pub const Lease = struct {
    id: UtteranceId,
    backend: Backend,
    language: Language,
    deadline: DeadlinePolicy,
    /// Backtrack enablement, read from the Settings Snapshot at Talk Key press and
    /// pinned here by the Backend Router so a mid-Utterance settings flip cannot
    /// half-apply (docs/backtrack-spec.md). The rewrite fires only when this is set
    /// AND `backend == .openai`; the backends themselves never read it.
    backtrack: bool = false,
    ctx: *anyopaque,
    commands: *const Commands,

    pub fn begin(self: Lease) !void {
        try self.commands.begin(self.ctx, self.id, self.language);
    }

    pub fn appendAudio(self: Lease, pcm: []const u8) !void {
        try self.commands.append_audio(self.ctx, self.id, pcm);
    }

    pub fn release(self: Lease) !void {
        try self.commands.release(self.ctx, self.id);
    }

    pub fn requestCancellation(self: Lease) void {
        self.commands.request_cancel(self.ctx, self.id);
    }

    pub fn cancel(self: Lease) void {
        self.commands.cancel(self.ctx, self.id);
    }
};

const Recorder = struct {
    calls: [5]u8 = undefined,
    call_count: usize = 0,
    last_id: UtteranceId = 0,
    last_language: [16]u8 = undefined,
    last_language_len: usize = 0,
    pcm: [16]u8 = undefined,
    pcm_len: usize = 0,

    const commands = Commands{
        .begin = begin,
        .append_audio = appendAudio,
        .release = release,
        .request_cancel = requestCancel,
        .cancel = cancel,
    };

    fn from(ctx: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(ctx));
    }
    fn record(self: *Recorder, call: u8, id: UtteranceId) void {
        self.calls[self.call_count] = call;
        self.call_count += 1;
        self.last_id = id;
    }
    fn begin(ctx: *anyopaque, id: UtteranceId, language: Language) !void {
        const self = from(ctx);
        self.record('b', id);
        @memcpy(self.last_language[0..language.len], language);
        self.last_language_len = language.len;
    }
    fn appendAudio(ctx: *anyopaque, id: UtteranceId, pcm: []const u8) !void {
        const self = from(ctx);
        self.record('a', id);
        @memcpy(self.pcm[0..pcm.len], pcm);
        self.pcm_len = pcm.len;
    }
    fn release(ctx: *anyopaque, id: UtteranceId) !void {
        from(ctx).record('r', id);
    }
    fn requestCancel(ctx: *anyopaque, id: UtteranceId) void {
        from(ctx).record('q', id);
    }
    fn cancel(ctx: *anyopaque, id: UtteranceId) void {
        from(ctx).record('c', id);
    }
};

test "lease pins metadata and forwards identity-tagged backend commands" {
    var recorder = Recorder{};
    const lease = Lease{
        .id = 73,
        .backend = .openai,
        .language = "sv",
        .deadline = .{ .final_ms = 15_000 },
        .ctx = &recorder,
        .commands = &Recorder.commands,
    };

    try lease.begin();
    var borrowed = [_]u8{ 1, 2, 3 };
    try lease.appendAudio(&borrowed);
    borrowed[0] = 99; // adapter consumed/copied the borrowed PCM synchronously
    try lease.release();
    lease.requestCancellation();
    lease.cancel();

    try std.testing.expectEqualStrings("barqc", recorder.calls[0..recorder.call_count]);
    try std.testing.expectEqual(@as(UtteranceId, 73), recorder.last_id);
    try std.testing.expectEqualStrings("sv", recorder.last_language[0..recorder.last_language_len]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, recorder.pcm[0..recorder.pcm_len]);
    try std.testing.expectEqual(Backend.openai, lease.backend);
    try std.testing.expectEqual(@as(u32, 15_000), lease.deadline.final_ms);
}

test "deadline claim cannot borrow the identity or kind of a later arm" {
    var state = DeadlineState{};
    state.arm(1, .release, 1_000, .{ .final_ms = 100 });
    try std.testing.expectEqualDeep(DeadlineState.Action{ .final = .{ .id = 1, .kind = .release } }, state.claim(1_100).?);

    state.arm(1, .rewrite, 1_100, .{ .final_ms = 100 });
    try std.testing.expect(state.claim(1_100) == null);
    try std.testing.expectEqualDeep(DeadlineState.Action{ .final = .{ .id = 1, .kind = .rewrite } }, state.claim(1_200).?);
}

test "deadline cancellation is identity matched" {
    var state = DeadlineState{};
    state.arm(8, .release, 1_000, .{ .final_ms = 100 });
    state.cancel(7);
    try std.testing.expectEqualDeep(DeadlineState.Action{ .final = .{ .id = 8, .kind = .release } }, state.claim(1_100).?);
}

test "local deadline requests cancellation at 9.5 seconds and claims the hard deadline at 10 seconds" {
    var state = DeadlineState{};
    state.arm(73, .release, 1_000, .{ .cooperative_cancel_ms = 9_500, .final_ms = 10_000 });

    try std.testing.expect(state.claim(10_499) == null);
    try std.testing.expectEqualDeep(DeadlineState.Action{ .cooperative_cancel = 73 }, state.claim(10_500).?);
    try std.testing.expect(state.claim(10_999) == null);
    try std.testing.expectEqualDeep(DeadlineState.Action{ .final = .{ .id = 73, .kind = .release } }, state.claim(11_000).?);
    try std.testing.expect(state.claim(11_001) == null);
}
