//! daemon.zig — the type-wave daemon (wayfinder #19; lifecycle lifted into the
//! Utterance Coordinator by the 2026-07-08 architecture review, candidate 1; menu-bar
//! Status Item + live settings grown by #34).
//!
//! The capstone that turns the proven modules into a real daily-driver background daemon:
//! hold the Talk Key → CoreAudio Capture streams to the warm OpenAI Transcription Session →
//! on release the Final Transcript is inserted at the cursor of the Focused Target — running
//! headless under the LaunchAgent (#15), settings and secret from config (#16), the session
//! keeping itself warm and reconnecting between Utterances (#17), every transition and
//! failure surfaced through feedback (#18) and the overlay HUD (#22).
//!
//! # Where the logic lives now
//!
//! The Utterance lifecycle — the overlap guard, poison-on-drop abandonment, the
//! release-anchored deadline, empty/failed handling — used to be spread across this file's
//! onPress / onRelease / workerLoop / processUtterance and coordinated through four
//! cross-thread atomics. It is now the **Utterance Coordinator** (coordinator.zig): one
//! synchronous state machine, tested by feeding it events. This file is what remains once
//! that logic is gone: the *wiring* — it builds the real adapters that satisfy the
//! Coordinator's four seams, trampolines real-world events into `coordinator.handle`, and
//! runs the two supervisory state machines below.
//!
//! # Two orthogonal state machines still assembled here
//!
//! 1. **Configuration Phase** (configuration_phase.zig, driven by the self-heal
//!    supervisor): `not-configured` ⇄ `configured`. The gate is (API key present) AND
//!    (Input Monitoring granted) AND (PostEvent granted) AND (tap enabled). Missing
//!    prerequisites do NOT crash the daemon (the LaunchAgent's KeepAlive would crash-loop);
//!    the supervisor polls (~3 s), executes the phase module's actions, and reserves
//!    `exit(0)` for a clean SIGTERM/bootout. On a cold start the supervisor also runs
//!    #130's serialized TCC request sequence (grant_sequence.zig) and the two live
//!    pickup mechanisms #127/#129 confirmed: fresh-create tap re-arm for Input
//!    Monitoring, tagged-probe attempt-then-observe for PostEvent — zero restarts.
//! 2. **Link state** (owned by session.zig): connecting / ready / reconnecting / closed.
//!
//! # Threads
//!   - main / run-loop  : installs the tap, the overlay HUD render pump, and the menu-bar
//!                        status item (#34), then blocks in [NSApp run] (appkit.zig — the
//!                        #31 swap; plain CFRunLoopRun when headless). The tap callback
//!                        trampolines press/release into the Coordinator (kept fast — a
//!                        slow tap callback makes the OS disable the tap). All AppKit
//!                        happens here, menu actions included.
//!   - insert worker    : the InsertionAdapter — drains one insert job, performs the slow
//!                        Insertion off the Coordinator's mutex, then reports `.inserted`.
//!   - rewrite worker   : the RewriteAdapter (docs/backtrack-spec.md) — drains one
//!                        Backtrack rewrite job, makes the OpenAI Responses call off the
//!                        Coordinator's mutex, then reports `.rewritten`.
//!   - deadline timer   : the DeadlineAdapter — fires `.deadline` if a Final Transcript does
//!                        not arrive within the release-anchored window.
//!   - supervisor       : the self-heal loop (config phase above).
//!   - read-loop        : (session.zig) delivers Partial/Final Transcripts into the
//!                        Coordinator via the always-on observer.
//!   - maintenance/sender: (session.zig) keepalive + reconnect; the outbound ring drain.
//!   - quit watcher      : waits for SIGINT/SIGTERM, then stops the run loop.
//!   - AudioQueue thread : delivers Capture chunks, forwarded to the current session.
//! The Coordinator's single mutex serializes every lifecycle event across these threads.

const std = @import("std");
const cap = @import("capture.zig");
const session_mod = @import("session.zig");
const tapmod = @import("tap.zig");
const insertmod = @import("insert.zig");
const config = @import("config.zig");
const feedback = @import("feedback.zig");
const hud_mod = @import("hud.zig");
const surface = @import("surface.zig");
const coord = @import("coordinator.zig");
const menu_mod = @import("menu.zig");
const appkit = @import("appkit.zig");
const keychain = @import("keychain.zig");
const insertion_adapter = @import("insertion_adapter.zig");
const rewrite_adapter = @import("rewrite_adapter.zig");
const openai_rewrite = @import("openai_rewrite.zig");
const readiness = @import("readiness.zig");
const configuration_phase = @import("configuration_phase.zig");
const supervisor = @import("supervisor.zig");
const grant_sequence = @import("grant_sequence.zig");
const backend = @import("transcription_backend.zig");
const backend_router = @import("backend_router.zig");
const operation_channel = @import("operation_channel.zig");
const model_operation = @import("model_operation.zig");
const local_backend = @import("local_backend.zig");
const whisper_process_helper = @import("whisper_process_helper.zig");
const model_store = @import("model_store.zig");
const local_provisioner = @import("local_provisioner.zig");
const status_item = @import("status_item.zig");

const Session = session_mod.Session;
const LocalAdapter = local_backend.Adapter(whisper_process_helper.ProcessHelper);

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

const CFRunLoopRef = ?*anyopaque;
extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
extern "c" fn CFRunLoopStop(rl: CFRunLoopRef) void;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) callconv(.c) usize;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIGHUP: c_int = 1;

/// Alias for the libc `kill` extern, so the Model Operation Runner's `Deps.kill` method can
/// call it without its own name shadowing the extern inside its body.
const posixKill = kill;

/// model_operation.zig's `Deps` seam, made real (wayfinder #95). The Model Operation Runner
/// owns the operation policy and its cross-thread observation; this adapter is the effects
/// it drives: resolve the daemon's own executable, spawn the Model Operation child with the
/// built argv + environment, write any confirmation to its stdin, run the two drain threads
/// that re-enter the Runner via trampolines (stdout → decoded operation-channel events;
/// stderr → prose / failure fallback, then the terminal outcome), and kill on cancel.
const ModelOperationRunnerDeps = struct {
    daemon: *Daemon,

    /// Resolve the executable, spawn the child (writing any confirmation to its stdin), and
    /// hand the child to the waiter drain thread. Returns the child's pid, or null when any
    /// step fails — the Runner then begins nothing (no phantom operation). `begin` runs the
    /// instant this returns, before the child can emit; the pipes buffer anything that races
    /// ahead of it.
    pub fn launch(self: *ModelOperationRunnerDeps, request: model_operation.LaunchRequest) ?c_int {
        const d = self.daemon;
        var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var executable_size: u32 = executable_buffer.len;
        if (_NSGetExecutablePath(&executable_buffer, &executable_size) != 0) return null;
        const executable = std.mem.sliceTo(executable_buffer[0..executable_size], 0);
        var child = std.process.spawn(d.io, .{
            .argv = &.{ executable, request.argument },
            .environ_map = d.process_environ,
            .stdin = if (request.confirmation != null) .pipe else .ignore,
            .stdout = .pipe, // the typed Model Operation channel (operation_channel.zig)
            .stderr = .pipe, // human prose: daemon log + failure fallback
        }) catch |failure| {
            feedback.log("  menu: could not start Model Operation: {s}\n", .{@errorName(failure)});
            return null;
        };
        if (request.confirmation) |answer| {
            child.stdin.?.writeStreamingAll(d.io, answer) catch {
                child.kill(d.io);
                return null;
            };
            child.stdin.?.close(d.io);
            child.stdin = null;
        }
        const pid: c_int = @intCast(child.id.?);
        const waiter = std.Thread.spawn(.{}, drainModelOperation, .{ d.io, child, &d.model_operation_runner }) catch {
            child.kill(d.io);
            return null;
        };
        waiter.detach();
        return pid;
    }

    /// Cancel routing's effect: deliver SIGTERM to the live child the Runner named.
    pub fn kill(_: *ModelOperationRunnerDeps, pid: c_int) void {
        _ = posixKill(pid, SIGTERM);
    }

    /// Narration for the daemon log: the child's stderr prose, and the terminal line.
    pub fn log(_: *ModelOperationRunnerDeps, note: model_operation.Note) void {
        switch (note) {
            .stderr => |line| feedback.log("  model: {s}\n", .{line}),
            .finished => |finished| feedback.log("  menu: Model Operation {s} {s}\n", .{
                @tagName(finished.action),
                if (finished.succeeded) "finished" else "failed",
            }),
        }
    }
};
const ModelOperationRunner = model_operation.Runner(ModelOperationRunnerDeps);

/// The waiter drain thread the Deps runs per launch (one of the two): it spawns the stdout
/// channel drain, streams the child's stderr prose into the Runner (failure fallback + log),
/// then joins the channel drain and reports the terminal outcome. Re-enters the Runner via
/// the pointer it is handed — the Runner must not move (model_operation.zig).
fn drainModelOperation(io: std.Io, child_value: std.process.Child, runner: *ModelOperationRunner) void {
    var child = child_value;
    const channel_thread: ?std.Thread = std.Thread.spawn(.{}, drainOperationChannel, .{ io, child.stdout.?, runner }) catch null;
    if (channel_thread == null)
        feedback.log("  menu: Model Operation channel reader unavailable — progress will not update\n", .{});
    var read_buffer: [2048]u8 = undefined;
    var stderr_reader = child.stderr.?.readerStreaming(io, &read_buffer);
    while (stderr_reader.interface.takeDelimiter('\n') catch null) |line| runner.onStderr(line);
    if (channel_thread) |thread| thread.join(); // both pipes hit EOF at child exit
    const term = child.wait(io) catch return runner.onTerminal(false);
    runner.onTerminal(term.success());
}

/// The stdout channel drain thread (the other of the two): decoded operation-channel events
/// drive the Runner's observation — phase and byte progress; anything undecodable on this
/// stream is silently skipped.
fn drainOperationChannel(io: std.Io, stdout_value: std.Io.File, runner: *ModelOperationRunner) void {
    var stdout = stdout_value;
    var read_buffer: [2048]u8 = undefined;
    var reader = stdout.readerStreaming(io, &read_buffer);
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (operation_channel.decode(line)) |event| runner.onChannelEvent(event);
    }
}

// ---- tuning ----------------------------------------------------------------
/// Self-heal poll cadence. Fast enough that granting a permission / dropping in the key
/// feels responsive, slow enough to be invisible in the log while waiting.
const supervisor_tick_ms: usize = 3_000;
/// Release-anchored Insertion deadline (grilled for #19): armed when the Coordinator enters
/// `awaiting_final`, so it bounds both the live wait and a reconnect-spanning wait. Past it
/// the Utterance is dropped rather than inserting stale text or blocking new Utterances.
/// Raised by the SIGINT/SIGTERM handler (async-signal-safe store only); the quit watcher
/// polls it and stops the run loop, and the supervisor + adapter threads poll it to end.
var g_quit = std.atomic.Value(bool).init(false);
var g_retry_local = std.atomic.Value(bool).init(false);

fn onSignal(_: c_int) callconv(.c) void {
    g_quit.store(true, .release);
}

fn onRetryLocal(_: c_int) callconv(.c) void {
    g_retry_local.store(true, .release);
}

/// Waits for the quit signal, then unwinds the main loop. Under the status item that
/// loop is [NSApp run], which CFRunLoopStop does NOT unwind — menu.requestStop routes
/// [NSApp stop:] onto the main thread instead (#34 quit-path audit). Headless (no menu)
/// falls back to CFRunLoopStop (documented thread-safe), unblocking tap.run().
fn quitWatcher(loop: CFRunLoopRef) void {
    while (!g_quit.load(.acquire)) _ = usleep(50_000);
    if (!menu_mod.requestStop()) CFRunLoopStop(loop);
}

/// A sleep that returns early once quitting, so the supervisor joins promptly at shutdown.
fn sleepInterruptible(ms: usize) void {
    var waited: usize = 0;
    while (waited < ms and !g_quit.load(.acquire)) {
        _ = usleep(50_000);
        waited += 50;
    }
}

/// Human-readable name for the configured Talk Key, for the log.
fn keyName(k: tapmod.TalkKey) []const u8 {
    return switch (k) {
        .right_option => "Right-Option",
        .left_option => "Left-Option",
        .globe => "Globe/Fn",
    };
}

// ============================================================================
// The real adapters satisfying the Utterance Coordinator's four outbound seams.
// (Audio is Capture itself — it already fits the seam, so it needs no wrapper.)
// ============================================================================

/// Transcription seam: the Backend Router's daemon-side dependencies (backend_router.zig
/// owns the drain-then-switch policy). This supplies the effectful provisioning, the
/// Settings Snapshot language, the Configuration Phase bridge, and the narration.
const DaemonDeps = struct {
    pub const SessionResource = Session;
    pub const LocalResource = LocalAdapter;

    daemon: *Daemon,
    /// Freshly loaded by gatherOutcome for this tick's potential connect; the Session
    /// retains the slice (a process-lifetime allocation, like snapshots).
    pending_key: ?[]const u8 = null,
    /// The Configuration Phase outcome gathered mid-tick by `wants`; the supervisor
    /// loop executes its non-router actions (READY, reporting) afterwards.
    outcome: configuration_phase.Outcome = undefined,

    pub fn connectOpenai(self: *DaemonDeps) !*Session {
        const d = self.daemon;
        const key = self.pending_key orelse return error.MissingApiKey;
        return Session.connect(d.io, d.alloc, key, .{ .ctx = d, .get = Daemon.getParams }, d.observer());
    }

    pub fn prepareLocal(self: *DaemonDeps) ?*LocalAdapter {
        return self.daemon.provisioner.warm();
    }

    /// The Backend Router asks between reconciliation and preparation, exactly once
    /// per tick, so the Configuration Phase sees post-teardown facts.
    pub fn wants(self: *DaemonDeps) backend_router.Wants {
        self.outcome = self.daemon.gatherOutcome();
        return .{
            .connect_openai = self.outcome.actions.connect_session and self.pending_key != null,
            .prepare_local = self.outcome.actions.prepare_local,
        };
    }

    pub fn language(self: *DaemonDeps) backend.Language {
        return self.daemon.store.current().language;
    }

    /// Stamped onto every new Lease at acquire, so Backtrack enablement is pinned at
    /// Talk Key press (docs/backtrack-spec.md) like the backend and language.
    pub fn backtrack(self: *DaemonDeps) bool {
        return self.daemon.store.current().backtrack;
    }

    pub fn note(self: *DaemonDeps, event: backend_router.Event) void {
        _ = self;
        switch (event) {
            .stale => feedback.log("  local Model Installation changed — draining old helper and warming the activated replacement\n", .{}),
            .ready => |which| switch (which) {
                .openai => feedback.log("  supervisor: API key found — Transcription Session connecting…\n", .{}),
                .local => feedback.log("  local Whisper helper warm — Capture stays on this Mac\n", .{}),
            },
            .prepare_failed => |failure| if (failure.which == .openai)
                feedback.log("  supervisor: session connect failed: {s} — will retry\n", .{@errorName(failure.err orelse error.Unknown)}),
            .tore_down => {}, // teardown of drained resources is routine, not news
        }
    }
};
const BackendRouter = backend_router.Router(DaemonDeps);

/// Local Provisioner seam: the daemon-side effects behind LocalProvisioner.warm(). The
/// opaque Install carries the RuntimeLease across verify and both spawn attempts; the real
/// startHelper transfers it into the warmed LocalAdapter on success, and abandon() releases
/// it (a no-op once taken) on every early return. All model_store / subprocess / adapter
/// coupling lives here, so the Provisioner's recovery ordering stays fakeable.
const LocalProvisionerDeps = struct {
    pub const LocalResource = LocalAdapter;
    pub const Install = struct {
        root_buf: [std.fs.max_path_bytes]u8 = undefined,
        root_len: usize = 0,
        helper_buf: [std.fs.max_path_bytes]u8 = undefined,
        helper_len: usize = 0,
        model_buf: [std.fs.max_path_bytes]u8 = undefined,
        model_len: usize = 0,
        artifact: model_store.ArtifactIdentity = undefined,
        lease: model_store.RuntimeLease = undefined,

        fn root(self: *const Install) []const u8 {
            return self.root_buf[0..self.root_len];
        }
        fn helperPath(self: *const Install) []const u8 {
            return self.helper_buf[0..self.helper_len];
        }
        fn modelPath(self: *const Install) []const u8 {
            return self.model_buf[0..self.model_len];
        }
    };

    daemon: *Daemon,

    pub fn resolveInstall(self: *LocalProvisionerDeps) ?Install {
        const d = self.daemon;
        const raw_home = std.c.getenv("HOME") orelse return null;
        const home = std.mem.span(raw_home);
        var install: Install = .{};
        const helper = std.fmt.bufPrint(&install.helper_buf, "{s}/.local/libexec/type-wave/type-wave-whisper", .{home}) catch return null;
        install.helper_len = helper.len;
        const root = model_store.rootPath(home, &install.root_buf) catch return null;
        install.root_len = root.len;
        install.lease = model_store.RuntimeLease.acquire(d.io, install.root()) catch return null;
        const model = (model_store.activeModelPath(d.io, install.root(), &install.model_buf) catch {
            install.lease.release();
            return null;
        }) orelse {
            install.lease.release();
            return null;
        };
        install.model_len = model.len;
        install.artifact = (model_store.activeArtifact(d.io, install.root()) catch {
            install.lease.release();
            return null;
        }) orelse {
            install.lease.release();
            return null;
        };
        return install;
    }

    pub fn verify(self: *LocalProvisionerDeps, install: *const Install) !local_provisioner.Integrity {
        const cancel = model_store.CancelToken{};
        return model_store.verifyActiveInstallation(self.daemon.io, install.root(), model_store.pinned_manifest, &model_store.trusted_manifests, &cancel, null);
    }

    pub fn startHelper(self: *LocalProvisionerDeps, install: *Install) local_provisioner.StartOutcome(LocalAdapter) {
        const d = self.daemon;
        const helper = whisper_process_helper.ProcessHelper.start(d.alloc, d.io, install.helperPath(), install.modelPath(), install.artifact) catch |failure| {
            return .{ .spawn_failed = failure };
        };
        const local = d.alloc.create(LocalAdapter) catch {
            helper.shutdown();
            return .no_adapter;
        };
        local.* = LocalAdapter.init(d.alloc, d.io, helper, .{
            .ctx = d,
            .final = Daemon.localFinal,
            .failed = Daemon.localFailed,
        });
        local.setInferenceRoot(install.root(), &install.lease) catch {
            helper.shutdown();
            d.alloc.destroy(local);
            return .no_adapter;
        };
        local.bindHelperEvents();
        return .{ .started = local };
    }

    pub fn abandon(_: *LocalProvisionerDeps, install: *Install) void {
        install.lease.release();
    }

    pub fn installationProbe(self: *LocalProvisionerDeps) bool {
        const d = self.daemon;
        const raw_home = std.c.getenv("HOME") orelse return false;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = model_store.rootPath(std.mem.span(raw_home), &root_buf) catch return false;
        if (model_store.modelRemovalPending(d.io, root)) return false;
        var model_buf: [std.fs.max_path_bytes]u8 = undefined;
        return (model_store.activeModelPath(d.io, root, &model_buf) catch return false) != null;
    }

    pub fn removeSuperseded(self: *LocalProvisionerDeps) void {
        const d = self.daemon;
        const raw_home = std.c.getenv("HOME") orelse return;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = model_store.rootPath(std.mem.span(raw_home), &root_buf) catch return;
        const removed = model_store.removeInactiveInstallations(d.io, root) catch |failure| {
            if (failure == error.ModelOperationInProgress or failure == error.ModelInferenceActive) return;
            feedback.log("  superseded Model Installation cleanup failed: {s}; retrying while idle\n", .{@errorName(failure)});
            return;
        };
        if (removed > 0) feedback.log("  removed {d} superseded Model Installation(s) after helper drain\n", .{removed});
    }

    pub fn note(_: *LocalProvisionerDeps, event: local_provisioner.Event) void {
        switch (event) {
            .absent => feedback.log("  local Model Installation is absent; Install is required\n", .{}),
            .corrupt => |reason| feedback.log("  local Model Installation is corrupt ({s}); Repair or Remove is required\n", .{@tagName(reason)}),
            .verify_failed => |failure| feedback.log("  local Model Installation verification failed: {s}; runtime Retry remains available\n", .{@errorName(failure)}),
            .load_failed => |failure| feedback.log("  local Whisper load failed: {s}; verifying the Model Installation offline\n", .{@errorName(failure)}),
            .runtime_failure => |failure| feedback.log("  local Whisper runtime failure after verified installation: {s}; send SIGHUP to Retry\n", .{@errorName(failure)}),
            .runtime_failure_after_verify => |failure| feedback.log("  Model Installation verified, but local runtime load failed again: {s}; send SIGHUP to Retry\n", .{@errorName(failure)}),
            .adapter_unavailable => feedback.log("  local Whisper unavailable: adapter allocation failed\n", .{}),
        }
    }
};
const LocalProvisioner = local_provisioner.LocalProvisioner(LocalProvisionerDeps);

/// Real dependencies for insertion_adapter.zig. The adapter owns the asynchronous
/// Insertion policy; daemon.zig supplies the concrete macOS mechanism, Settings Snapshot,
/// process quit flag, and reverse edge into the Coordinator.
const RealInsertionDeps = struct {
    inserter: *insertmod.Inserter,
    store: *config.Store,

    co_ctx: *anyopaque = undefined,
    on_done: *const fn (*anyopaque, coord.UtteranceId, coord.InsertResult) void = undefined,

    pub fn insertionPlan(self: *RealInsertionDeps) insertmod.Plan {
        const s = self.store.current(); // one snapshot: method + settle stay coherent
        return .{ .method = s.insertion, .pre_paste_ms = s.pre_paste_ms };
    }
    pub fn insert(self: *RealInsertionDeps, plan: insertmod.Plan, text: [*:0]const u8) insertmod.InsertError!void {
        return self.inserter.insert(plan, text);
    }
    pub fn complete(self: *RealInsertionDeps, id: coord.UtteranceId, result: coord.InsertResult) void {
        self.on_done(self.co_ctx, id, result);
    }
    pub fn finishInsert(self: *RealInsertionDeps) void {
        self.inserter.drainDeferredRestore();
    }
    pub fn shouldQuit(_: *RealInsertionDeps) bool {
        return g_quit.load(.acquire);
    }
    pub fn idle(_: *RealInsertionDeps) void {
        _ = usleep(2_000);
    }
};
const InsertionAdapter = insertion_adapter.InsertionAdapter(RealInsertionDeps);

/// Real dependencies for rewrite_adapter.zig (docs/backtrack-spec.md). The adapter owns
/// the asynchronous Rewrite policy; daemon.zig supplies the OpenAI mechanism — the
/// long-lived HTTP client whose connection pool keeps HTTPS warm across Utterances, the
/// existing OpenAI key loader — the process quit flag, and the reverse edge into the
/// Coordinator.
const RealRewriteDeps = struct {
    daemon: *Daemon,

    co_ctx: *anyopaque = undefined,
    on_done: *const fn (*anyopaque, coord.UtteranceId, []const u8, coord.RewriteResult) void = undefined,

    pub fn rewrite(self: *RealRewriteDeps, raw: []const u8, out: []u8) anyerror![]const u8 {
        const d = self.daemon;
        // Freshly loaded per rewrite, like the supervisor's poll — env override first,
        // then the keychain item. Freed after the call; only Sessions retain a key.
        const key = config.loadApiKeyOnly(d.io, d.alloc) orelse return error.RewriteKeyMissing;
        defer d.alloc.free(key);
        return openai_rewrite.rewrite(&d.rewrite_http, d.alloc, key, raw, out);
    }
    pub fn complete(self: *RealRewriteDeps, id: coord.UtteranceId, text: []const u8, result: coord.RewriteResult) void {
        self.on_done(self.co_ctx, id, text, result);
    }
    pub fn shouldQuit(_: *RealRewriteDeps) bool {
        return g_quit.load(.acquire);
    }
    pub fn idle(_: *RealRewriteDeps) void {
        _ = usleep(2_000);
    }
};
const RewriteAdapter = rewrite_adapter.RewriteAdapter(RealRewriteDeps);

/// Deadline seam: a small timer thread. `arm` (Coordinator releasing an Utterance) sets
/// the backend's cooperative and final fire times; `cancel` (Final Transcript) clears both.
/// Claimed actions re-enter the Coordinator, whose identity/phase guard rejects stale races.
const DeadlineAdapter = struct {
    io: std.Io = undefined,
    mu: std.Io.Mutex = .init,
    state: backend.DeadlineState = .{},

    co_ctx: *anyopaque = undefined,
    on_cooperative_cancel: *const fn (*anyopaque, backend.UtteranceId) void = undefined,
    on_fire: *const fn (*anyopaque, backend.UtteranceId, backend.DeadlineKind) void = undefined,

    pub fn arm(self: *DeadlineAdapter, id: backend.UtteranceId, kind: backend.DeadlineKind, policy: backend.DeadlinePolicy) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.state.arm(id, kind, session_mod.nowMs(), policy);
    }
    pub fn cancel(self: *DeadlineAdapter, id: backend.UtteranceId) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.state.cancel(id);
    }
    fn timerLoop(self: *DeadlineAdapter) void {
        while (!g_quit.load(.acquire)) {
            self.mu.lockUncancelable(self.io);
            const claimed = self.state.claim(session_mod.nowMs());
            self.mu.unlock(self.io);
            if (claimed) |action| switch (action) {
                .cooperative_cancel => |id| self.on_cooperative_cancel(self.co_ctx, id),
                .final => |fired| self.on_fire(self.co_ctx, fired.id, fired.kind),
            };
            _ = usleep(1_000);
        }
    }
};

// The Coordinator's dependency set, wired to the real adapters above.
const RealDeps = struct {
    audio: *cap.Capture,
    backends: *BackendRouter,
    rewrite: *RewriteAdapter,
    insertion: *InsertionAdapter,
    deadline: *DeadlineAdapter,
    feedback: *surface.Surface,
};
const Coord = coord.Coordinator(RealDeps);

// Reverse-edge trampolines: the adapters' worker/timer threads carry the Coordinator as an
// opaque pointer and re-enter it here (its concrete type is known at this wiring site).
fn insertDoneTramp(ctx: *anyopaque, id: coord.UtteranceId, result: coord.InsertResult) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.{ .inserted = .{ .id = id, .result = result } });
}
fn rewriteDoneTramp(ctx: *anyopaque, id: coord.UtteranceId, text: []const u8, result: coord.RewriteResult) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.{ .rewritten = .{ .id = id, .text = text, .result = result } });
}
fn deadlineFireTramp(ctx: *anyopaque, id: backend.UtteranceId, kind: backend.DeadlineKind) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.{ .deadline = .{ .id = id, .kind = kind } });
}
fn cooperativeCancelTramp(ctx: *anyopaque, id: backend.UtteranceId) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.{ .cooperative_cancel = id });
}

/// The whole daemon: the long-lived modules, the real adapters, and the Coordinator they
/// feed. A single instance lives on `run`'s stack for the process lifetime; its address is
/// handed to every thread and to the tap as its callback context, so it must not move.
const Daemon = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    process_environ: *const std.process.Environ.Map,

    // ---- live settings (#16, made mutable by #32/#34): the immutable-snapshot store.
    //      The menu is the sole writer; every reader acquire-loads a coherent snapshot
    //      at use (tap → talk_key, insert worker → insertion, session connect → params).
    store: config.Store,

    /// Menu-bar "Pause dictation" (#34): a paused daemon ignores Talk Key presses (the
    /// key keeps its normal OS meaning). Runtime-only — not a config.zon field.
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    capture_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ---- long-lived modules ----
    capture: cap.Capture = .{},
    inserter: insertmod.Inserter = .{},
    cues: feedback.Cues = .{},
    hud: hud_mod.Hud = .{},
    menu: menu_mod.Menu = .{},
    tap: tapmod.Tap = undefined, // built in run()

    // ---- the Coordinator's real adapters + the Coordinator itself (wired in run()) ----
    router_deps: DaemonDeps = undefined,
    transcription: BackendRouter = undefined,
    /// The Backtrack Rewrite worker's HTTP client (docs/backtrack-spec.md): a fresh
    /// std.http.Client use — the realtime websocket is not reusable for a REST call.
    /// Its connection pool keeps the HTTPS connection warm across Utterances. Only the
    /// rewrite worker thread touches it; never deinitialized (process-lifetime, like
    /// the Session).
    rewrite_http: std.http.Client = undefined,
    rewrite: RewriteAdapter = undefined,
    insertion: InsertionAdapter = undefined,
    deadline: DeadlineAdapter = .{},
    feedback_surface: surface.Surface = undefined,
    coordinator: Coord = undefined,

    /// The Model Operation Runner (model_operation.zig, wayfinder #94) + its real Deps: the
    /// daemon's one route from a Status Item action to a Model Operation child, and the owner
    /// of that operation's observation. Wired in run(); driven by menuModelAction, read by
    /// menuStatus. Handed out by pointer and must not move (its observation atomics are
    /// addressed in place).
    model_operation_runner_deps: ModelOperationRunnerDeps = undefined,
    model_operation_runner: ModelOperationRunner = undefined,

    /// Supervisor-thread-only: owns Configuration Phase memory, including READY
    /// announcements and distinct not-configured reports.
    configuration: configuration_phase.ConfigurationPhase = .{},
    /// Supervisor-thread-only: #130's serialized cold-start TCC request sequence —
    /// Microphone → Input Monitoring → PostEvent, one request in flight at a time,
    /// advancing on grant or a 60 s per-grant timeout. Never restarts anything.
    grants: grant_sequence.Sequence = .{},
    /// Supervisor-thread-only: prints the sequence header once, right before its
    /// first `[N/3]` line, so the block stays contiguous in the log.
    grants_header_printed: bool = false,
    /// Attempt-then-observe latch for the PostEvent grant (#129): set by the tap
    /// callback when a self-tagged Insertion probe round-trips the event stream.
    /// `CGPreflightPostEventAccess` can stay stale-`false` for the process lifetime
    /// after a live grant, so this latch is the only trustworthy in-process signal.
    post_event_observed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    provisioner_deps: LocalProvisionerDeps = undefined,
    provisioner: LocalProvisioner = undefined,

    /// Always-on live-transcript subscriber: Final Transcripts from the read-loop thread
    /// trampoline into the Coordinator. Installed at every Session.connect, before the read
    /// loop starts — never mid-stream. Partials are not subscribed — the HUD shows no text
    /// (wayfinder #27); their log lives upstream in session.zig (#18).
    fn observer(self: *Daemon) session_mod.TranscriptObserver {
        return .{ .ctx = self, .on_final = obsFinal, .on_drop = obsDropped };
    }
    fn obsFinal(ctx: ?*anyopaque, id: backend.UtteranceId, text: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.coordinator.handle(.{ .final = .{ .id = id, .text = text } });
    }
    fn obsDropped(ctx: ?*anyopaque, id: backend.UtteranceId) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.coordinator.handle(.{ .backend_failed = id });
    }
    fn localFinal(ctx: *anyopaque, id: backend.UtteranceId, text: []const u8) void {
        obsFinal(ctx, id, text);
    }
    fn localFailed(ctx: *anyopaque, id: backend.UtteranceId) void {
        obsDropped(ctx, id);
    }

    fn localRetryLoop(self: *Daemon) void {
        while (!g_quit.load(.acquire)) {
            if (g_retry_local.swap(false, .acq_rel) and self.transcription.selected() == .local) {
                if (self.transcription.retryLocal()) {
                    feedback.log("  local Whisper Retry requested\n", .{});
                } else if (self.provisioner.requestRetry()) {
                    feedback.log("  local Whisper load Retry requested\n", .{});
                }
            }
            _ = usleep(50_000);
        }
    }

    /// Capture chunk sink: forward PCM to the current Session (created lazily by the
    /// supervisor). A press only starts Capture once a session exists, so the null case is
    /// belt-and-braces for a chunk delivered during teardown.
    fn audioSink(ctx: ?*anyopaque, pcm: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        const id = self.transcription.activeId();
        _ = self.transcription.appendCurrent(pcm) catch {
            self.coordinator.handle(.{ .backend_failed = id });
            return;
        };
    }

    /// Capture level sink: one raw RMS per 50 ms buffer, straight to the HUD's queue —
    /// no Coordinator traffic; levels are continuous telemetry, not lifecycle edges
    /// (wayfinder #26). The HUD drops them unless it is showing `.recording`.
    fn levelSink(ctx: ?*anyopaque, rms: f32) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.hud.pushLevel(rms);
    }

    // ---- tap callbacks: run on the run-loop thread, kept fast (filter, then trampoline) ----
    // talk_key is read from the live snapshot per event (#32 read-at-use): a menu change
    // binds at the next press. Release is NOT pause-gated so a hold that began before a
    // pause still resolves (the Coordinator ignores a stray release anyway).

    fn tapPress(ctx: ?*anyopaque, key: tapmod.TalkKey, _: i64, _: u64) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (key != self.store.current().talk_key) return; // key filtering stays in the adapter
        if (self.paused.load(.acquire)) return; // menu-paused: ignore the Talk Key (#34)
        if (!self.capture_enabled.load(.acquire)) return;
        self.coordinator.handle(.press);
    }
    fn tapRelease(ctx: ?*anyopaque, key: tapmod.TalkKey) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (key != self.store.current().talk_key) return;
        self.coordinator.handle(.release);
    }

    /// Tap self-heal outcome (#18): a re-enable that didn't take means Input Monitoring was
    /// revoked; surface it. The tap recovers automatically once the grant returns. This is a
    /// tap-health event, not an Utterance event, so it does not go through the Coordinator.
    fn onTapDisabled(ctx: ?*anyopaque, by_timeout: bool, reenabled: bool) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (reenabled) {
            feedback.log("  Talk Key tap was disabled ({s}) and re-enabled\n", .{if (by_timeout) "OS timeout" else "user input"});
        } else {
            feedback.log("  Talk Key tap DISABLED and could not be re-enabled — Input Monitoring may be revoked; re-grant it to recover\n", .{});
            self.cues.err();
        }
    }

    /// A self-tagged synthetic event round-tripped the event stream into our tap: the
    /// PostEvent grant is provably live (#129). Runs on the run-loop thread; one store.
    fn onSelfEvent(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.post_event_observed.store(true, .release);
    }

    // ---- supervisor thread: the self-heal / not-configured → configured engine ----

    /// Input Monitoring fact. The preflight is stale in-process after a live grant
    /// (#127), so the live tap — brought up by the fresh-create re-arm — is the truth;
    /// the preflight only adds the created-but-momentarily-disabled window at startup.
    fn inputMonitoringFact(self: *Daemon) bool {
        return self.tap.isEnabled() or tapmod.Tap.listenGranted();
    }

    /// PostEvent fact: the observe latch (#129) ORed with the preflight, which is
    /// trustworthy when `true` but can lie `false` for the process lifetime.
    fn postEventFact(self: *Daemon) bool {
        return self.post_event_observed.load(.acquire) or insertmod.postEventGranted();
    }

    /// One facts pass: probe grants/key/installation, tick the Configuration Phase, and
    /// park the freshly loaded key (if any) for DaemonDeps.connectOpenai. Called by the
    /// Backend Router mid-tick (DaemonDeps.wants) and again after self-heal effects.
    fn gatherOutcome(self: *Daemon) configuration_phase.Outcome {
        const selected = self.transcription.selected();
        const local_installation = self.provisioner.installationPresent();
        const key = if (selected == .openai and !self.transcription.resourcePresent(.openai))
            config.loadApiKeyOnly(self.io, self.alloc)
        else
            null;
        self.router_deps.pending_key = key;
        const im = self.inputMonitoringFact();
        const pe = self.postEventFact();
        return self.configuration.tick(self.configurationFacts(im, pe, key != null, local_installation));
    }

    /// Gather this tick's Supervisor facts — the impure OS/router/grant reads the pure
    /// Supervisor decides on. Read at end-of-tick (after the grant sequence advanced and
    /// the Backend Router prepared) so backend/grant facts are current. ADR-0005 keeps
    /// this gathering in the daemon rather than behind a Supervisor seam.
    fn supervisorFacts(self: *Daemon) supervisor.Facts {
        return .{
            .tap_enabled = self.tap.isEnabled(),
            .grants_reached_post_event = self.grants.reached(.post_event),
            .post_event_granted = self.postEventFact(),
            .no_utterance_in_flight = self.transcription.activeId() == 0,
            .backend_available = self.transcription.available(),
            .paused = self.paused.load(.acquire),
        };
    }

    fn supervisorLoop(self: *Daemon) void {
        var first = true;
        while (!g_quit.load(.acquire)) {
            if (!first) sleepInterruptible(supervisor_tick_ms);
            first = false;
            if (g_quit.load(.acquire)) return;

            // #130's serialized cold-start requests + all [N/3] narration.
            self.tickGrantSequence();

            // The Backend Router reconciles (selection, staleness, drain-gated teardown),
            // gathers the Configuration Phase outcome via DaemonDeps.wants at the right
            // moment, then prepares. True = a resource became authoritative this tick.
            const changed_facts = self.transcription.tick(self.store.current().transcription_backend);
            var outcome = self.router_deps.outcome;

            // Re-evaluate after successful self-heal effects so READY/reporting reflects
            // the state users see at the end of this poll tick.
            if (changed_facts) outcome = self.gatherOutcome();

            // The Supervisor decides this tick's self-heal nudges + the capture-enable
            // gate; the daemon runs the effects here. The rearm/probe nudges are async —
            // scheduleRecreate posts to the tap's run-loop thread, postTaggedProbe posts a
            // synthetic event — so their outcomes land next tick regardless of where in
            // the tick they fire (#127/#129). See ADR-0005.
            const acts = supervisor.tick(self.supervisorFacts(), outcome);
            if (acts.rearm_tap) self.tap.scheduleRecreate();
            if (acts.post_probe) insertmod.postTaggedProbe();
            if (acts.announce_ready)
                feedback.log("  READY — hold {s}, speak, release; the transcript lands at the cursor.\n", .{keyName(self.store.current().talk_key)});
            if (acts.report_missing) |report| self.reportMissing(report);
            // Reclaim a superseded Model Installation only with no Utterance in flight;
            // busy operation/inference locks defer cleanup to the next tick without
            // disturbing dictation.
            if (acts.remove_superseded) self.provisioner.removeSuperseded();
            self.capture_enabled.store(acts.capture_enabled, .release);
        }
    }

    /// One tick of #130's serialized TCC request sequence: gather the three grant facts,
    /// let the pure policy decide, then fire the requests and print the [N/3] lines. The
    /// grant facts keep being polled here forever — a grant landing minutes after its
    /// step timed out still gets its granted line and its live pickup.
    fn tickGrantSequence(self: *Daemon) void {
        const facts = grant_sequence.Facts{
            cap.microphoneGranted(),
            self.inputMonitoringFact(),
            self.postEventFact(),
        };
        const actions = self.grants.tick(feedback.nowMs(), facts);
        if (actions.count > 0 and !self.grants_header_printed) {
            self.grants_header_printed = true;
            feedback.log("TCC grants for the type-wave daemon (requesting one at a time):\n", .{});
        }
        for (actions.slice()) |action| switch (action) {
            .request => |grant| {
                switch (grant) {
                    .microphone => cap.requestMicrophoneAccess(),
                    .input_monitoring => _ = tapmod.Tap.requestListenAccess(),
                    .post_event => _ = insertmod.requestPostEventAccess(),
                }
                feedback.log("  [{d}/3] {s}: requesting{s}\n", .{ stepNo(grant), grantName(grant), requestHint(grant) });
            },
            .granted => |grant| feedback.log("  [{d}/3] {s}: granted — {s}\n", .{ stepNo(grant), grantName(grant), grantedNote(grant) }),
            .timed_out => |grant| feedback.log("  [{d}/3] {s}: still waiting after 60s — moving on to the next grant; will keep polling in the background\n", .{ stepNo(grant), grantName(grant) }),
        };
    }

    fn stepNo(grant: grant_sequence.Grant) usize {
        return @intFromEnum(grant) + 1;
    }

    fn grantName(grant: grant_sequence.Grant) []const u8 {
        return switch (grant) {
            .microphone => "Microphone",
            .input_monitoring => "Input Monitoring",
            .post_event => "PostEvent (Accessibility)",
        };
    }

    fn requestHint(grant: grant_sequence.Grant) []const u8 {
        return switch (grant) {
            .microphone => "…",
            .input_monitoring => " — check System Settings > Privacy & Security > Input Monitoring",
            .post_event => " — check System Settings > Privacy & Security > Accessibility",
        };
    }

    fn grantedNote(grant: grant_sequence.Grant) []const u8 {
        return switch (grant) {
            .microphone => "Capture is live",
            .input_monitoring => "Talk Key tap is live",
            .post_event => "Insertion is live",
        };
    }

    /// Log the missing prerequisites once per distinct set (not every tick), with one error
    /// cue so a headless user hears that the daemon is waiting on them.
    fn reportMissing(self: *Daemon, report: readiness.Report) void {
        feedback.log("  not-configured — waiting on:\n", .{});
        for (report.slice()) |line| feedback.log("{s}\n", .{line});
        self.cues.err();
    }

    // ---- live-settings + menu-bar seams (wayfinder #32/#34) -----------------------

    /// session.ParamsProvider: invoked at EVERY connect attempt (session.zig), so a
    /// cycled session always speaks the freshest snapshot. Snapshot strings leak by
    /// design, so handing them to the Session is lifetime-safe.
    fn getParams(ctx: ?*anyopaque) session_mod.TranscriptionParams {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        const s = self.store.current();
        return .{
            .model = s.model,
            .language = s.language,
            .delay = s.delay,
            .noise_reduction = s.noiseReductionType(),
        };
    }

    fn configurationFacts(self: *Daemon, im: bool, pe: bool, key_present_now: bool, local_installation: bool) configuration_phase.Facts {
        const selected = self.transcription.selected();
        const resource_present = self.transcription.resourcePresent(selected);
        return .{
            .selected_backend = selected,
            .key_present = key_present_now or self.transcription.resourcePresent(.openai),
            .local_installation_present = local_installation,
            .microphone_granted = cap.microphoneGranted(),
            .backend_present = resource_present,
            .input_monitoring_granted = im,
            .post_event_granted = pe,
            .tap_enabled = self.tap.isEnabled(),
            .backend_ready = self.transcription.available(),
            .paused = self.paused.load(.acquire),
        };
    }

    // menu.Host callbacks — all run on the main thread (menu action / chrome pump).

    fn menuSelectBackend(ctx: *anyopaque, selected: backend.Backend) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.capture_enabled.store(false, .release);
        self.transcription.select(selected);
    }

    /// Health for the two-tier icon + status line, in the menu's priority order. The
    /// same signals the supervisor gates "configured" on, read non-destructively.
    fn menuStatus(ctx: *anyopaque) status_item.Snapshot {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const h = configuration_phase.health(self.configurationFacts(
            self.inputMonitoringFact(),
            self.postEventFact(),
            false,
            self.provisioner.installationPresent(),
        ));
        // Gathering glue: the model_store I/O and the recovery-phase -> Operation map that
        // stay in the daemon. The corrupt override and runner precedence are status_item's
        // pure `project` (Candidate 2 of the 2026-07-22 architecture review).
        var installation: status_item.Installation = .absent;
        var operation: status_item.Operation = .idle;
        var operation_bytes: ?status_item.ByteProgress = null;
        var installation_identity: ?status_item.InstallationIdentity = null;
        if (std.c.getenv("HOME")) |raw_home| {
            var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (model_store.rootPath(std.mem.span(raw_home), &root_buffer)) |root| {
                if (model_store.activeArtifact(self.io, root) catch null) |identity| {
                    _ = identity;
                    installation_identity = model_store.activeInstallationIdentity(self.io, root) catch null;
                    installation = if (model_store.updateAvailable(self.io, root, model_store.pinned_manifest) catch false)
                        .update_available
                    else
                        .ready;
                }
                const recovery = model_store.recoveryState(self.io, root, model_store.pinned_manifest) catch null;
                if (recovery) |state| {
                    if (state.phase == .downloading or state.phase == .paused)
                        operation_bytes = .{ .completed = state.bytes.completed, .total = state.bytes.total };
                    operation = switch (state.phase) {
                        .idle => .idle,
                        .downloading => .installing,
                        .paused => .paused,
                        .verifying => .verifying,
                        .smoke_testing => .smoke_testing,
                        .activating => .activating,
                        .removing => .removing,
                        .failed => .failed,
                    };
                }
            } else |_| {}
        }
        const recovery_state = self.provisioner.recoveryState();
        const observed: ?status_item.Observation = if (self.model_operation_runner.current()) |c| .{
            .active = c.active,
            .phase = c.phase,
            .bytes = c.bytes,
            .failure_detail = c.failure_detail,
        } else null;
        return status_item.project(.{
            .selected_backend = self.store.current().transcription_backend,
            .health = h,
            .terminal_backend_failure = self.store.current().transcription_backend == .local and recovery_state == .runtime_failure,
            .local_runtime_failure = recovery_state == .runtime_failure,
            .installation = installation,
            .recovery_is_corrupt = recovery_state == .corrupt,
            .operation = operation,
            .operation_bytes = operation_bytes,
            .installation_identity = installation_identity,
            .provisioner_failure_detail = self.provisioner.failureDetail(),
            .observed = observed,
        });
    }

    /// A session-shaped setting changed: nudge the Session to cycle when idle. Before
    /// the first connect there is nothing to mark — that connect reads the snapshot.
    fn menuMarkSessionDirty(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.transcription.settingsChanged();
    }

    /// The Overlay toggle (#32 decision 3): lazy-build on first enable — menu actions
    /// run exactly where the HUD must be built (main thread, so its render pump joins
    /// this run loop); init failure degrades to sound-only like startup. Disable keeps
    /// the built HUD and just stops showing it.
    fn menuSetOverlay(ctx: *anyopaque, on: bool) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (on and !self.hud.active) {
            if (self.hud.init())
                self.hud.startRenderPump()
            else
                feedback.log("  overlay HUD: enabled but no display detected — sound-only feedback\n", .{});
        }
        self.hud.setEnabled(on);
    }

    fn menuSetPaused(ctx: *anyopaque, paused: bool) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.paused.store(paused, .release);
    }

    /// Set API Key… → the login keychain. Same mechanism as `type-wave --set-key`
    /// (keychain.zig); the installed signed daemon creates the item itself, so its ACL
    /// keys to the daemon's Designated Requirement and later reads stay prompt-free.
    /// The supervisor's ~3 s poll then picks the key up — no restart.
    fn menuStoreApiKey(ctx: *anyopaque, key: []const u8) bool {
        _ = ctx;
        const st = keychain.storeKey(key);
        if (st == keychain.errSecSuccess) {
            feedback.log("  menu: API key stored in the login keychain (service \"{s}\")\n", .{keychain.service});
            return true;
        }
        var buf: [256]u8 = undefined;
        feedback.log("  menu: keychain store failed: {s}\n", .{keychain.describe(st, &buf)});
        return false;
    }

    /// Every Status Item Model Operation action, routed through the Runner. `retry_runtime`,
    /// `cancel_operation`, and `diagnostics` are handled here (they spawn no operation child);
    /// every launchable / retryable action goes to `startAction`, which resolves a retry to
    /// its original action, applies the one-at-a-time busy guard, and launches through the
    /// Deps seam.
    fn menuModelAction(ctx: *anyopaque, action: menu_mod.ModelAction) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        switch (action) {
            .retry_runtime => g_retry_local.store(true, .release),
            .cancel_operation => _ = self.model_operation_runner.requestCancel(),
            .diagnostics => {
                const raw_home = std.c.getenv("HOME") orelse return;
                var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buffer, "{s}/Library/Logs/type-wave.log", .{std.mem.span(raw_home)}) catch return;
                var child = std.process.spawn(self.io, .{ .argv = &.{ "/usr/bin/open", path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
                const waiter = std.Thread.spawn(.{}, waitForDetached, .{ self.io, child }) catch {
                    child.kill(self.io);
                    return;
                };
                waiter.detach();
            },
            else => self.model_operation_runner.startAction(action),
        }
    }

    fn waitForDetached(io: std.Io, child_value: std.process.Child) void {
        var child = child_value;
        _ = child.wait(io) catch {};
    }

    /// Menu Quit: signal every thread, then unwind [NSApp run] — daemon.run's normal
    /// graceful shutdown (supervisor join, websocket close drain) follows, and the
    /// process exits 0, which the LaunchAgent's KeepAlive (SuccessfulExit=false)
    /// treats as deliberate: it stays down until the next login/bootstrap.
    fn menuQuit(ctx: *anyopaque) void {
        _ = ctx;
        g_quit.store(true, .release);
        appkit.stop();
    }
};

/// Entry point: wire the modules + adapters + Coordinator, spawn the threads, and run the
/// tap's run loop until a quit signal. Never exits non-zero for a *recoverable* condition
/// (missing key/grants) — those are the supervisor's job — so the LaunchAgent never
/// crash-loops on them.
pub fn run(io: std.Io, alloc: std.mem.Allocator, process_environ: *const std.process.Environ.Map) !void {
    // Settings load always (defaults if absent); the secret is NOT required up front — the
    // supervisor waits for it (self-heal). The parsed Settings become the first immutable
    // snapshot in the Store (#32); every later change swaps in a fresh heap copy.
    const first_snapshot = try alloc.create(config.Settings);
    first_snapshot.* = config.loadSettingsOnly(io, alloc);
    const settings = first_snapshot.*;
    const selected_backend = settings.transcription_backend;
    std.debug.print("config: backend={s} talk_key={s} model=\"{s}\" language=\"{s}\" delay=\"{s}\" noise_reduction={s} insertion={s} pre_paste_ms={d} overlay={} backtrack={}\n", .{
        @tagName(selected_backend), @tagName(settings.talk_key), settings.model, settings.language, settings.delay, @tagName(settings.noise_reduction), @tagName(settings.insertion), settings.pre_paste_ms, settings.overlay, settings.backtrack,
    });

    var daemon = Daemon{
        .io = io,
        .alloc = alloc,
        .process_environ = process_environ,
        .store = config.Store.init(first_snapshot),
    };
    daemon.router_deps = .{ .daemon = &daemon };
    daemon.transcription = BackendRouter.init(io, &daemon.router_deps, selected_backend);
    daemon.model_operation_runner_deps = .{ .daemon = &daemon };
    daemon.model_operation_runner = ModelOperationRunner.init(&daemon.model_operation_runner_deps);
    daemon.provisioner_deps = .{ .daemon = &daemon };
    daemon.provisioner = LocalProvisioner.init(&daemon.provisioner_deps);

    // ---- modules that need neither a grant nor the key to construct ----
    try daemon.capture.init();
    defer daemon.capture.deinit();
    daemon.capture.ctx = &daemon;
    daemon.capture.on_chunk = Daemon.audioSink;
    daemon.capture.on_level = Daemon.levelSink;

    daemon.inserter.init();
    daemon.cues.init();

    // ---- overlay HUD (wayfinder #22): built on the main thread so its CFRunLoopTimer render
    //      pump joins the SAME run loop the tap will block on. Off by config, or headless
    //      with no display, both degrade to the sound cues without failing startup. ----
    if (settings.overlay) {
        if (daemon.hud.init()) {
            daemon.hud.startRenderPump();
            feedback.log("  overlay HUD: on — the waveform pill carries start/processing feedback; the error cue is kept\n", .{});
        } else {
            feedback.log("  overlay HUD: enabled but no display detected — sound-only feedback\n", .{});
        }
    } else {
        feedback.log("  overlay HUD: off (config.overlay=false) — sound-only feedback\n", .{});
    }

    // ---- wire the real adapters, then the Coordinator that drives them ----
    daemon.feedback_surface = .{ .cues = &daemon.cues, .hud = &daemon.hud };
    daemon.deadline.io = io;
    daemon.rewrite_http = .{ .allocator = alloc, .io = io };
    daemon.rewrite = RewriteAdapter.init(.{ .daemon = &daemon });
    daemon.insertion = InsertionAdapter.init(.{ .inserter = &daemon.inserter, .store = &daemon.store });
    daemon.coordinator = Coord.init(.{
        .audio = &daemon.capture,
        .backends = &daemon.transcription,
        .rewrite = &daemon.rewrite,
        .insertion = &daemon.insertion,
        .deadline = &daemon.deadline,
        .feedback = &daemon.feedback_surface,
    });
    // Reverse edges: the worker/timer threads re-enter the now-constructed Coordinator.
    daemon.insertion.deps.co_ctx = &daemon.coordinator;
    daemon.insertion.deps.on_done = insertDoneTramp;
    daemon.rewrite.deps.co_ctx = &daemon.coordinator;
    daemon.rewrite.deps.on_done = rewriteDoneTramp;
    daemon.deadline.co_ctx = &daemon.coordinator;
    daemon.deadline.on_cooperative_cancel = cooperativeCancelTramp;
    daemon.deadline.on_fire = deadlineFireTramp;

    // ---- Accessory activation policy, BEFORE any TCC preflight: Sequoia+ answers
    //      CGPreflightPostEventAccess()==false for a background-only process (#127).
    //      menu.init would set it as a side effect, but the ordering is load-bearing —
    //      make it explicit here so the headless path is covered by design (#129). ----
    _ = appkit.app();

    // ---- Talk Key tap: created on THIS (main) run loop. No TCC request fires here —
    //      the supervisor serializes them, one grant in flight at a time (#130). A
    //      created-while-denied tap stays disabled until the supervisor's fresh-create
    //      re-arm picks the grant up live (#127/#129); CGEventTapEnable can never revive
    //      it. Only a null port is a genuine hard failure. ----
    daemon.tap = .{ .cbs = .{
        .ctx = &daemon,
        .on_press = Daemon.tapPress,
        .on_release = Daemon.tapRelease,
        .on_disabled = Daemon.onTapDisabled,
        .on_self_event = Daemon.onSelfEvent,
    } };
    const tap_live = daemon.tap.install() catch |e| switch (e) {
        error.TapCreateFailed => {
            feedback.log("CGEventTapCreate returned NULL — cannot observe the Talk Key. Exiting.\n", .{});
            return e;
        },
    };
    feedback.log("Talk Key tap: {s}\n", .{if (tap_live) "live" else "created, waiting for Input Monitoring (the supervisor re-arms it once granted)"});

    // ---- menu-bar status item (#34): built on the main thread before the run loop.
    //      Headless (no display) skips it and the daemon behaves exactly as before. ----
    const menu_up = daemon.menu.init(io, alloc, &daemon.store, .{
        .ctx = &daemon,
        .status = Daemon.menuStatus,
        .selectBackend = Daemon.menuSelectBackend,
        .markSessionDirty = Daemon.menuMarkSessionDirty,
        .setOverlay = Daemon.menuSetOverlay,
        .setPaused = Daemon.menuSetPaused,
        .storeApiKey = Daemon.menuStoreApiKey,
        .modelAction = Daemon.menuModelAction,
        .quit = Daemon.menuQuit,
    });
    feedback.log("  menu bar: {s}\n", .{if (menu_up)
        "status item up"
    else
        "no display — running headless (no status item)"});

    // ---- threads ----
    const worker = try std.Thread.spawn(.{}, InsertionAdapter.workerLoop, .{&daemon.insertion});
    worker.detach();
    const rewrite_worker = try std.Thread.spawn(.{}, RewriteAdapter.workerLoop, .{&daemon.rewrite});
    rewrite_worker.detach();
    const timer = try std.Thread.spawn(.{}, DeadlineAdapter.timerLoop, .{&daemon.deadline});
    timer.detach();
    // The supervisor is JOINED at shutdown (below), so it can't race the session teardown.
    const supervisor_thread = try std.Thread.spawn(.{}, Daemon.supervisorLoop, .{&daemon});
    const local_retry = try std.Thread.spawn(.{}, Daemon.localRetryLoop, .{&daemon});

    _ = signal(SIGINT, onSignal);
    _ = signal(SIGTERM, onSignal);
    _ = signal(SIGHUP, onRetryLocal);
    const watcher = try std.Thread.spawn(.{}, quitWatcher, .{CFRunLoopGetMain()});
    watcher.detach();

    feedback.log("type-wave daemon up — self-healing. SIGTERM/Ctrl-C to quit; SIGHUP retries selected local inference.\n", .{});

    // The main loop. With the status item up this MUST be [NSApp run] — a bare
    // CFRunLoopRun never runs AppKit's nextEvent→sendEvent: dispatch, so status-item
    // clicks would never be routed (#31's load-bearing finding). It drives the same
    // main run loop: the tap's CFMachPort source and the HUD's render-pump timer keep
    // firing under it. Headless keeps the plain CFRunLoopRun.
    if (menu_up) appkit.run() else daemon.tap.run();
    g_quit.store(true, .release); // normally already set (menu Quit / signal) — belt-and-braces

    // Quit: g_quit is set (that's why run() returned). Join the supervisor first so it is not
    // mid-connect, then close the session gracefully (websocket close-frame drain, #17). We
    // deliberately do NOT deinit the session: the process is exiting, the OS reclaims its
    // memory, and skipping the free avoids any race with the detached worker/timer that may
    // still hold the pointer (same process-lifetime-singleton stance as config).
    feedback.log("shutting down…\n", .{});
    supervisor_thread.join();
    local_retry.join();
    daemon.transcription.shutdown();
    feedback.log("bye.\n", .{});
}
