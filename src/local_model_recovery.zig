//! Decision state for distinguishing Model Installation corruption from helper runtime
//! load failure. The daemon owns effects; this module only says which effect is next.

const std = @import("std");

pub const State = enum(u8) {
    ready,
    verifying,
    retrying_verified_load,
    corrupt,
    runtime_failure,
};

pub const Action = enum { none, verify, load };

pub const Recovery = struct {
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.ready),

    pub fn current(self: *const Recovery) State {
        return self.state.load(.acquire);
    }

    pub fn installationUsable(self: *const Recovery) bool {
        return self.current() != .corrupt;
    }

    pub fn loadFailed(self: *Recovery) Action {
        return switch (self.current()) {
            .ready => action: {
                self.state.store(.verifying, .release);
                break :action .verify;
            },
            .retrying_verified_load => action: {
                self.state.store(.runtime_failure, .release);
                break :action .none;
            },
            .verifying, .corrupt, .runtime_failure => .none,
        };
    }

    pub fn verificationFinished(self: *Recovery, usable: bool) Action {
        if (self.current() != .verifying) return .none;
        self.state.store(if (usable) .retrying_verified_load else .corrupt, .release);
        return if (usable) .load else .none;
    }

    pub fn verificationFailed(self: *Recovery) void {
        if (self.current() == .verifying) self.state.store(.runtime_failure, .release);
    }

    pub fn retry(self: *Recovery) Action {
        return switch (self.current()) {
            .runtime_failure => action: {
                self.state.store(.retrying_verified_load, .release);
                break :action .load;
            },
            .corrupt => action: {
                self.state.store(.verifying, .release);
                break :action .verify;
            },
            else => .none,
        };
    }

    pub fn loadSucceeded(self: *Recovery) void {
        self.state.store(.ready, .release);
    }
};

test "a load failure verifies locally before choosing Repair or runtime Retry" {
    var recovery = Recovery{};

    try std.testing.expectEqual(Action.verify, recovery.loadFailed());
    try std.testing.expectEqual(Action.none, recovery.verificationFinished(false));
    try std.testing.expectEqual(State.corrupt, recovery.current());

    var repaired = Recovery{};
    try std.testing.expectEqual(Action.verify, repaired.loadFailed());
    try std.testing.expectEqual(Action.load, repaired.verificationFinished(true));
    try std.testing.expectEqual(Action.none, repaired.loadFailed());
    try std.testing.expectEqual(State.runtime_failure, repaired.current());
}

test "runtime Retry preserves configured installation state" {
    var recovery = Recovery{};
    _ = recovery.loadFailed();
    _ = recovery.verificationFinished(true);
    _ = recovery.loadFailed();

    try std.testing.expect(recovery.installationUsable());
    try std.testing.expectEqual(Action.load, recovery.retry());
    recovery.loadSucceeded();
    try std.testing.expectEqual(State.ready, recovery.current());
}
