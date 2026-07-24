//! grants.zig — the **Grant Observer** and the pure request sequence it drives (wayfinder
//! #130, ADR-0010).
//!
//! Two halves, in the shape `undo.zig` and `session.zig` use: a pure decider, and the
//! machine that feeds it the OS.
//!
//! # `Sequence` — pure policy, no OS
//!
//! Fed wall-clock time and the three grant facts each tick, it returns the actions to run
//! (fire one TCC request, narrate a `[N/3]` line). Requests are serialized — Microphone →
//! Input Monitoring → PostEvent, one in flight at a time — because firing a CG request while
//! an earlier prompt is pending is what produced the historical restart loop (#128). Each
//! step advances the moment its grant fact goes true, or after a 60 s timeout — the public
//! preflights cannot distinguish "not yet answered" from "denied", so the cap sidesteps that
//! undecidable state; there is no restart/relaunch fallback anywhere in this policy.
//!
//! The grant facts themselves keep being polled forever, independent of sequence position: a
//! grant that lands minutes after its step timed out still gets its `granted` action (the
//! narration is transition-based, not step-based), and the live pickup mechanisms (#127/#129
//! tap recreate, Insertion probe) run outside this module. `Sequence` only decides *when to
//! ask*.
//!
//! # `Observer(Probes)` — the grant facts, and who owns them
//!
//! The Observer owns everything between the OS and that decider: the six TCC calls behind the
//! `Probes` seam, the two facts that are *compositions* rather than single reads, the
//! attempt-then-observe latch (#129), and the narration.
//!
//! Both composed facts exist because a preflight alone lies:
//!
//!   - **Input Monitoring** — the preflight is stale in-process after a live grant (#127), so
//!     the live tap is the truth; the preflight only adds the created-but-momentarily-disabled
//!     window at startup.
//!   - **PostEvent** — the preflight is trustworthy when `true` but can lie `false` for the
//!     process lifetime, so an observed self-post latches the fact true (#129).
//!
//! That second one is why this module is a seam rather than a set of free functions in the
//! daemon: `postEventGranted` is what authorizes the Undo Runner to post a burst of
//! destructive Backspaces (ADR-0008), and a predicate guarding data loss should be reachable
//! from a test. ADR-0010 records the boundary against ADR-0005: the Supervisor's facts stay
//! the daemon's to gather; the *grant* facts are this module's, and the daemon reads them
//! from here.

const std = @import("std");
const feedback = @import("feedback.zig");

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

// ---- narration: the `[N/3]` line each Action renders as -----------------------------
//
// Pure lookups, kept beside the policy that produces the Actions rather than at the call
// site that prints them, so the wording is table-tested (ADR-0010). The Observer composes
// and logs them; nothing here touches the OS.

/// 1-based step number, as the user sees it in `[N/3]`.
pub fn stepNo(grant: Grant) usize {
    return @intFromEnum(grant) + 1;
}

/// The grant's name in macOS's own words — what the user will look for in System Settings.
pub fn grantName(grant: Grant) []const u8 {
    return switch (grant) {
        .microphone => "Microphone",
        .input_monitoring => "Input Monitoring",
        .post_event => "PostEvent (Accessibility)",
    };
}

/// Where to go when the prompt does not surface. The Microphone prompt is reliable and needs
/// no directions; the other two are the ones users have to find by hand.
pub fn requestHint(grant: Grant) []const u8 {
    return switch (grant) {
        .microphone => "…",
        .input_monitoring => " — check System Settings > Privacy & Security > Input Monitoring",
        .post_event => " — check System Settings > Privacy & Security > Accessibility",
    };
}

/// What the grant unlocked, so the line reports a capability rather than a permission.
pub fn grantedNote(grant: Grant) []const u8 {
    return switch (grant) {
        .microphone => "Capture is live",
        .input_monitoring => "Talk Key tap is live",
        .post_event => "Insertion is live",
    };
}

// ---- the Grant Observer ------------------------------------------------------------

/// The Observer's seam: the four TCC reads, the request, and the clock. Asserted by name
/// here and invoked by `Observer` itself below, so a production adapter can never skip the
/// check — the gap the Helper and Session Transport contracts leave open.
pub fn assertProbes(comptime Probes: type) void {
    const required = [_][]const u8{
        "micGranted",       "listenGranted", "tapEnabled",
        "postEventGranted", "request",       "nowMs",
    };
    inline for (required) |name| {
        if (!@hasDecl(Probes, name))
            @compileError("type '" ++ @typeName(Probes) ++ "' is not Grant Probes: missing method '" ++ name ++ "'");
    }
}

pub fn Observer(comptime Probes: type) type {
    assertProbes(Probes);
    return struct {
        const Self = @This();

        probes: Probes,
        seq: Sequence = .{},

        /// The attempt-then-observe latch (#129). Set from the tap's run-loop thread when a
        /// self-tagged post is seen; read from the supervisor thread and the Insert Worker.
        post_event_observed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// Whether the `TCC grants…` header has been printed. Printed lazily, before the
        /// first line that would need it, so a fully-granted daemon narrates nothing at all.
        header_printed: bool = false,

        pub fn init(probes: Probes) Self {
            return .{ .probes = probes };
        }

        /// A self-tagged Insertion post was observed: the PostEvent grant is real, whatever
        /// the preflight says from here on (#129). Idempotent; safe from the tap thread.
        pub fn observePostEvent(self: *Self) void {
            self.post_event_observed.store(true, .release);
        }

        /// Whether `grant` is held right now. The two composed facts live here rather than at
        /// the call sites that used to each re-OR them: Input Monitoring trusts the live tap
        /// over its stale preflight (#127), PostEvent trusts the observe latch over its
        /// lying-false preflight (#129).
        pub fn granted(self: *Self, grant: Grant) bool {
            return switch (grant) {
                .microphone => self.probes.micGranted(),
                .input_monitoring => self.probes.tapEnabled() or self.probes.listenGranted(),
                .post_event => self.post_event_observed.load(.acquire) or self.probes.postEventGranted(),
            };
        }

        /// This tick's three facts, in `Grant` order.
        pub fn facts(self: *Self) Facts {
            return .{ self.granted(.microphone), self.granted(.input_monitoring), self.granted(.post_event) };
        }

        /// Whether this grant's sequence step has been reached — see `Sequence.reached`.
        pub fn reached(self: *const Self, grant: Grant) bool {
            return self.seq.reached(grant);
        }

        /// One supervisor tick of #130's serialized request sequence: read the three facts,
        /// let the pure policy decide, then fire the requests and print the `[N/3]` lines.
        /// The facts keep being polled here forever — a grant landing minutes after its step
        /// timed out still gets its `granted` line and its live pickup.
        pub fn tick(self: *Self) void {
            const actions = self.seq.tick(self.probes.nowMs(), self.facts());
            if (actions.count > 0 and !self.header_printed) {
                self.header_printed = true;
                feedback.log("TCC grants for the type-wave daemon (requesting one at a time):\n", .{});
            }
            for (actions.slice()) |action| switch (action) {
                .request => |grant| {
                    self.probes.request(grant);
                    feedback.log("  [{d}/3] {s}: requesting{s}\n", .{ stepNo(grant), grantName(grant), requestHint(grant) });
                },
                .granted => |grant| feedback.log("  [{d}/3] {s}: granted — {s}\n", .{ stepNo(grant), grantName(grant), grantedNote(grant) }),
                .timed_out => |grant| feedback.log("  [{d}/3] {s}: still waiting after 60s — moving on to the next grant; will keep polling in the background\n", .{ stepNo(grant), grantName(grant) }),
            };
        }
    };
}

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

// ---- tests: the Observer — composed facts, the latch, and the request ladder ----

/// A scriptable stand-in for the daemon's TCC calls and clock: every read is a fed value,
/// every request is recorded, and time only moves when a test moves it.
const FakeProbes = struct {
    mic: bool = false,
    listen: bool = false,
    tap: bool = false,
    post_event: bool = false,
    now: i64 = 0,
    requests: [8]Grant = undefined,
    request_count: usize = 0,

    fn micGranted(self: *FakeProbes) bool {
        return self.mic;
    }
    fn listenGranted(self: *FakeProbes) bool {
        return self.listen;
    }
    fn tapEnabled(self: *FakeProbes) bool {
        return self.tap;
    }
    fn postEventGranted(self: *FakeProbes) bool {
        return self.post_event;
    }
    fn request(self: *FakeProbes, grant: Grant) void {
        self.requests[self.request_count] = grant;
        self.request_count += 1;
    }
    fn nowMs(self: *FakeProbes) i64 {
        return self.now;
    }
    fn requested(self: *FakeProbes) []const Grant {
        return self.requests[0..self.request_count];
    }
};

const Obs = Observer(FakeProbes);

test "the Observer fires #130's requests in order, one at a time, as facts land" {
    var obs = Obs.init(.{});

    obs.tick();
    try expectEqual(@as(usize, 1), obs.probes.request_count);
    try expectEqual(Grant.microphone, obs.probes.requested()[0]);

    // Still waiting: no repeat request.
    obs.probes.now = 3_000;
    obs.tick();
    try expectEqual(@as(usize, 1), obs.probes.request_count);

    obs.probes.mic = true;
    obs.probes.now = 6_000;
    obs.tick();
    try expectEqual(Grant.input_monitoring, obs.probes.requested()[1]);

    obs.probes.listen = true;
    obs.probes.now = 9_000;
    obs.tick();
    try expectEqual(Grant.post_event, obs.probes.requested()[2]);

    obs.probes.post_event = true;
    obs.probes.now = 12_000;
    obs.tick();
    // Done and inert — three requests, never a fourth.
    try expectEqual(@as(usize, 3), obs.probes.request_count);
}

test "a stuck grant times out and the Observer moves on, still polling the fact" {
    var obs = Obs.init(.{});

    obs.tick(); // microphone requested
    obs.probes.now = 59_999;
    obs.tick();
    try expectEqual(@as(usize, 1), obs.probes.request_count);

    obs.probes.now = 60_000;
    obs.tick();
    try expectEqual(Grant.input_monitoring, obs.probes.requested()[1]);

    // The timed-out grant lands late; the fact is still read every tick.
    obs.probes.mic = true;
    obs.probes.now = 63_000;
    obs.tick();
    try expect(obs.granted(.microphone));
}

test "Input Monitoring trusts the live tap over its stale preflight (#127)" {
    var obs = Obs.init(.{});

    try expect(!obs.granted(.input_monitoring));
    // The preflight goes stale after a live grant, so a live tap alone is sufficient
    // evidence — this is the case the daemon's old free function existed to express.
    obs.probes.tap = true;
    try expect(obs.granted(.input_monitoring));

    // And the preflight alone still counts, for the created-but-disabled startup window.
    obs.probes.tap = false;
    obs.probes.listen = true;
    try expect(obs.granted(.input_monitoring));
}

test "PostEvent latches on an observed self-post and never un-latches (#129)" {
    var obs = Obs.init(.{});

    try expect(!obs.granted(.post_event));
    obs.observePostEvent();
    try expect(obs.granted(.post_event));

    // The preflight can lie `false` for the whole process lifetime; the latch outranks it.
    obs.probes.post_event = false;
    try expect(obs.granted(.post_event));
}

test "a truthful PostEvent preflight is enough on its own" {
    var obs = Obs.init(.{ .post_event = true });
    // Trustworthy when true — a restart with the grant already in place needs no self-post.
    try expect(obs.granted(.post_event));
}

test "the PostEvent fact is what gates a destructive Undo (ADR-0008/ADR-0010)" {
    // The whole reason this composition sits behind a seam: `RealUndoDeps.enabled` reads it
    // before posting a burst of Backspaces, so it must be reachable from a test. Neither
    // source of evidence present → the gate is closed.
    var obs = Obs.init(.{ .mic = true, .tap = true });
    try expect(!obs.granted(.post_event));
    obs.observePostEvent();
    try expect(obs.granted(.post_event));
}

test "a fully granted daemon requests nothing and reaches the last step immediately" {
    var obs = Obs.init(.{ .mic = true, .listen = true, .post_event = true });

    obs.tick();
    try expectEqual(@as(usize, 0), obs.probes.request_count);
    try expect(obs.reached(.post_event));
    // Narration is transition-based, so a second tick is silent too.
    obs.probes.now = 3_000;
    obs.tick();
    try expectEqual(@as(usize, 0), obs.probes.request_count);
}

test "reached gates the PostEvent probe until its prompt fired, through the Observer" {
    var obs = Obs.init(.{});

    obs.tick();
    try expect(!obs.reached(.post_event));
    obs.probes.now = 60_000;
    obs.tick();
    try expect(!obs.reached(.post_event));
    obs.probes.now = 120_000;
    obs.tick(); // input_monitoring timed out → post_event requested
    try expect(obs.reached(.post_event));
}

test "the narration tables cover every grant" {
    // The four lookups are total over `Grant`, and the step numbers are the 1-based order
    // #130 requests them in.
    var i: usize = 0;
    while (i < grant_count) : (i += 1) {
        const g: Grant = @enumFromInt(i);
        try expectEqual(i + 1, stepNo(g));
        try expect(grantName(g).len > 0);
        try expect(requestHint(g).len > 0);
        try expect(grantedNote(g).len > 0);
    }
    try expectEqual(@as(usize, 1), stepNo(.microphone));
    try expectEqual(@as(usize, 3), stepNo(.post_event));
    // The two the user has to find by hand name where to look.
    try expect(std.mem.indexOf(u8, requestHint(.input_monitoring), "Input Monitoring") != null);
    try expect(std.mem.indexOf(u8, requestHint(.post_event), "Accessibility") != null);
}
