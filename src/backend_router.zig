//! Backend Router — the daemon's one route from an accepted Utterance to the selected
//! Transcription Backend, and the owner of the drain-then-switch policy (#70/#74).
//!
//! One mutex guards all router state (the Selection FSM plus the two resource
//! pointers). It is held only for state transitions and pointer fetches — never across
//! a `Deps` call, a resource command, or `note` — so audio appends and slow preparation
//! (a websocket connect, a helper warm) never block each other. Two invariants make the
//! fetched-pointer-used-outside-the-lock pattern safe:
//!
//!   1. A resource is taken down only once its route has drained (`Selection` guards
//!      teardown and invalidation on `active == null`), so commands addressed to a live
//!      Utterance never race a teardown.
//!   2. Published resources are never freed (they leak by design, like Settings
//!      Snapshots), and their commands are safe post-shutdown, so a stale fetch
//!      degrades to a no-op rather than a use-after-free.
//!
//! `Deps` supplies everything effectful, so the whole policy — staleness invalidation,
//! drain-gated teardown, ticket-guarded preparation, stale-ticket teardown — runs under
//! scripted single-threaded tests:
//!
//!   Deps.SessionResource / Deps.LocalResource — resource types satisfying the uniform
//!     contract: isReady() bool, shutdown() void, stillValid() bool,
//!     acquire(id, language) ?backend.Lease, appendAudio(id, pcm) !void
//!     (SessionResource additionally: markParamsDirty(); LocalResource: retry()).
//!   deps.connectOpenai() anyerror!*SessionResource — establish the OpenAI resource.
//!   deps.prepareLocal() ?*LocalResource — warm the local resource (null = failed;
//!     the provisioner reports its own details).
//!   deps.wants() Wants — called exactly once per tick, after reconciliation
//!     (select / staleness / same-backend teardown) and before preparation, so the
//!     caller's Configuration Phase sees post-teardown facts — preserving the
//!     prepare-in-the-same-tick behavior on a Model Installation swap.
//!   deps.language() backend.Language — the Settings Snapshot language for new Leases.
//!   deps.backtrack() bool — the Settings Snapshot Backtrack enablement, stamped onto
//!     every new Lease so it is pinned at Talk Key press (docs/backtrack-spec.md).
//!   deps.vocabulary() backend.Vocabulary — the Settings Snapshot vocabulary list, pinned
//!     onto every new Lease at press so all Segments of an Utterance bias identically
//!     (docs/vocab-biasing-spec.md §5). Only the local backend reads it; OpenAI ignores it.
//!   deps.note(Event) — narration for the caller's log. Invoked outside the router
//!     mutex; it must not call back into the Router.

const std = @import("std");
const backend = @import("transcription_backend.zig");

/// What the caller's Configuration Phase wants prepared this tick. `connect_openai`
/// implies the caller holds whatever the connect needs (e.g. the API key).
pub const Wants = struct {
    connect_openai: bool = false,
    prepare_local: bool = false,
};

pub const Event = union(enum) {
    /// A ready, drained resource stopped covering its Backend (a Model Installation
    /// activated under the warm helper); its replacement generation is being prepared.
    stale: backend.Backend,
    /// An obsolete resource was shut down after draining (silent teardowns included).
    tore_down: backend.Backend,
    /// Preparation published a ready resource for this Backend.
    ready: backend.Backend,
    /// Preparation failed; it retries on a later tick. `err` is null when the
    /// provisioner already reported the details itself.
    prepare_failed: struct { which: backend.Backend, err: ?anyerror },
};

/// Pure drain-then-switch policy (the Router's internal seam). Resource owners prepare
/// the returned ticket and may publish it only if its generation is still current. An
/// accepted Utterance occupies `active` through Insertion/abandonment, so selection
/// changes reject Capture without disturbing its immutable Lease.
const Selection = struct {
    selected: backend.Backend,
    generation: u64 = 1,
    readiness: Readiness = .unavailable,
    active: ?Active = null,

    pub const Readiness = enum { unavailable, preparing, ready };
    pub const Ticket = struct { backend: backend.Backend, generation: u64 };
    pub const Route = struct { id: backend.UtteranceId, backend: backend.Backend };
    const Active = struct { id: backend.UtteranceId, backend: backend.Backend };

    pub fn init(selected: backend.Backend) Selection {
        return .{ .selected = selected };
    }

    pub fn select(self: *Selection, selected: backend.Backend) void {
        if (self.selected == selected) return;
        self.selected = selected;
        self.generation +%= 1;
        self.readiness = .unavailable;
    }

    pub fn beginPreparation(self: *Selection, expected: backend.Backend) ?Ticket {
        if (self.selected != expected or self.active != null or self.readiness != .unavailable) return null;
        self.readiness = .preparing;
        return .{ .backend = self.selected, .generation = self.generation };
    }

    /// Returns whether the prepared resource became authoritative. A stale result must
    /// be torn down by its owner.
    pub fn finishPreparation(self: *Selection, ticket: Ticket, ready: bool) bool {
        if (ticket.generation != self.generation or ticket.backend != self.selected) return false;
        self.readiness = if (ready) .ready else .unavailable;
        return ready;
    }

    /// An authoritative resource changed underneath the selected backend (for example,
    /// atomic activation published a new Model Installation). New leases stay rejected
    /// until the owner prepares the replacement generation.
    pub fn invalidate(self: *Selection, expected: backend.Backend) bool {
        if (self.selected != expected or self.active != null or self.readiness != .ready) return false;
        self.generation +%= 1;
        self.readiness = .unavailable;
        return true;
    }

    pub fn acquire(self: *Selection, id: backend.UtteranceId) ?backend.Backend {
        if (self.active != null or self.readiness != .ready) return null;
        self.active = .{ .id = id, .backend = self.selected };
        return self.selected;
    }

    pub fn resolve(self: *Selection, id: backend.UtteranceId) bool {
        const active = self.active orelse return false;
        if (active.id != id) return false;
        self.active = null;
        if (active.backend != self.selected) self.readiness = .unavailable;
        return true;
    }

    pub fn activeRoute(self: *const Selection) ?Route {
        const active = self.active orelse return null;
        return .{ .id = active.id, .backend = active.backend };
    }

    pub fn isReady(self: *const Selection) bool {
        return self.active == null and self.readiness == .ready;
    }
};

pub fn Router(comptime Deps: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        deps: *Deps,
        mu: std.Io.Mutex = .init,
        selection: Selection,
        session: ?*Deps.SessionResource = null,
        local: ?*Deps.LocalResource = null,

        pub fn init(io: std.Io, deps: *Deps, first_selected: backend.Backend) Self {
            return .{ .io = io, .deps = deps, .selection = Selection.init(first_selected) };
        }

        fn lock(self: *Self) void {
            self.mu.lockUncancelable(self.io);
        }
        fn unlock(self: *Self) void {
            self.mu.unlock(self.io);
        }

        // ---- the Coordinator's backend-neutral lease seam ------------------------

        pub fn acquire(self: *Self, id: backend.UtteranceId) ?backend.Lease {
            self.lock();
            const which = self.selection.acquire(id) orelse {
                self.unlock();
                return null;
            };
            const session = self.session;
            const local = self.local;
            self.unlock();
            var lease: ?backend.Lease = switch (which) {
                .openai => if (session) |s| s.acquire(id, self.deps.language()) else null,
                .local => if (local) |l| l.acquire(id, self.deps.language()) else null,
            };
            if (lease == null) {
                self.resolve(id);
                return null;
            }
            // Pin Backtrack enablement and the vocabulary list at press, alongside the backend
            // and language the Lease already carries — a mid-Utterance settings flip cannot
            // half-apply, so every Segment of the Utterance biases toward one coherent list.
            lease.?.backtrack = self.deps.backtrack();
            lease.?.vocabulary = self.deps.vocabulary();
            return lease;
        }

        pub fn resolve(self: *Self, id: backend.UtteranceId) void {
            self.lock();
            defer self.unlock();
            _ = self.selection.resolve(id);
        }

        pub fn available(self: *Self) bool {
            self.lock();
            const ready = self.selection.isReady();
            const which = self.selection.selected;
            const session = self.session;
            const local = self.local;
            self.unlock();
            if (!ready) return false;
            return switch (which) {
                .openai => if (session) |s| s.isReady() else false,
                .local => if (local) |l| l.isReady() else false,
            };
        }

        // ---- the audio sink's route-addressed append -----------------------------

        pub fn appendCurrent(self: *Self, pcm: []const u8) !backend.UtteranceId {
            self.lock();
            const route = self.selection.activeRoute() orelse {
                self.unlock();
                return error.NoActiveUtterance;
            };
            const session = self.session;
            const local = self.local;
            self.unlock();
            switch (route.backend) {
                .openai => try (session orelse return error.NoTranscriptionSession).appendAudio(route.id, pcm),
                .local => try (local orelse return error.NoLocalBackend).appendAudio(route.id, pcm),
            }
            return route.id;
        }

        pub fn activeId(self: *Self) backend.UtteranceId {
            self.lock();
            defer self.unlock();
            return if (self.selection.activeRoute()) |route| route.id else 0;
        }

        // ---- selection queries + menu edges --------------------------------------

        pub fn select(self: *Self, requested: backend.Backend) void {
            self.lock();
            defer self.unlock();
            self.selection.select(requested);
        }

        pub fn selected(self: *Self) backend.Backend {
            self.lock();
            defer self.unlock();
            return self.selection.selected;
        }

        /// Is a resource published for this Backend? (Presence, not readiness — a
        /// reconnecting session or a mid-swap helper still counts.)
        pub fn resourcePresent(self: *Self, which: backend.Backend) bool {
            self.lock();
            defer self.unlock();
            return switch (which) {
                .openai => self.session != null,
                .local => self.local != null,
            };
        }

        /// A session-shaped setting changed in the Settings Snapshot: the OpenAI
        /// resource cycles when idle (#32). Local leases read the snapshot per
        /// Utterance, so only the session cares.
        pub fn settingsChanged(self: *Self) void {
            self.lock();
            const session = self.session;
            self.unlock();
            if (session) |s| s.markParamsDirty();
        }

        /// SIGHUP/menu Retry, deliberately local-only (a failed connect simply retries
        /// on the next tick). Returns whether a warm local resource took the retry.
        pub fn retryLocal(self: *Self) bool {
            self.lock();
            const local = self.local;
            self.unlock();
            const l = local orelse return false;
            l.retry();
            return true;
        }

        // ---- the supervisor's reconcile-then-prepare tick ------------------------

        /// One supervision pass: adopt the requested selection, invalidate a stale
        /// ready resource, tear down obsolete resources once drained, ask `deps.wants()`
        /// what to prepare, and prepare it under a generation ticket. Returns true when
        /// a resource became authoritative this tick (the caller re-evaluates its facts).
        pub fn tick(self: *Self, selected_backend: backend.Backend) bool {
            self.lock();
            self.selection.select(selected_backend);

            // Staleness: only a ready, drained resource of the selected Backend can go
            // stale; `Selection.invalidate` re-checks under the same guards after the
            // unlocked stillValid probe (which may touch the filesystem).
            var probe_session: ?*Deps.SessionResource = null;
            var probe_local: ?*Deps.LocalResource = null;
            if (self.selection.isReady()) switch (selected_backend) {
                .openai => probe_session = self.session,
                .local => probe_local = self.local,
            };
            self.unlock();
            var is_stale = false;
            if (probe_session) |s| is_stale = !s.stillValid();
            if (probe_local) |l| is_stale = !l.stillValid();
            if (is_stale) {
                self.lock();
                const invalidated = self.selection.invalidate(selected_backend);
                self.unlock();
                if (invalidated) self.deps.note(.{ .stale = selected_backend });
            }

            // Same-backend teardown: the selected Backend's resource is obsolete once
            // its route has drained and the selection is not ready (a generation bump
            // from select-away-and-back, or the invalidation above).
            self.lock();
            var doomed_session: ?*Deps.SessionResource = null;
            var doomed_local: ?*Deps.LocalResource = null;
            if (self.selection.activeRoute() == null and !self.selection.isReady()) switch (selected_backend) {
                .openai => {
                    doomed_session = self.session;
                    self.session = null;
                },
                .local => {
                    doomed_local = self.local;
                    self.local = null;
                },
            };
            self.unlock();
            if (doomed_session) |s| {
                s.shutdown();
                self.deps.note(.{ .tore_down = .openai });
            }
            if (doomed_local) |l| {
                l.shutdown();
                self.deps.note(.{ .tore_down = .local });
            }

            // The caller gathers its facts NOW — after reconciliation, before
            // preparation — exactly once per tick.
            const wants = self.deps.wants();

            // Drain-gated cross-teardown + ticket-guarded preparation.
            self.lock();
            const drained = self.selection.activeRoute() == null;
            self.unlock();
            if (!drained) return false;
            switch (selected_backend) {
                .openai => {
                    self.lock();
                    const obsolete = self.local;
                    self.local = null;
                    self.unlock();
                    if (obsolete) |l| {
                        l.shutdown();
                        self.deps.note(.{ .tore_down = .local });
                    }
                    if (wants.connect_openai) return self.prepareOpenaiSlot();
                },
                .local => {
                    self.lock();
                    const obsolete = self.session;
                    self.session = null;
                    self.unlock();
                    if (obsolete) |s| {
                        s.shutdown();
                        self.deps.note(.{ .tore_down = .openai });
                    }
                    if (wants.prepare_local) return self.prepareLocalSlot();
                },
            }
            return false;
        }

        fn prepareOpenaiSlot(self: *Self) bool {
            self.lock();
            const maybe_ticket = self.selection.beginPreparation(.openai);
            self.unlock();
            const ticket = maybe_ticket orelse return false;
            const session = self.deps.connectOpenai() catch |err| {
                self.lock();
                _ = self.selection.finishPreparation(ticket, false);
                self.unlock();
                self.deps.note(.{ .prepare_failed = .{ .which = .openai, .err = err } });
                return false;
            };
            self.lock();
            const authoritative = self.selection.finishPreparation(ticket, true);
            if (authoritative) {
                std.debug.assert(self.session == null); // tick's teardown phases cleared the slot
                self.session = session;
            }
            self.unlock();
            if (!authoritative) {
                session.shutdown();
                self.deps.note(.{ .tore_down = .openai });
                return false;
            }
            self.deps.note(.{ .ready = .openai });
            return true;
        }

        fn prepareLocalSlot(self: *Self) bool {
            self.lock();
            const maybe_ticket = self.selection.beginPreparation(.local);
            self.unlock();
            const ticket = maybe_ticket orelse return false;
            const local = self.deps.prepareLocal() orelse {
                self.lock();
                _ = self.selection.finishPreparation(ticket, false);
                self.unlock();
                self.deps.note(.{ .prepare_failed = .{ .which = .local, .err = null } });
                return false;
            };
            self.lock();
            const authoritative = self.selection.finishPreparation(ticket, true);
            if (authoritative) {
                std.debug.assert(self.local == null); // tick's teardown phases cleared the slot
                self.local = local;
            }
            self.unlock();
            if (!authoritative) {
                local.shutdown();
                self.deps.note(.{ .tore_down = .local });
                return false;
            }
            self.deps.note(.{ .ready = .local });
            return true;
        }

        /// Process exit: shut down whatever is warm. Runs after the supervisor joined,
        /// so nothing races the slots.
        pub fn shutdown(self: *Self) void {
            self.lock();
            const session = self.session;
            const local = self.local;
            self.session = null;
            self.local = null;
            self.unlock();
            if (local) |l| l.shutdown();
            if (session) |s| s.shutdown();
        }
    };
}

// ---- scripted scenarios (FakeDeps: no threads, no hardware) --------------------

const FakeSession = struct {
    ready: bool = true,
    shutdowns: u32 = 0,
    params_dirty: bool = false,
    appended_id: backend.UtteranceId = 0,
    appended_bytes: usize = 0,

    const commands = backend.Commands{
        .begin = noopBegin,
        .append_audio = noopAppend,
        .release = noopRelease,
        .request_cancel = noopCancel,
        .cancel = noopCancel,
    };
    fn noopBegin(_: *anyopaque, _: backend.UtteranceId, _: backend.Language, _: backend.Vocabulary) !void {}
    fn noopAppend(_: *anyopaque, _: backend.UtteranceId, _: []const u8) !void {}
    fn noopRelease(_: *anyopaque, _: backend.UtteranceId) !void {}
    fn noopCancel(_: *anyopaque, _: backend.UtteranceId) void {}

    fn isReady(self: *FakeSession) bool {
        return self.ready;
    }
    fn shutdown(self: *FakeSession) void {
        self.shutdowns += 1;
    }
    fn stillValid(_: *FakeSession) bool {
        return true;
    }
    fn markParamsDirty(self: *FakeSession) void {
        self.params_dirty = true;
    }
    fn acquire(self: *FakeSession, id: backend.UtteranceId, language: backend.Language) ?backend.Lease {
        return .{
            .id = id,
            .backend = .openai,
            .language = language,
            .deadline = backend.openai_deadline,
            .ctx = self,
            .commands = &commands,
        };
    }
    fn appendAudio(self: *FakeSession, id: backend.UtteranceId, pcm: []const u8) !void {
        self.appended_id = id;
        self.appended_bytes += pcm.len;
    }
};

const FakeLocal = struct {
    ready: bool = true,
    valid: bool = true,
    shutdowns: u32 = 0,
    retries: u32 = 0,
    appended_id: backend.UtteranceId = 0,
    appended_bytes: usize = 0,

    fn isReady(self: *FakeLocal) bool {
        return self.ready;
    }
    fn shutdown(self: *FakeLocal) void {
        self.shutdowns += 1;
    }
    fn stillValid(self: *FakeLocal) bool {
        return self.valid;
    }
    fn retry(self: *FakeLocal) void {
        self.retries += 1;
    }
    fn acquire(self: *FakeLocal, id: backend.UtteranceId, language: backend.Language) ?backend.Lease {
        if (!self.ready) return null;
        return .{
            .id = id,
            .backend = .local,
            .language = language,
            .deadline = .{ .cooperative_cancel_ms = 9_500, .final_ms = 10_000 },
            .ctx = self,
            .commands = &FakeSession.commands,
        };
    }
    fn appendAudio(self: *FakeLocal, id: backend.UtteranceId, pcm: []const u8) !void {
        self.appended_id = id;
        self.appended_bytes += pcm.len;
    }
};

const FakeDeps = struct {
    pub const SessionResource = FakeSession;
    pub const LocalResource = FakeLocal;

    sessions: [4]FakeSession = @splat(.{}),
    session_count: usize = 0,
    connect_failure: ?anyerror = null,
    locals: [4]FakeLocal = @splat(.{}),
    local_count: usize = 0,
    prepare_ok: bool = true,
    pending_wants: Wants = .{},
    lang: backend.Language = "en",
    backtrack_enabled: bool = false,
    vocab: backend.Vocabulary = &.{},
    events: [16]Event = undefined,
    event_count: usize = 0,
    /// Reentry hook simulating a menu selection landing while a connect is in flight
    /// (Deps calls run outside the router mutex, so this is legal in production too).
    mid_connect: ?*const fn (ctx: *anyopaque) void = null,
    mid_connect_ctx: *anyopaque = undefined,

    pub fn connectOpenai(self: *FakeDeps) !*FakeSession {
        if (self.mid_connect) |hook| hook(self.mid_connect_ctx);
        if (self.connect_failure) |failure| return failure;
        const session = &self.sessions[self.session_count];
        self.session_count += 1;
        return session;
    }
    pub fn prepareLocal(self: *FakeDeps) ?*FakeLocal {
        if (!self.prepare_ok) return null;
        const local = &self.locals[self.local_count];
        self.local_count += 1;
        return local;
    }
    pub fn wants(self: *FakeDeps) Wants {
        return self.pending_wants;
    }
    pub fn language(self: *FakeDeps) backend.Language {
        return self.lang;
    }
    pub fn backtrack(self: *FakeDeps) bool {
        return self.backtrack_enabled;
    }
    pub fn vocabulary(self: *FakeDeps) backend.Vocabulary {
        return self.vocab;
    }
    pub fn note(self: *FakeDeps, event: Event) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn sawEvent(self: *const FakeDeps, expected: Event) bool {
        for (self.events[0..self.event_count]) |event| {
            if (std.meta.eql(event, expected)) return true;
        }
        return false;
    }
};

const TestRouter = Router(FakeDeps);

fn testRouter(deps: *FakeDeps, first: backend.Backend) TestRouter {
    return TestRouter.init(std.testing.io, deps, first);
}

test "switching backends tears down the drained resource and warms the replacement" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .openai);

    deps.pending_wants = .{ .connect_openai = true };
    try std.testing.expect(router.tick(.openai));
    try std.testing.expect(router.available());
    try std.testing.expect(deps.sawEvent(.{ .ready = .openai }));

    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(router.tick(.local));
    try std.testing.expectEqual(@as(u32, 1), deps.sessions[0].shutdowns);
    try std.testing.expect(deps.sawEvent(.{ .tore_down = .openai }));
    try std.testing.expect(deps.sawEvent(.{ .ready = .local }));
    try std.testing.expect(router.available());
    const lease = router.acquire(7).?;
    try std.testing.expectEqual(backend.Backend.local, lease.backend);
}

test "a new Lease pins the Settings Snapshot Backtrack enablement at acquire" {
    var deps = FakeDeps{ .backtrack_enabled = true };
    var router = testRouter(&deps, .openai);
    deps.pending_wants = .{ .connect_openai = true };
    try std.testing.expect(router.tick(.openai));

    const lease = router.acquire(7).?;
    try std.testing.expect(lease.backtrack);
    deps.backtrack_enabled = false; // mid-Utterance flip — the pinned Lease keeps true
    try std.testing.expect(lease.backtrack);
    router.resolve(7);

    const next = router.acquire(8).?;
    try std.testing.expect(!next.backtrack);
}

test "a new Lease pins the Settings Snapshot vocabulary list at acquire" {
    var deps = FakeDeps{ .vocab = &.{ "type-wave", "whisper.cpp" } };
    var router = testRouter(&deps, .local);
    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(router.tick(.local));

    const lease = router.acquire(7).?;
    try std.testing.expectEqual(@as(usize, 2), lease.vocabulary.len);
    try std.testing.expectEqualStrings("type-wave", lease.vocabulary[0]);
    deps.vocab = &.{}; // mid-Utterance edit — the pinned Lease keeps its list
    try std.testing.expectEqual(@as(usize, 2), lease.vocabulary.len);
    router.resolve(7);

    const next = router.acquire(8).?;
    try std.testing.expectEqual(@as(usize, 0), next.vocabulary.len);
}

test "a switch lands only after the active Utterance drains" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .openai);
    deps.pending_wants = .{ .connect_openai = true };
    try std.testing.expect(router.tick(.openai));
    const lease = router.acquire(41).?;
    try std.testing.expectEqual(backend.Backend.openai, lease.backend);

    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(!router.tick(.local)); // pinned route: no teardown, no preparation
    try std.testing.expectEqual(@as(u32, 0), deps.sessions[0].shutdowns);
    try std.testing.expectEqual(@as(usize, 0), deps.local_count);
    try std.testing.expect(router.acquire(42) == null); // new leases rejected while draining

    router.resolve(41);
    try std.testing.expect(router.tick(.local));
    try std.testing.expectEqual(@as(u32, 1), deps.sessions[0].shutdowns);
    const next = router.acquire(42).?;
    try std.testing.expectEqual(backend.Backend.local, next.backend);
}

test "a selection change mid-connect makes the prepared resource obsolete, never published" {
    const Reselect = struct {
        fn hook(ctx: *anyopaque) void {
            const router: *TestRouter = @ptrCast(@alignCast(ctx));
            router.select(.local); // the menu switches while the connect is in flight
        }
    };
    var deps = FakeDeps{};
    var router = testRouter(&deps, .openai);
    deps.pending_wants = .{ .connect_openai = true };
    deps.mid_connect = Reselect.hook;
    deps.mid_connect_ctx = &router;

    try std.testing.expect(!router.tick(.openai));
    try std.testing.expectEqual(@as(u32, 1), deps.sessions[0].shutdowns); // stale ticket → torn down
    try std.testing.expect(!router.resourcePresent(.openai));
    try std.testing.expect(!deps.sawEvent(.{ .ready = .openai }));
    try std.testing.expect(router.acquire(1) == null);
}

test "failed preparation stays unavailable and retries on a later tick" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .openai);
    deps.pending_wants = .{ .connect_openai = true };
    deps.connect_failure = error.ConnectFailed;
    try std.testing.expect(!router.tick(.openai));
    try std.testing.expect(!router.available());
    try std.testing.expect(deps.sawEvent(.{ .prepare_failed = .{ .which = .openai, .err = error.ConnectFailed } }));

    deps.connect_failure = null;
    try std.testing.expect(router.tick(.openai));
    try std.testing.expect(router.available());

    var local_deps = FakeDeps{ .prepare_ok = false, .pending_wants = .{ .prepare_local = true } };
    var local_router = testRouter(&local_deps, .local);
    try std.testing.expect(!local_router.tick(.local));
    try std.testing.expect(local_deps.sawEvent(.{ .prepare_failed = .{ .which = .local, .err = null } }));
    try std.testing.expect(!local_router.available());
}

test "a Model Installation swap under the warm helper invalidates, drains, and re-warms in one tick" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .local);
    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(router.tick(.local));
    try std.testing.expect(router.available());

    deps.locals[0].valid = false; // a new installation activated underneath
    try std.testing.expect(router.tick(.local));
    try std.testing.expect(deps.sawEvent(.{ .stale = .local }));
    try std.testing.expectEqual(@as(u32, 1), deps.locals[0].shutdowns);
    try std.testing.expectEqual(@as(usize, 2), deps.local_count); // replacement warmed same tick
    try std.testing.expect(router.available());
    const lease = router.acquire(3).?;
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&deps.locals[1])), lease.ctx);
}

test "an invalidated resource rejects leases while nothing is prepared" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .local);
    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(router.tick(.local));

    deps.locals[0].valid = false;
    deps.pending_wants = .{}; // Configuration Phase does not (yet) want a replacement
    try std.testing.expect(!router.tick(.local));
    try std.testing.expect(!router.available());
    try std.testing.expect(router.acquire(9) == null);
    try std.testing.expectEqual(@as(u32, 1), deps.locals[0].shutdowns);
}

test "selecting away and back drains the warm resource and prepares a fresh generation" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .openai);
    deps.pending_wants = .{ .connect_openai = true };
    try std.testing.expect(router.tick(.openai));
    _ = router.acquire(7).?;

    router.select(.local);
    router.select(.openai); // menu round-trip while the Utterance is still in flight
    try std.testing.expect(router.acquire(8) == null);
    router.resolve(7);

    try std.testing.expect(router.tick(.openai));
    try std.testing.expectEqual(@as(u32, 1), deps.sessions[0].shutdowns); // old generation drained out
    try std.testing.expectEqual(@as(usize, 2), deps.session_count);
    try std.testing.expect(router.available());
}

test "audio routes to the active Utterance's resource and nowhere else" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .openai);
    deps.pending_wants = .{ .connect_openai = true };
    try std.testing.expect(router.tick(.openai));

    try std.testing.expectError(error.NoActiveUtterance, router.appendCurrent(&.{ 1, 2 }));
    try std.testing.expectEqual(@as(backend.UtteranceId, 0), router.activeId());

    _ = router.acquire(9).?;
    try std.testing.expectEqual(@as(backend.UtteranceId, 9), try router.appendCurrent(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(backend.UtteranceId, 9), deps.sessions[0].appended_id);
    try std.testing.expectEqual(@as(usize, 3), deps.sessions[0].appended_bytes);
    try std.testing.expectEqual(@as(backend.UtteranceId, 9), router.activeId());
    router.resolve(9);

    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(router.tick(.local));
    _ = router.acquire(10).?;
    _ = try router.appendCurrent(&.{ 4, 5 });
    try std.testing.expectEqual(@as(backend.UtteranceId, 10), deps.locals[0].appended_id);
}

test "the pragmatic surface: retryLocal, settingsChanged, resourcePresent, shutdown" {
    var deps = FakeDeps{};
    var router = testRouter(&deps, .local);
    try std.testing.expect(!router.retryLocal()); // no warm local: the caller falls back to recovery

    deps.pending_wants = .{ .prepare_local = true };
    try std.testing.expect(router.tick(.local));
    try std.testing.expect(router.retryLocal());
    try std.testing.expectEqual(@as(u32, 1), deps.locals[0].retries);
    try std.testing.expect(router.resourcePresent(.local));
    try std.testing.expect(!router.resourcePresent(.openai));

    router.settingsChanged(); // no session: a no-op
    deps.pending_wants = .{ .connect_openai = true };
    try std.testing.expect(router.tick(.openai));
    router.settingsChanged();
    try std.testing.expect(deps.sessions[0].params_dirty);

    router.shutdown();
    try std.testing.expectEqual(@as(u32, 1), deps.sessions[0].shutdowns);
    try std.testing.expect(!router.resourcePresent(.openai));
}

// ---- the internal Selection seam's own tests (moved from transcription_backend.zig) ----

test "selection drains an active lease before preparing the latest backend" {
    var state = Selection.init(.openai);
    const openai = state.beginPreparation(.openai).?;
    try std.testing.expect(state.finishPreparation(openai, true));
    try std.testing.expectEqual(backend.Backend.openai, state.acquire(41).?);

    state.select(.local);
    try std.testing.expectEqual(backend.Backend.openai, state.activeRoute().?.backend);
    try std.testing.expect(state.beginPreparation(.local) == null);
    try std.testing.expect(state.acquire(42) == null);

    state.select(.openai);
    state.select(.local);
    try std.testing.expect(state.resolve(41));
    const latest = state.beginPreparation(.local).?;
    try std.testing.expectEqual(backend.Backend.local, latest.backend);
    try std.testing.expect(state.finishPreparation(latest, true));
    try std.testing.expectEqual(backend.Backend.local, state.acquire(42).?);
}

test "obsolete preparation never becomes ready" {
    var state = Selection.init(.openai);
    const obsolete = state.beginPreparation(.openai).?;
    state.select(.local);
    try std.testing.expect(!state.finishPreparation(obsolete, true));
    try std.testing.expect(state.acquire(1) == null);
    try std.testing.expect(state.beginPreparation(.openai) == null);
    try std.testing.expectEqual(backend.Backend.local, state.beginPreparation(.local).?.backend);
}

test "invalidating a ready resource rejects leases until its replacement is prepared" {
    var state = Selection.init(.local);
    const first = state.beginPreparation(.local).?;
    try std.testing.expect(state.finishPreparation(first, true));

    try std.testing.expect(state.invalidate(.local));
    try std.testing.expect(state.acquire(1) == null);
    const replacement = state.beginPreparation(.local).?;
    try std.testing.expect(state.finishPreparation(replacement, true));
    try std.testing.expectEqual(backend.Backend.local, state.acquire(2).?);
}
