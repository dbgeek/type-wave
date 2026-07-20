//! local_provisioner.zig — the Local Provisioner: the daemon's one route that warms the
//! local Transcription Backend from its Model Installation. It owns the load-verify → spawn
//! → corruption-vs-runtime-failure recovery latch (local_model_recovery.Recovery) and the
//! cross-thread FailureObservation the Status Item reads. Every effect — resolving the
//! installation on disk, verifying it offline, spawning the helper, building the adapter —
//! is reached through a dependency seam it is handed, so warm()'s recovery ordering is
//! exercised by scripted verify/load outcomes, not real subprocesses (the same shape as the
//! Backend Router and the Utterance Coordinator).
//!
//! The Deps seam (the daemon supplies the real one; tests supply a fake):
//!   Deps.Install         — opaque per-attempt handle; the real one carries the RuntimeLease.
//!   Deps.LocalResource   — the warmed resource the Backend Router's local slot receives.
//!   resolveInstall() ?Install           — read paths+artifact, acquire the RuntimeLease.
//!   verify(*const Install) !Integrity   — offline-verify the active Model Installation.
//!   startHelper(*Install) StartOutcome  — spawn + build the adapter; takes the lease on
//!                                         success. Callable twice (the verified-load retry).
//!   abandon(*Install)                   — release the lease on any early return (a no-op
//!                                         once a success took it).
//!   installationProbe() bool            — lightweight presence check (no lease).
//!   removeSuperseded()                  — drain-gated cleanup of superseded Installations.
//!   note(Event)                         — narration for the caller's log.

const std = @import("std");
const model_store = @import("model_store.zig");
const recovery_mod = @import("local_model_recovery.zig");
const failure_observation = @import("failure_observation.zig");
const status_item = @import("status_item.zig");

/// warm() reuses the store's verify verdict verbatim — usable / absent / corrupt(reason).
pub const Integrity = model_store.InstallationIntegrity;

/// warm()'s narration, mapped to the caller's log by the real Deps and asserted by fakes.
pub const Event = union(enum) {
    absent,
    corrupt: model_store.Corruption,
    verify_failed: anyerror,
    load_failed: anyerror,
    runtime_failure: anyerror,
    runtime_failure_after_verify: anyerror,
    adapter_unavailable,
};

/// startHelper's outcome. `started` = the helper process spawned AND the adapter was built;
/// `no_adapter` = the process spawned but the adapter could not be built (the process has
/// been shut down) — a load success from the recovery machine's view, but no resource to
/// return this attempt; `spawn_failed` = the process did not spawn (drives the verify/retry
/// latch).
pub fn StartOutcome(comptime Resource: type) type {
    return union(enum) {
        started: *Resource,
        no_adapter,
        spawn_failed: anyerror,
    };
}

pub fn LocalProvisioner(comptime Deps: type) type {
    return struct {
        const Self = @This();
        const Resource = Deps.LocalResource;
        const Install = Deps.Install;

        deps: *Deps,
        recovery: recovery_mod.Recovery = .{},
        failure: failure_observation.FailureObservation = .{},

        pub fn init(deps: *Deps) Self {
            return .{ .deps = deps };
        }

        /// Warm the local helper: resolve the installation, drive the recovery machine across
        /// verify/load, and return the Backend Router's local resource (null = not warm this
        /// attempt). Preserves the daemon's prior ordering exactly: an accepted installation
        /// is load-verified once on first failure, then a verified-load failure latches
        /// runtime_failure until a SIGHUP retry.
        pub fn warm(self: *Self) ?*Resource {
            var install = self.deps.resolveInstall() orelse return null;
            defer self.deps.abandon(&install);

            // A prior corrupt→retry left us mid-verify: finish the offline verify first.
            if (self.recovery.current() == .verifying) {
                if (!self.verifyAndDecide(&install)) return null;
            }
            if (self.recovery.current() == .corrupt or self.recovery.current() == .runtime_failure)
                return null;

            switch (self.deps.startHelper(&install)) {
                .started => |resource| return self.loaded(resource),
                .no_adapter => return self.loadedButUnavailable(),
                .spawn_failed => |err| {
                    // First failure from `ready` verifies once; a failure while already
                    // retrying a verified load latches runtime_failure.
                    if (self.recovery.loadFailed() != .verify) {
                        self.failure.setError("Local runtime load failed", err);
                        self.deps.note(.{ .runtime_failure = err });
                        return null;
                    }
                    self.deps.note(.{ .load_failed = err });
                    if (!self.verifyAndDecide(&install)) return null;
                    switch (self.deps.startHelper(&install)) {
                        .started => |resource| return self.loaded(resource),
                        .no_adapter => return self.loadedButUnavailable(),
                        .spawn_failed => |retry_err| {
                            _ = self.recovery.loadFailed(); // retrying_verified_load → runtime_failure
                            self.failure.setError("Local runtime load failed", retry_err);
                            self.deps.note(.{ .runtime_failure_after_verify = retry_err });
                            return null;
                        },
                    }
                },
            }
        }

        fn loaded(self: *Self, resource: *Resource) ?*Resource {
            self.recovery.loadSucceeded();
            self.failure.clear();
            return resource;
        }

        /// The helper spawned but the adapter couldn't be built: the recovery machine still
        /// sees a load success (a fresh attempt starts from `ready`), but there is nothing to
        /// hand the Router this tick.
        fn loadedButUnavailable(self: *Self) ?*Resource {
            self.recovery.loadSucceeded();
            self.failure.clear();
            self.deps.note(.adapter_unavailable);
            return null;
        }

        /// Offline-verify and fold the verdict into the recovery machine. Returns true when
        /// the verified installation should be (re)loaded, false when the caller must bail.
        fn verifyAndDecide(self: *Self, install: *Install) bool {
            const integrity = self.deps.verify(install) catch |err| {
                self.recovery.verificationFailed();
                self.failure.setError("Model Installation verification failed", err);
                self.deps.note(.{ .verify_failed = err });
                return false;
            };
            switch (integrity) {
                .usable => return self.recovery.verificationFinished(true) == .load,
                .absent => {
                    self.deps.note(.absent);
                    _ = self.recovery.verificationFinished(false);
                    return false;
                },
                .corrupt => |reason| {
                    var buffer: [256]u8 = undefined;
                    if (std.fmt.bufPrint(&buffer, "Model Installation corrupt: {s}", .{@tagName(reason)})) |detail|
                        self.failure.set(detail)
                    else |_| {}
                    self.deps.note(.{ .corrupt = reason });
                    _ = self.recovery.verificationFinished(false);
                    return false;
                },
            }
        }

        // ---- queries the daemon relays (config fact + Status Item + SIGHUP retry) ----

        /// A usable Model Installation is present on disk (the Configuration Phase fact and
        /// the Status Item both read this).
        pub fn installationPresent(self: *Self) bool {
            return self.recovery.installationUsable() and self.deps.installationProbe();
        }

        /// SIGHUP runtime Retry: nudge the recovery latch. True = a retry was armed.
        pub fn requestRetry(self: *Self) bool {
            return self.recovery.retry() != .none;
        }

        /// Drain-gated cleanup of superseded Model Installations (effect only; the drain gate
        /// stays with the Backend Router state the daemon reads).
        pub fn removeSuperseded(self: *Self) void {
            self.deps.removeSuperseded();
        }

        pub fn recoveryState(self: *Self) recovery_mod.State {
            return self.recovery.current();
        }

        pub fn failureDetail(self: *Self) ?status_item.FailureDetail {
            return self.failure.current();
        }
    };
}

// ─────────────────────────────── tests ───────────────────────────────
//
// The driver's recovery ordering, scripted against a fake seam — the payoff of the lift.
// The pure Recovery machine keeps its own transition tests in local_model_recovery.zig.

const testing = std.testing;

const FakeResource = struct { tag: u8 = 0 };

const FakeDeps = struct {
    pub const Install = struct {};
    pub const LocalResource = FakeResource;

    const Start = union(enum) { started, no_adapter, spawn_failed: anyerror };
    const EventTag = std.meta.Tag(Event);

    resolve: ?Install = Install{},
    verify_outcome: anyerror!Integrity = Integrity{ .absent = {} },
    starts: []const Start = &.{},
    start_index: usize = 0,
    start_calls: u32 = 0,
    abandon_calls: u32 = 0,
    resource: FakeResource = .{},

    events: [16]EventTag = undefined,
    events_len: usize = 0,

    pub fn resolveInstall(self: *FakeDeps) ?Install {
        return self.resolve;
    }
    pub fn abandon(self: *FakeDeps, _: *Install) void {
        self.abandon_calls += 1;
    }
    pub fn verify(self: *FakeDeps, _: *const Install) !Integrity {
        return self.verify_outcome;
    }
    pub fn startHelper(self: *FakeDeps, _: *Install) StartOutcome(FakeResource) {
        const script = self.starts[self.start_index];
        self.start_index += 1;
        self.start_calls += 1;
        return switch (script) {
            .started => .{ .started = &self.resource },
            .no_adapter => .no_adapter,
            .spawn_failed => |err| .{ .spawn_failed = err },
        };
    }
    pub fn installationProbe(_: *FakeDeps) bool {
        return true;
    }
    pub fn removeSuperseded(_: *FakeDeps) void {}
    pub fn note(self: *FakeDeps, event: Event) void {
        if (self.events_len < self.events.len) {
            self.events[self.events_len] = std.meta.activeTag(event);
            self.events_len += 1;
        }
    }
    fn sawEvent(self: *FakeDeps, tag: EventTag) bool {
        for (self.events[0..self.events_len]) |seen| if (seen == tag) return true;
        return false;
    }
};

const Provisioner = LocalProvisioner(FakeDeps);

test "usable installation loads on the first attempt" {
    var deps = FakeDeps{ .starts = &.{.started} };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource != null);
    try testing.expectEqual(recovery_mod.State.ready, prov.recoveryState());
    try testing.expectEqual(@as(u32, 1), deps.start_calls);
    try testing.expectEqual(@as(u32, 1), deps.abandon_calls); // defer released the lease
}

test "a spawn failure verifies once, then the verified load succeeds" {
    var deps = FakeDeps{
        .starts = &.{ .{ .spawn_failed = error.HelperSpawnFailed }, .started },
        .verify_outcome = Integrity{ .usable = undefined },
    };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource != null);
    try testing.expectEqual(recovery_mod.State.ready, prov.recoveryState());
    try testing.expect(deps.sawEvent(.load_failed));
    try testing.expectEqual(@as(u32, 2), deps.start_calls);
}

test "a verified load that fails again latches runtime_failure" {
    var deps = FakeDeps{
        .starts = &.{ .{ .spawn_failed = error.HelperSpawnFailed }, .{ .spawn_failed = error.HelperSpawnFailed } },
        .verify_outcome = Integrity{ .usable = undefined },
    };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource == null);
    try testing.expectEqual(recovery_mod.State.runtime_failure, prov.recoveryState());
    try testing.expect(prov.failureDetail() != null);
    try testing.expect(deps.sawEvent(.runtime_failure_after_verify));
}

test "a corrupt verdict stops before a retry spawn" {
    var deps = FakeDeps{
        .starts = &.{.{ .spawn_failed = error.HelperSpawnFailed }},
        .verify_outcome = Integrity{ .corrupt = .digest_mismatch },
    };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource == null);
    try testing.expectEqual(recovery_mod.State.corrupt, prov.recoveryState());
    try testing.expect(prov.failureDetail() != null);
    try testing.expect(deps.sawEvent(.corrupt));
    try testing.expectEqual(@as(u32, 1), deps.start_calls); // no retry after corrupt
}

test "an absent installation stops and does not retry" {
    var deps = FakeDeps{
        .starts = &.{.{ .spawn_failed = error.HelperSpawnFailed }},
        .verify_outcome = Integrity{ .absent = {} },
    };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource == null);
    try testing.expectEqual(recovery_mod.State.corrupt, prov.recoveryState());
    try testing.expect(deps.sawEvent(.absent));
    try testing.expectEqual(@as(u32, 1), deps.start_calls);
}

test "a verification failure latches runtime_failure" {
    var deps = FakeDeps{
        .starts = &.{.{ .spawn_failed = error.HelperSpawnFailed }},
        .verify_outcome = error.VerificationBroke,
    };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource == null);
    try testing.expectEqual(recovery_mod.State.runtime_failure, prov.recoveryState());
    try testing.expect(deps.sawEvent(.verify_failed));
    try testing.expectEqual(@as(u32, 1), deps.start_calls);
}

test "an already-latched runtime_failure short-circuits before any spawn" {
    var deps = FakeDeps{}; // no start scripts — startHelper must never be called
    var prov = Provisioner.init(&deps);
    // Drive the machine to runtime_failure: ready → verifying → retrying_verified_load → runtime_failure.
    _ = prov.recovery.loadFailed();
    _ = prov.recovery.verificationFinished(true);
    _ = prov.recovery.loadFailed();
    try testing.expectEqual(recovery_mod.State.runtime_failure, prov.recoveryState());

    const resource = prov.warm();
    try testing.expect(resource == null);
    try testing.expectEqual(@as(u32, 0), deps.start_calls);
}

test "requestRetry re-arms a latched runtime_failure so the next warm loads" {
    var deps = FakeDeps{ .starts = &.{.started} };
    var prov = Provisioner.init(&deps);
    _ = prov.recovery.loadFailed();
    _ = prov.recovery.verificationFinished(true);
    _ = prov.recovery.loadFailed(); // → runtime_failure

    try testing.expect(prov.requestRetry());
    const resource = prov.warm();
    try testing.expect(resource != null);
    try testing.expectEqual(recovery_mod.State.ready, prov.recoveryState());
}

test "a spawn that leaves no adapter counts as loaded but returns nothing" {
    var deps = FakeDeps{ .starts = &.{.no_adapter} };
    var prov = Provisioner.init(&deps);

    const resource = prov.warm();
    try testing.expect(resource == null);
    try testing.expectEqual(recovery_mod.State.ready, prov.recoveryState()); // spawn succeeded
    try testing.expect(deps.sawEvent(.adapter_unavailable));
}

test "entering mid-verify (a corrupt retry) verifies, then loads" {
    var deps = FakeDeps{
        .starts = &.{.started},
        .verify_outcome = Integrity{ .usable = undefined },
    };
    var prov = Provisioner.init(&deps);
    // corrupt, then a SIGHUP retry arms an offline re-verify (state → verifying).
    _ = prov.recovery.loadFailed();
    _ = prov.recovery.verificationFinished(false); // → corrupt
    _ = prov.recovery.retry(); // corrupt → verifying
    try testing.expectEqual(recovery_mod.State.verifying, prov.recoveryState());

    const resource = prov.warm();
    try testing.expect(resource != null);
    try testing.expectEqual(recovery_mod.State.ready, prov.recoveryState());
}
