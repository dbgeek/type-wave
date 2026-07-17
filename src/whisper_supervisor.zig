const std = @import("std");
const core = @import("whisper_helper_core.zig");
const ipc = @import("whisper_ipc.zig");

pub const State = enum { starting, ready, busy, failed };

pub const Event = union(enum) {
    ready,
    final: []const u8,
    startup_failed: ipc.Diagnostic,
    failed: ipc.Diagnostic,
};

/// Automatic helper-recovery budget. Recovery attempts are delayed by one, two, and
/// four seconds. If all three attempts fail, automatic recovery latches until an explicit
/// reset (Retry/backend reselection) or a successful Final Transcript.
pub const RecoveryBudget = struct {
    consecutive_failures: u8 = 0,

    const delays_ms = [_]u32{ 1_000, 2_000, 4_000 };

    pub fn failed(self: *RecoveryBudget) ?u32 {
        if (self.latched()) return null;
        const delay = delays_ms[self.consecutive_failures];
        self.consecutive_failures += 1;
        return delay;
    }

    pub fn latched(self: RecoveryBudget) bool {
        return self.consecutive_failures == delays_ms.len;
    }

    pub fn reset(self: *RecoveryBudget) void {
        self.* = .{};
    }

    pub fn receivedFinal(self: *RecoveryBudget, text: []const u8) void {
        if (text.len != 0) self.reset();
    }
};

pub const Supervisor = struct {
    state: State = .starting,
    expected_digest: [32]u8,
    active_id: ?u64 = null,

    pub fn init(expected_digest: [32]u8) Supervisor {
        return .{ .expected_digest = expected_digest };
    }

    pub fn begin(self: *Supervisor, id: u64) !void {
        if (self.state != .ready) return error.NotReady;
        self.state = .busy;
        self.active_id = id;
    }

    pub fn receive(self: *Supervisor, frame: ipc.Frame) !Event {
        switch (self.state) {
            .starting => switch (frame) {
                .ready => |digest| {
                    if (!std.mem.eql(u8, &digest, &self.expected_digest)) {
                        self.state = .failed;
                        return error.ModelIdentityMismatch;
                    }
                    self.state = .ready;
                    return .ready;
                },
                .startup_failed => |failure| {
                    self.state = .failed;
                    return .{ .startup_failed = failure };
                },
                else => {
                    self.state = .failed;
                    return error.UnexpectedFrame;
                },
            },
            .busy => switch (frame) {
                .final => |final| {
                    if (final.id != self.active_id.?) {
                        self.fail();
                        return error.RequestIdentityMismatch;
                    }
                    self.finish();
                    return .{ .final = final.text };
                },
                .failed => |failure| {
                    if (failure.id != self.active_id.?) {
                        self.fail();
                        return error.RequestIdentityMismatch;
                    }
                    self.finish();
                    return .{ .failed = .{ .code = failure.code, .message = failure.message } };
                },
                else => {
                    self.fail();
                    return error.UnexpectedFrame;
                },
            },
            .ready, .failed => {
                self.fail();
                return error.UnexpectedFrame;
            },
        }
    }

    pub fn protocolFailure(self: *Supervisor) void {
        self.fail();
    }

    fn finish(self: *Supervisor) void {
        self.active_id = null;
        self.state = .ready;
    }

    fn fail(self: *Supervisor) void {
        self.active_id = null;
        self.state = .failed;
    }
};

test "supervisor becomes ready only for the active receipt digest" {
    var supervisor = Supervisor.init(core.pinned_model_sha256);
    try std.testing.expectEqual(State.starting, supervisor.state);
    try std.testing.expectEqual(Event.ready, try supervisor.receive(.{ .ready = core.pinned_model_sha256 }));
    try std.testing.expectEqual(State.ready, supervisor.state);

    var wrong = Supervisor.init(core.pinned_model_sha256);
    var digest = core.pinned_model_sha256;
    digest[0] ^= 0xff;
    try std.testing.expectError(error.ModelIdentityMismatch, wrong.receive(.{ .ready = digest }));
    try std.testing.expectEqual(State.failed, wrong.state);
}

test "supervisor accepts one matching terminal response and rejects stale identities" {
    var supervisor = Supervisor.init(core.pinned_model_sha256);
    _ = try supervisor.receive(.{ .ready = core.pinned_model_sha256 });
    try supervisor.begin(71);

    try std.testing.expectError(error.RequestIdentityMismatch, supervisor.receive(.{ .final = .{ .id = 70, .text = "stale" } }));
    try std.testing.expectEqual(State.failed, supervisor.state);

    var matching = Supervisor.init(core.pinned_model_sha256);
    _ = try matching.receive(.{ .ready = core.pinned_model_sha256 });
    try matching.begin(71);
    try std.testing.expectEqualDeep(Event{ .final = "hello" }, try matching.receive(.{ .final = .{ .id = 71, .text = "hello" } }));
    try std.testing.expectEqual(State.ready, matching.state);
    try std.testing.expectError(error.UnexpectedFrame, matching.receive(.{ .final = .{ .id = 71, .text = "duplicate" } }));
    try std.testing.expectEqual(State.failed, matching.state);
}

test "startup and inference failures stay structured" {
    var startup = Supervisor.init(core.pinned_model_sha256);
    try std.testing.expectEqualDeep(
        Event{ .startup_failed = .{ .code = 4, .message = "load failed" } },
        try startup.receive(.{ .startup_failed = .{ .code = 4, .message = "load failed" } }),
    );
    try std.testing.expectEqual(State.failed, startup.state);

    var inference = Supervisor.init(core.pinned_model_sha256);
    _ = try inference.receive(.{ .ready = core.pinned_model_sha256 });
    try inference.begin(8);
    try std.testing.expectEqualDeep(
        Event{ .failed = .{ .code = 9, .message = "cancelled" } },
        try inference.receive(.{ .failed = .{ .id = 8, .code = 9, .message = "cancelled" } }),
    );
    try std.testing.expectEqual(State.ready, inference.state);
}

test "helper recovery waits 1 2 and 4 seconds then latches after three failed attempts" {
    var recovery = RecoveryBudget{};

    try std.testing.expectEqual(@as(?u32, 1_000), recovery.failed());
    try std.testing.expectEqual(@as(?u32, 2_000), recovery.failed());
    try std.testing.expectEqual(@as(?u32, 4_000), recovery.failed());

    try std.testing.expect(recovery.latched());
    try std.testing.expectEqual(@as(?u32, null), recovery.failed());
}

test "explicit reset and successful Final Transcript restore the recovery budget" {
    var recovery = RecoveryBudget{};
    _ = recovery.failed();
    _ = recovery.failed();

    recovery.reset();
    try std.testing.expectEqual(@as(?u32, 1_000), recovery.failed());
    recovery.receivedFinal("restored");
    try std.testing.expectEqual(@as(?u32, 1_000), recovery.failed());
}

test "empty Final Transcript does not restore the recovery budget" {
    var recovery = RecoveryBudget{};
    _ = recovery.failed();
    recovery.receivedFinal("");
    try std.testing.expectEqual(@as(?u32, 2_000), recovery.failed());
}
