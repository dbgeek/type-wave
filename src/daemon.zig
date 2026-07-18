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
//!    `exit(0)` for a clean SIGTERM/bootout.
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
const readiness = @import("readiness.zig");
const configuration_phase = @import("configuration_phase.zig");
const backend = @import("transcription_backend.zig");
const backend_router = @import("backend_router.zig");
const operation_channel = @import("operation_channel.zig");
const local_backend = @import("local_backend.zig");
const model_store = @import("model_store.zig");
const local_model_recovery = @import("local_model_recovery.zig");
const status_item = @import("status_item.zig");
const failure_observation = @import("failure_observation.zig");

const FailureObservation = failure_observation.FailureObservation;

const Session = session_mod.Session;
const LocalAdapter = local_backend.Adapter(local_backend.ProcessHelper);

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

const ModelOperationObservation = struct {
    pid: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(status_item.Operation.idle)),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    retry_action: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(menu_mod.ModelAction.install)),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    typed_failure: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failure: FailureObservation = .{},

    const Current = struct { phase: status_item.Operation, bytes: ?status_item.ByteProgress, active: bool, failure_detail: ?status_item.FailureDetail };

    fn current(self: *ModelOperationObservation) ?Current {
        const active = self.pid.load(.acquire) != 0;
        const phase = std.enums.fromInt(status_item.Operation, self.phase.load(.acquire)) orelse .installing;
        if (!active and phase != .failed and phase != .cancelled) return null;
        const total = self.total.load(.acquire);
        return .{
            .phase = phase,
            .bytes = if (!phase.reportsByteProgress() or total == 0) null else .{ .completed = self.completed.load(.acquire), .total = total },
            .active = active,
            .failure_detail = self.failure.current(),
        };
    }

    fn begin(self: *ModelOperationObservation, pid: c_int, phase: status_item.Operation, action: menu_mod.ModelAction) void {
        self.phase.store(@intFromEnum(phase), .release);
        self.retry_action.store(@intFromEnum(action), .release);
        self.cancel_requested.store(false, .release);
        self.completed.store(0, .release);
        self.total.store(0, .release);
        self.typed_failure.store(false, .release);
        self.failure.clear();
        self.pid.store(pid, .release);
    }

    /// A decoded typed event from the child's stdout channel — the only source of
    /// phase and byte progress. Stderr prose is log and failure fallback, never
    /// mined for numbers.
    fn apply(self: *ModelOperationObservation, event: operation_channel.Event) void {
        switch (event) {
            .operation => |op| switch (op) {
                .downloading => |bytes| self.setProgress(bytes.completed, bytes.total),
                // A retry carries its own byte position — attempt/budget never
                // masquerades as progress (the old prose mining's latent bug).
                .retrying => |retry| self.setProgress(retry.bytes.completed, retry.bytes.total),
                .verifying => |bytes| {
                    self.setPhase(.verifying);
                    self.setProgress(bytes.completed, bytes.total);
                },
                .smoke_testing => self.setPhase(.smoke_testing),
                .waiting_for_inference => self.setPhase(.waiting_for_inference),
                .activating => self.setPhase(.activating),
                .removing => self.setPhase(.removing),
            },
            .failed => |name| {
                self.typed_failure.store(true, .release);
                self.failure.set(name);
            },
        }
    }

    /// Stderr fallback for deaths that never emit a typed `failed` event (a panic,
    /// OOM): retain the last non-progress line. A typed failure is authoritative.
    fn observeFailure(self: *ModelOperationObservation, line: []const u8) void {
        if (std.mem.indexOf(u8, line, "Model Operation:") != null) return;
        if (self.typed_failure.load(.acquire)) return;
        self.failure.set(line);
    }

    fn finish(self: *ModelOperationObservation, succeeded: bool) void {
        self.phase.store(@intFromEnum(if (succeeded)
            status_item.Operation.idle
        else if (self.cancel_requested.load(.acquire))
            status_item.Operation.cancelled
        else
            status_item.Operation.failed), .release);
        self.completed.store(0, .release);
        self.total.store(0, .release);
        self.pid.store(0, .release);
    }

    fn setPhase(self: *ModelOperationObservation, phase: status_item.Operation) void {
        self.phase.store(@intFromEnum(phase), .release);
        if (phase != .installing and phase != .updating and phase != .verifying) {
            self.completed.store(0, .release);
            self.total.store(0, .release);
        }
    }

    fn setProgress(self: *ModelOperationObservation, completed: u64, total: u64) void {
        self.completed.store(completed, .release);
        self.total.store(total, .release);
    }

    fn requestCancel(self: *ModelOperationObservation) ?c_int {
        const phase = std.enums.fromInt(status_item.Operation, self.phase.load(.acquire)) orelse return null;
        if (!phase.isCancellable()) return null;
        const pid = self.pid.load(.acquire);
        if (pid == 0) return null;
        self.cancel_requested.store(true, .release);
        return pid;
    }

    fn retryAction(self: *const ModelOperationObservation) ?menu_mod.ModelAction {
        const phase = std.enums.fromInt(status_item.Operation, self.phase.load(.acquire)) orelse return null;
        if (phase != .failed and phase != .cancelled) return null;
        return std.enums.fromInt(menu_mod.ModelAction, self.retry_action.load(.acquire));
    }
};
var g_model_operation: ModelOperationObservation = .{};

test "Model Operation observation retains the actionable terminal failure" {
    var observation = ModelOperationObservation{};
    observation.begin(42, .installing, .install);
    observation.observeFailure("--install-model: ModelDownloadRejected");
    observation.finish(false);

    const current = observation.current().?;
    try std.testing.expectEqual(status_item.Operation.failed, current.phase);
    try std.testing.expectEqualStrings("--install-model: ModelDownloadRejected", current.failure_detail.?.value());
}

test "typed channel events drive phase and bytes; a retry never corrupts progress" {
    var observation = ModelOperationObservation{};
    observation.begin(42, .installing, .install);

    observation.apply(.{ .operation = .{ .downloading = .{ .completed = 100, .total = 1_000 } } });
    var current = observation.current().?;
    try std.testing.expectEqual(status_item.Operation.installing, current.phase);
    try std.testing.expectEqualDeep(status_item.ByteProgress{ .completed = 100, .total = 1_000 }, current.bytes.?);

    // The prose mining this replaced read "retry 2/5" as 2/5 bytes.
    observation.apply(.{ .operation = .{ .retrying = .{ .attempt = 2, .budget = 5, .delay_ms = 4_000, .bytes = .{ .completed = 100, .total = 1_000 } } } });
    current = observation.current().?;
    try std.testing.expectEqualDeep(status_item.ByteProgress{ .completed = 100, .total = 1_000 }, current.bytes.?);

    observation.apply(.{ .operation = .{ .verifying = .{ .completed = 1_000, .total = 1_000 } } });
    try std.testing.expectEqual(status_item.Operation.verifying, observation.current().?.phase);
}

test "a typed failure is authoritative over trailing stderr prose" {
    var observation = ModelOperationObservation{};
    observation.begin(42, .installing, .install);
    observation.apply(.{ .failed = "ModelDownloadRejected" });
    observation.observeFailure("--install-model: ModelDownloadRejected"); // prose may still trail in
    observation.finish(false);

    const current = observation.current().?;
    try std.testing.expectEqual(status_item.Operation.failed, current.phase);
    try std.testing.expectEqualStrings("ModelDownloadRejected", current.failure_detail.?.value());
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
    /// loop executes its non-router actions (tap enable, READY, reporting) afterwards.
    outcome: configuration_phase.Outcome = undefined,

    pub fn connectOpenai(self: *DaemonDeps) !*Session {
        const d = self.daemon;
        const key = self.pending_key orelse return error.MissingApiKey;
        return Session.connect(d.io, d.alloc, key, .{ .ctx = d, .get = Daemon.getParams }, d.observer());
    }

    pub fn prepareLocal(self: *DaemonDeps) ?*LocalAdapter {
        return self.daemon.prepareLocalHelper();
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

/// Deadline seam: a small timer thread. `arm` (Coordinator releasing an Utterance) sets
/// the backend's cooperative and final fire times; `cancel` (Final Transcript) clears both.
/// Claimed actions re-enter the Coordinator, whose identity/phase guard rejects stale races.
const DeadlineAdapter = struct {
    io: std.Io = undefined,
    mu: std.Io.Mutex = .init,
    state: backend.DeadlineState = .{},

    co_ctx: *anyopaque = undefined,
    on_cooperative_cancel: *const fn (*anyopaque, backend.UtteranceId) void = undefined,
    on_fire: *const fn (*anyopaque, backend.UtteranceId) void = undefined,

    pub fn arm(self: *DeadlineAdapter, id: backend.UtteranceId, policy: backend.DeadlinePolicy) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.state.arm(id, session_mod.nowMs(), policy);
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
                .final => |id| self.on_fire(self.co_ctx, id),
            };
            _ = usleep(1_000);
        }
    }
};

// The Coordinator's dependency set, wired to the real adapters above.
const RealDeps = struct {
    audio: *cap.Capture,
    backends: *BackendRouter,
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
fn deadlineFireTramp(ctx: *anyopaque, id: backend.UtteranceId) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.{ .deadline = id });
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
    insertion: InsertionAdapter = undefined,
    deadline: DeadlineAdapter = .{},
    feedback_surface: surface.Surface = undefined,
    coordinator: Coord = undefined,

    /// Supervisor-thread-only: owns Configuration Phase memory, including READY
    /// announcements and distinct not-configured reports.
    configuration: configuration_phase.ConfigurationPhase = .{},
    local_model_recovery: local_model_recovery.Recovery = .{},
    local_failure: FailureObservation = .{},

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

    fn localModelPath(io: std.Io, buf: []u8) ?[]const u8 {
        const raw_home = std.c.getenv("HOME") orelse {
            return null;
        };
        const home = std.mem.span(raw_home);
        var root_buf: [4096]u8 = undefined;
        const root = model_store.rootPath(home, &root_buf) catch return null;
        return model_store.activeModelPath(io, root, buf) catch null;
    }

    fn localInstallationPresent(self: *Daemon) bool {
        const raw_home = std.c.getenv("HOME") orelse return false;
        var root_buf: [4096]u8 = undefined;
        const root = model_store.rootPath(std.mem.span(raw_home), &root_buf) catch return false;
        if (model_store.modelRemovalPending(self.io, root)) return false;
        var model_buf: [4096]u8 = undefined;
        return self.local_model_recovery.installationUsable() and localModelPath(self.io, &model_buf) != null;
    }

    fn removeInactiveModelInstallations(self: *Daemon) void {
        const raw_home = std.c.getenv("HOME") orelse return;
        var root_buf: [4096]u8 = undefined;
        const root = model_store.rootPath(std.mem.span(raw_home), &root_buf) catch return;
        const removed = model_store.removeInactiveInstallations(self.io, root) catch |failure| {
            if (failure == error.ModelOperationInProgress or failure == error.ModelInferenceActive) return;
            feedback.log("  superseded Model Installation cleanup failed: {s}; retrying while idle\n", .{@errorName(failure)});
            return;
        };
        if (removed > 0) feedback.log("  removed {d} superseded Model Installation(s) after helper drain\n", .{removed});
    }

    fn prepareLocalHelper(self: *Daemon) ?*LocalAdapter {
        const raw_home = std.c.getenv("HOME") orelse return null;
        const home = std.mem.span(raw_home);
        var helper_buf: [4096]u8 = undefined;
        var model_buf: [4096]u8 = undefined;
        var root_buf: [4096]u8 = undefined;
        const helper_path = std.fmt.bufPrint(&helper_buf, "{s}/.local/libexec/type-wave/type-wave-whisper", .{home}) catch return null;
        const root = model_store.rootPath(home, &root_buf) catch return null;
        var runtime_lease = model_store.RuntimeLease.acquire(self.io, root) catch return null;
        defer runtime_lease.release();
        const model_path = localModelPath(self.io, &model_buf) orelse return null;
        const active_artifact = (model_store.activeArtifact(self.io, root) catch return null) orelse return null;
        if (self.local_model_recovery.current() == .verifying) {
            const usable = self.verifyLocalInstallation(root) orelse return null;
            if (self.local_model_recovery.verificationFinished(usable) != .load) return null;
        }
        if (self.local_model_recovery.current() == .corrupt or self.local_model_recovery.current() == .runtime_failure) return null;

        const helper = local_backend.ProcessHelper.start(self.alloc, self.io, helper_path, model_path, .{
            .size = active_artifact.size,
            .sha256 = active_artifact.sha256,
        }) catch |failure| retry: {
            if (self.local_model_recovery.loadFailed() != .verify) {
                self.local_failure.setError("Local runtime load failed", failure);
                feedback.log("  local Whisper runtime failure after verified installation: {s}; send SIGHUP to Retry\n", .{@errorName(failure)});
                return null;
            }
            feedback.log("  local Whisper load failed: {s}; verifying the Model Installation offline\n", .{@errorName(failure)});
            const usable = self.verifyLocalInstallation(root) orelse return null;
            if (self.local_model_recovery.verificationFinished(usable) != .load) return null;
            break :retry local_backend.ProcessHelper.start(self.alloc, self.io, helper_path, model_path, .{
                .size = active_artifact.size,
                .sha256 = active_artifact.sha256,
            }) catch |retry_failure| {
                _ = self.local_model_recovery.loadFailed();
                self.local_failure.setError("Local runtime load failed", retry_failure);
                feedback.log("  Model Installation verified, but local runtime load failed again: {s}; send SIGHUP to Retry\n", .{@errorName(retry_failure)});
                return null;
            };
        };
        self.local_model_recovery.loadSucceeded();
        self.local_failure.clear();
        const local = self.alloc.create(LocalAdapter) catch {
            helper.shutdown();
            feedback.log("  local Whisper unavailable: adapter allocation failed\n", .{});
            return null;
        };
        local.* = LocalAdapter.init(self.alloc, self.io, helper, .{
            .ctx = self,
            .final = Daemon.localFinal,
            .failed = Daemon.localFailed,
        });
        local.setInferenceRoot(root, &runtime_lease) catch {
            helper.shutdown();
            self.alloc.destroy(local);
            return null;
        };
        local.bindHelperEvents();
        return local;
    }

    fn verifyLocalInstallation(self: *Daemon, root: []const u8) ?bool {
        const cancel = model_store.CancelToken{};
        const integrity = model_store.verifyActiveInstallation(self.io, root, model_store.pinned_manifest, &model_store.trusted_manifests, &cancel, null) catch |failure| {
            self.local_model_recovery.verificationFailed();
            self.local_failure.setError("Model Installation verification failed", failure);
            feedback.log("  local Model Installation verification failed: {s}; runtime Retry remains available\n", .{@errorName(failure)});
            return null;
        };
        return switch (integrity) {
            .usable => true,
            .absent => {
                feedback.log("  local Model Installation is absent; Install is required\n", .{});
                return false;
            },
            .corrupt => |reason| {
                var buffer: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buffer, "Model Installation corrupt: {s}", .{@tagName(reason)})) |detail|
                    self.local_failure.set(detail)
                else |_| {}
                feedback.log("  local Model Installation is corrupt ({s}); Repair or Remove is required\n", .{@tagName(reason)});
                return false;
            },
        };
    }

    fn localRetryLoop(self: *Daemon) void {
        while (!g_quit.load(.acquire)) {
            if (g_retry_local.swap(false, .acq_rel) and self.transcription.selected() == .local) {
                if (self.transcription.retryLocal()) {
                    feedback.log("  local Whisper Retry requested\n", .{});
                } else if (self.local_model_recovery.retry() != .none) {
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

    // ---- supervisor thread: the self-heal / not-configured → configured engine ----

    /// One facts pass: probe grants/key/installation, tick the Configuration Phase, and
    /// park the freshly loaded key (if any) for DaemonDeps.connectOpenai. Called by the
    /// Backend Router mid-tick (DaemonDeps.wants) and again after self-heal effects.
    fn gatherOutcome(self: *Daemon) configuration_phase.Outcome {
        const selected = self.transcription.selected();
        const local_installation = self.localInstallationPresent();
        const key = if (selected == .openai and !self.transcription.resourcePresent(.openai))
            config.loadApiKeyOnly(self.io, self.alloc)
        else
            null;
        self.router_deps.pending_key = key;
        const im = tapmod.Tap.listenGranted();
        const pe = insertmod.postEventGranted();
        return self.configuration.tick(self.configurationFacts(im, pe, key != null, local_installation));
    }

    fn supervisorLoop(self: *Daemon) void {
        var first = true;
        while (!g_quit.load(.acquire)) {
            if (!first) sleepInterruptible(supervisor_tick_ms);
            first = false;
            if (g_quit.load(.acquire)) return;

            // The Backend Router reconciles (selection, staleness, drain-gated teardown),
            // gathers the Configuration Phase outcome via DaemonDeps.wants at the right
            // moment, then prepares. True = a resource became authoritative this tick.
            var changed_facts = self.transcription.tick(self.store.current().transcription_backend);
            var outcome = self.router_deps.outcome;

            if (outcome.actions.enable_tap) {
                if (self.tap.enable()) {
                    changed_facts = true;
                    feedback.log("  supervisor: Input Monitoring granted — Talk Key tap is live\n", .{});
                } else {
                    feedback.log("  supervisor: Input Monitoring looks granted but the tap won't enable — a daemon restart may be needed\n", .{});
                }
            }

            // Re-evaluate after successful self-heal effects so READY/reporting reflects
            // the state users see at the end of this poll tick.
            if (changed_facts) outcome = self.gatherOutcome();

            if (outcome.actions.announce_ready)
                feedback.log("  READY — hold {s}, speak, release; the transcript lands at the cursor.\n", .{keyName(self.store.current().talk_key)});
            if (outcome.actions.report_missing) |report| self.reportMissing(report);
            // Cheap nonblocking reconciliation also catches updates activated while OpenAI
            // is selected and no local helper exists. Busy operation/inference locks defer
            // cleanup to the next supervisor tick without disturbing dictation.
            if (self.transcription.activeId() == 0)
                self.removeInactiveModelInstallations();
            self.capture_enabled.store(outcome.configured and self.transcription.available() and !self.paused.load(.acquire), .release);
        }
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
            tapmod.Tap.listenGranted(),
            insertmod.postEventGranted(),
            false,
            self.localInstallationPresent(),
        ));
        var installation: status_item.Installation = .absent;
        var operation: status_item.Operation = .idle;
        var operation_bytes: ?status_item.ByteProgress = null;
        var installation_identity: ?status_item.InstallationIdentity = null;
        var failure_detail = self.local_failure.current();
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
        const recovery_state = self.local_model_recovery.current();
        if (recovery_state == .corrupt) installation = .corrupt;
        if (g_model_operation.current()) |observed| {
            if (observed.active or operation != .paused) {
                operation = observed.phase;
                operation_bytes = observed.bytes;
            }
            failure_detail = observed.failure_detail;
        }
        return .{
            .selected_backend = self.store.current().transcription_backend,
            .health = h,
            .terminal_backend_failure = self.store.current().transcription_backend == .local and recovery_state == .runtime_failure,
            .local_runtime_failure = recovery_state == .runtime_failure,
            .installation = installation,
            .operation = operation,
            .operation_bytes = operation_bytes,
            .installation_identity = installation_identity,
            .failure_detail = failure_detail,
        };
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

    fn menuModelAction(ctx: *anyopaque, action: menu_mod.ModelAction) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        switch (action) {
            .retry_runtime => {
                g_retry_local.store(true, .release);
                return;
            },
            .cancel_operation => {
                if (g_model_operation.requestCancel()) |pid| _ = kill(pid, SIGTERM);
                return;
            },
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
                return;
            },
            else => {},
        }
        const effective_action = if (action == .retry_operation)
            g_model_operation.retryAction() orelse return
        else
            action;
        if (g_model_operation.pid.load(.acquire) != 0) return;
        const argument: []const u8 = switch (effective_action) {
            .install => "--install-model",
            .update => "--update-model",
            .resume_operation => "--resume-model",
            .discard => "--discard-model",
            .verify => "--verify-model",
            .repair => "--repair-model",
            .remove => "--remove-model",
            .retry_runtime, .retry_operation, .cancel_operation, .diagnostics => unreachable,
        };
        var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var executable_size: u32 = executable_buffer.len;
        if (_NSGetExecutablePath(&executable_buffer, &executable_size) != 0) return;
        const executable = std.mem.sliceTo(executable_buffer[0..executable_size], 0);
        const confirmation: ?[]const u8 = switch (effective_action) {
            .repair => "yes\n",
            .remove => "remove\n",
            else => null,
        };
        var child = std.process.spawn(self.io, .{
            .argv = &.{ executable, argument },
            .environ_map = self.process_environ,
            .stdin = if (confirmation != null) .pipe else .ignore,
            .stdout = .pipe, // the typed Model Operation channel (operation_channel.zig)
            .stderr = .pipe, // human prose: daemon log + failure fallback
        }) catch |failure| {
            feedback.log("  menu: could not start Model Operation: {s}\n", .{@errorName(failure)});
            return;
        };
        if (confirmation) |answer| {
            child.stdin.?.writeStreamingAll(self.io, answer) catch {
                child.kill(self.io);
                return;
            };
            child.stdin.?.close(self.io);
            child.stdin = null;
        }
        const pid: c_int = @intCast(child.id.?);
        g_model_operation.begin(pid, switch (effective_action) {
            .update => status_item.Operation.updating,
            .verify => .verifying,
            .remove => .removing,
            .discard => .discarding,
            else => .installing,
        }, effective_action);
        const waiter = std.Thread.spawn(.{}, waitForModelAction, .{ self.io, child, effective_action }) catch {
            child.kill(self.io);
            g_model_operation.finish(false);
            return;
        };
        waiter.detach();
    }

    fn waitForModelAction(io: std.Io, child_value: std.process.Child, action: menu_mod.ModelAction) void {
        var child = child_value;
        const channel_thread: ?std.Thread = std.Thread.spawn(.{}, observeOperationChannel, .{ io, child.stdout.? }) catch null;
        if (channel_thread == null)
            feedback.log("  menu: Model Operation channel reader unavailable — progress will not update\n", .{});
        var read_buffer: [2048]u8 = undefined;
        var stderr_reader = child.stderr.?.readerStreaming(io, &read_buffer);
        while (stderr_reader.interface.takeDelimiter('\n') catch null) |line| {
            g_model_operation.observeFailure(line);
            feedback.log("  model: {s}\n", .{line});
        }
        if (channel_thread) |thread| thread.join(); // both pipes hit EOF at child exit
        const term = child.wait(io) catch {
            g_model_operation.finish(false);
            return;
        };
        g_model_operation.finish(term.success());
        feedback.log("  menu: Model Operation {s} {s}\n", .{ @tagName(action), if (term.success()) "finished" else "failed" });
    }

    /// Drain the child's stdout channel: decoded events drive the observation;
    /// anything undecodable on this stream is silently skipped.
    fn observeOperationChannel(io: std.Io, stdout_value: std.Io.File) void {
        var stdout = stdout_value;
        var read_buffer: [2048]u8 = undefined;
        var reader = stdout.readerStreaming(io, &read_buffer);
        while (reader.interface.takeDelimiter('\n') catch null) |line| {
            if (operation_channel.decode(line)) |event| g_model_operation.apply(event);
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
    std.debug.print("config: backend={s} talk_key={s} model=\"{s}\" language=\"{s}\" delay=\"{s}\" noise_reduction={s} insertion={s} pre_paste_ms={d} overlay={}\n", .{
        @tagName(selected_backend), @tagName(settings.talk_key), settings.model, settings.language, settings.delay, @tagName(settings.noise_reduction), @tagName(settings.insertion), settings.pre_paste_ms, settings.overlay,
    });

    var daemon = Daemon{
        .io = io,
        .alloc = alloc,
        .process_environ = process_environ,
        .store = config.Store.init(first_snapshot),
    };
    daemon.router_deps = .{ .daemon = &daemon };
    daemon.transcription = BackendRouter.init(io, &daemon.router_deps, selected_backend);

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
    daemon.insertion = InsertionAdapter.init(.{ .inserter = &daemon.inserter, .store = &daemon.store });
    daemon.coordinator = Coord.init(.{
        .audio = &daemon.capture,
        .backends = &daemon.transcription,
        .insertion = &daemon.insertion,
        .deadline = &daemon.deadline,
        .feedback = &daemon.feedback_surface,
    });
    // Reverse edges: the worker/timer threads re-enter the now-constructed Coordinator.
    daemon.insertion.deps.co_ctx = &daemon.coordinator;
    daemon.insertion.deps.on_done = insertDoneTramp;
    daemon.deadline.co_ctx = &daemon.coordinator;
    daemon.deadline.on_cooperative_cancel = cooperativeCancelTramp;
    daemon.deadline.on_fire = deadlineFireTramp;

    // ---- Talk Key tap: prompt for the two event grants once, then create the tap on THIS
    //      (main) run loop. A created-but-disabled tap is fine — the supervisor enables it
    //      once Input Monitoring appears. Only a null port is a genuine hard failure. ----
    const listen_ok = tapmod.Tap.requestListenAccess();
    const post_ok = insertmod.requestPostEventAccess();
    cap.requestMicrophoneAccess();
    const microphone_ok = cap.microphoneGranted();
    feedback.log("TCC grants for the type-wave daemon:\n", .{});
    feedback.log("  Input Monitoring (Talk Key tap): {s}\n", .{if (listen_ok) "granted" else "NOT granted — waiting"});
    feedback.log("  PostEvent        (Insertion):    {s}\n", .{if (post_ok) "granted" else "NOT granted — waiting"});
    feedback.log("  Microphone       (Capture):      {s}\n", .{if (microphone_ok) "granted" else "NOT granted — enable in System Settings"});

    daemon.tap = .{ .cbs = .{
        .ctx = &daemon,
        .on_press = Daemon.tapPress,
        .on_release = Daemon.tapRelease,
        .on_disabled = Daemon.onTapDisabled,
    } };
    const tap_live = daemon.tap.install() catch |e| switch (e) {
        error.TapCreateFailed => {
            feedback.log("CGEventTapCreate returned NULL — cannot observe the Talk Key. Exiting.\n", .{});
            return e;
        },
    };
    feedback.log("  Talk Key tap: {s}\n", .{if (tap_live) "live" else "created, waiting for Input Monitoring"});

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
    const timer = try std.Thread.spawn(.{}, DeadlineAdapter.timerLoop, .{&daemon.deadline});
    timer.detach();
    // The supervisor is JOINED at shutdown (below), so it can't race the session teardown.
    const supervisor = try std.Thread.spawn(.{}, Daemon.supervisorLoop, .{&daemon});
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
    supervisor.join();
    local_retry.join();
    daemon.transcription.shutdown();
    feedback.log("bye.\n", .{});
}
