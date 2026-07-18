//! failure_observation.zig — the cross-thread failure-publishing helper the Status Item
//! reads (wayfinder #93). A mutex-guarded snapshot of one failure string: a background
//! thread `set`s or `clear`s it as a runtime path fails or recovers, and the main thread
//! `current()`s it when it rebuilds the Status Item.
//!
//! Two unrelated failure paths share this exact shape — the Model Operation failure and the
//! local-runtime failure (daemon.zig) — so it stands alone as a leaf, owned by neither and
//! importable without dragging in daemon.zig. This is the prefactor for the Model Operation
//! Runner lift: the Runner must own a `FailureObservation` without importing the daemon.
//!
//! The lock is a spin lock. Every critical section is a pointer store or a fixed 256-byte
//! copy — far shorter than a park/unpark syscall — and contention is near-nil (one writer
//! thread, one reader), so spinning wins.

const std = @import("std");
const status_item = @import("status_item.zig");

const ObservationMutex = struct {
    value: std.atomic.Mutex = .unlocked,

    fn lock(self: *ObservationMutex) void {
        while (!self.value.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *ObservationMutex) void {
        self.value.unlock();
    }
};

pub const FailureObservation = struct {
    mutex: ObservationMutex = .{},
    detail: ?status_item.FailureDetail = null,

    pub fn set(self: *FailureObservation, value: []const u8) void {
        const detail = status_item.FailureDetail.init(value) catch return;
        self.mutex.lock();
        self.detail = detail;
        self.mutex.unlock();
    }

    pub fn setError(self: *FailureObservation, prefix: []const u8, failure: anyerror) void {
        var buffer: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ prefix, @errorName(failure) }) catch return;
        self.set(detail);
    }

    pub fn clear(self: *FailureObservation) void {
        self.mutex.lock();
        self.detail = null;
        self.mutex.unlock();
    }

    pub fn current(self: *FailureObservation) ?status_item.FailureDetail {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.detail;
    }
};

test "FailureObservation publishes, overwrites, and clears the snapshot" {
    var observation = FailureObservation{};
    // Starts empty — nothing for the Status Item to show.
    try std.testing.expectEqual(@as(?status_item.FailureDetail, null), observation.current());

    observation.set("local runtime down");
    try std.testing.expectEqualStrings("local runtime down", observation.current().?.value());

    // setError formats "<prefix>: <errorName>" and overwrites the prior snapshot.
    observation.setError("Local runtime load failed", error.HelperSpawnFailed);
    try std.testing.expectEqualStrings("Local runtime load failed: HelperSpawnFailed", observation.current().?.value());

    observation.clear();
    try std.testing.expectEqual(@as(?status_item.FailureDetail, null), observation.current());
}

test "FailureObservation leaves the snapshot untouched when a detail is rejected" {
    var observation = FailureObservation{};
    observation.set("real failure");

    // An empty or over-long detail fails FailureDetail.init; `set` swallows it rather than
    // clobbering the last good failure the Status Item is still showing.
    const over_long: [257]u8 = @splat('x'); // 257 > FailureDetail's 256-byte cap
    observation.set("");
    observation.set(&over_long);
    try std.testing.expectEqualStrings("real failure", observation.current().?.value());
}
