//! grant_sequence.zig - the serialized cold-start TCC request sequence (wayfinder #130).
//!
//! Pure policy, no OS: the daemon's self-heal supervisor feeds wall-clock time and the
//! three grant facts each tick and executes the returned actions (fire one TCC request,
//! narrate a `[N/3]` line). Requests are serialized — Microphone → Input Monitoring →
//! PostEvent, one in flight at a time — because firing a CG request while an earlier
//! prompt is pending is what produced the historical restart loop (#128). Each step
//! advances the moment its grant fact goes true, or after a 60 s timeout — the public
//! preflights cannot distinguish "not yet answered" from "denied", so the cap sidesteps
//! that undecidable state; there is no restart/relaunch fallback anywhere in this policy.
//!
//! The grant facts themselves keep being polled forever by the supervisor, independent
//! of sequence position: a grant that lands minutes after its step timed out still gets
//! its `granted` action (the narration is transition-based, not step-based), and the
//! live pickup mechanisms (#127/#129 tap recreate, Insertion probe) run outside this
//! module. This module only decides *when to ask*.

const std = @import("std");

pub const Grant = enum { microphone, input_monitoring, post_event };
pub const grant_count = std.meta.fieldNames(Grant).len;

/// Grant facts for one tick, indexed by @intFromEnum(Grant).
pub const Facts = [grant_count]bool;

/// Per-grant wait before moving on to the next request (#130).
pub const timeout_ms: i64 = 60_000;

pub const Action = union(enum) {
    /// Fire this grant's TCC request now (prompts only while undetermined).
    request: Grant,
    /// This grant's fact went true — first observation ever, any sequence position.
    granted: Grant,
    /// timeout_ms elapsed without the grant; the sequence moves on. The caller keeps
    /// polling the fact in the background — this is not a denial verdict.
    timed_out: Grant,
};

/// Bounded per-tick action list. Worst case: three `granted` transitions in one tick,
/// plus one `timed_out` and the follow-on `request` while walking forward.
pub const Actions = struct {
    items: [5]Action = undefined,
    count: usize = 0,

    fn add(self: *Actions, action: Action) void {
        self.items[self.count] = action;
        self.count += 1;
    }

    pub fn slice(self: *const Actions) []const Action {
        return self.items[0..self.count];
    }
};

pub const Sequence = struct {
    /// Index of the grant whose request is current; grant_count = sequence done.
    next: usize = 0,
    requested: bool = false,
    requested_at_ms: i64 = 0,
    narrated: [grant_count]bool = @splat(false),

    /// One supervisor tick: narrate fresh grants, then advance the request pointer —
    /// skip grants already granted, fire the next request once, time a stuck one out.
    pub fn tick(self: *Sequence, now_ms: i64, granted: Facts) Actions {
        var out: Actions = .{};
        for (granted, 0..) |is_granted, i| {
            if (is_granted and !self.narrated[i]) {
                self.narrated[i] = true;
                out.add(.{ .granted = @enumFromInt(i) });
            }
        }
        while (self.next < grant_count) {
            const grant: Grant = @enumFromInt(self.next);
            if (granted[self.next]) {
                self.advance();
                continue;
            }
            if (!self.requested) {
                self.requested = true;
                self.requested_at_ms = now_ms;
                out.add(.{ .request = grant });
                break;
            }
            if (now_ms - self.requested_at_ms >= timeout_ms) {
                out.add(.{ .timed_out = grant });
                self.advance();
                continue;
            }
            break;
        }
        return out;
    }

    fn advance(self: *Sequence) void {
        self.next += 1;
        self.requested = false;
    }

    /// Whether this grant's sequence step has been reached (its request fired, or the
    /// step passed by grant/timeout). The daemon's probe gate: never post a PostEvent
    /// probe before that grant's prompt had its chance to surface.
    pub fn reached(self: *const Sequence, grant: Grant) bool {
        const i = @intFromEnum(grant);
        return self.next > i or (self.next == i and self.requested);
    }
};

// ---- tests: the request serialization, timeout advance, and narration ----

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const none = Facts{ false, false, false };

fn expectActions(actual: Actions, expected: []const Action) !void {
    try expectEqual(expected.len, actual.count);
    for (expected, actual.slice()) |want, got| {
        try expect(std.meta.eql(want, got));
    }
}

test "fresh install: one request in flight at a time, in #130's order" {
    var seq = Sequence{};

    try expectActions(seq.tick(0, none), &.{.{ .request = .microphone }});
    // Still waiting: no repeat request, nothing new.
    try expectActions(seq.tick(3_000, none), &.{});
    try expect(seq.reached(.microphone));
    try expect(!seq.reached(.input_monitoring));

    // Microphone granted → narrate it and fire the next request the same tick.
    try expectActions(seq.tick(6_000, .{ true, false, false }), &.{
        .{ .granted = .microphone },
        .{ .request = .input_monitoring },
    });
    try expectActions(seq.tick(9_000, .{ true, true, false }), &.{
        .{ .granted = .input_monitoring },
        .{ .request = .post_event },
    });
    try expectActions(seq.tick(12_000, .{ true, true, true }), &.{
        .{ .granted = .post_event },
    });
    // Done and inert.
    try expectActions(seq.tick(15_000, .{ true, true, true }), &.{});
}

test "a stuck grant times out after 60s and the sequence moves on" {
    var seq = Sequence{};

    _ = seq.tick(0, none);
    try expectActions(seq.tick(59_999, none), &.{});
    try expectActions(seq.tick(60_000, none), &.{
        .{ .timed_out = .microphone },
        .{ .request = .input_monitoring },
    });
    // The timer restarts per grant.
    try expectActions(seq.tick(119_999, none), &.{});
    try expectActions(seq.tick(120_000, none), &.{
        .{ .timed_out = .input_monitoring },
        .{ .request = .post_event },
    });
    try expectActions(seq.tick(180_000, none), &.{
        .{ .timed_out = .post_event },
    });
    try expect(seq.reached(.post_event));
}

test "a grant landing after its step timed out still gets its granted line" {
    var seq = Sequence{};

    _ = seq.tick(0, none);
    _ = seq.tick(60_000, none); // microphone timed out; input_monitoring requested
    try expectActions(seq.tick(63_000, .{ true, false, false }), &.{
        .{ .granted = .microphone },
    });
    // Narrated once, never again.
    try expectActions(seq.tick(66_000, .{ true, false, false }), &.{});
}

test "grants already present are skipped without a request (normal restart)" {
    var seq = Sequence{};

    try expectActions(seq.tick(0, .{ true, true, true }), &.{
        .{ .granted = .microphone },
        .{ .granted = .input_monitoring },
        .{ .granted = .post_event },
    });
    try expect(seq.reached(.post_event));
    try expectActions(seq.tick(3_000, .{ true, true, true }), &.{});
}

test "a mid-sequence grant already present is skipped straight to the next request" {
    var seq = Sequence{};

    // Microphone missing, Input Monitoring already granted, PostEvent missing.
    try expectActions(seq.tick(0, .{ false, true, false }), &.{
        .{ .granted = .input_monitoring },
        .{ .request = .microphone },
    });
    try expectActions(seq.tick(3_000, .{ true, true, false }), &.{
        .{ .granted = .microphone },
        .{ .request = .post_event },
    });
}

test "reached gates the PostEvent probe until its prompt fired" {
    var seq = Sequence{};

    _ = seq.tick(0, none);
    try expect(!seq.reached(.post_event));
    _ = seq.tick(60_000, none);
    try expect(!seq.reached(.post_event));
    _ = seq.tick(120_000, none); // input_monitoring timed out → post_event requested
    try expect(seq.reached(.post_event));
}
