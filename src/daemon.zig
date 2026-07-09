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
//! # Two orthogonal state machines still owned here
//!
//! 1. **Configuration phase** (this file, the self-heal supervisor): `not-configured` ⇄
//!    `configured`. The gate is (API key present) AND (Input Monitoring granted) AND
//!    (PostEvent granted). Missing prerequisites do NOT crash the daemon (the LaunchAgent's
//!    KeepAlive would crash-loop); the supervisor polls (~3 s), builds the Transcription
//!    Session the moment a key appears, and brings the created-but-disabled tap live the
//!    moment Input Monitoring appears. `exit(0)` is reserved for a clean SIGTERM/bootout.
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

const Session = session_mod.Session;

extern "c" fn usleep(usec: c_uint) c_int;

const CFRunLoopRef = ?*anyopaque;
extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
extern "c" fn CFRunLoopStop(rl: CFRunLoopRef) void;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) callconv(.c) usize;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;

// ---- tuning ----------------------------------------------------------------
/// Self-heal poll cadence. Fast enough that granting a permission / dropping in the key
/// feels responsive, slow enough to be invisible in the log while waiting.
const supervisor_tick_ms: usize = 3_000;
/// Release-anchored Insertion deadline (grilled for #19): armed when the Coordinator enters
/// `awaiting_final`, so it bounds both the live wait and a reconnect-spanning wait. Past it
/// the Utterance is dropped rather than inserting stale text or blocking new Utterances.
const insert_deadline_ms: i64 = 15_000;

/// Raised by the SIGINT/SIGTERM handler (async-signal-safe store only); the quit watcher
/// polls it and stops the run loop, and the supervisor + adapter threads poll it to end.
var g_quit = std.atomic.Value(bool).init(false);

fn onSignal(_: c_int) callconv(.c) void {
    g_quit.store(true, .release);
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

/// Transcription seam: owns "the current warm Transcription Session" as a plain atomic
/// pointer (0 = not created yet), hiding that indirection behind named methods. The
/// supervisor `set`s it once the API key appears; the pointer never reverts to 0 for the
/// process lifetime (reconnects reuse the same Session), so `available()` latches true.
const TranscriptionAdapter = struct {
    ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn set(self: *TranscriptionAdapter, sess: *Session) void {
        self.ptr.store(@intFromPtr(sess), .release);
    }
    fn current(self: *TranscriptionAdapter) ?*Session {
        const p = self.ptr.load(.acquire);
        return if (p == 0) null else @ptrFromInt(p);
    }
    // ---- the Coordinator's seam (pub: called cross-file from the generic Coordinator) ----
    pub fn available(self: *TranscriptionAdapter) bool {
        return self.ptr.load(.acquire) != 0;
    }
    pub fn beginUtterance(self: *TranscriptionAdapter) void {
        if (self.current()) |s| s.beginUtterance();
    }
    pub fn endUtterance(self: *TranscriptionAdapter) void {
        if (self.current()) |s| s.endUtterance();
    }
    pub fn commitUtterance(self: *TranscriptionAdapter) !bool {
        if (self.current()) |s| return s.commitUtterance();
        return false;
    }
    pub fn isPoisoned(self: *TranscriptionAdapter) bool {
        if (self.current()) |s| return s.isPoisoned();
        return false;
    }
    // ---- used by the audio sink (Capture → current Session), not the Coordinator ----
    fn appendAudio(self: *TranscriptionAdapter, pcm: []const u8) void {
        if (self.current()) |s| s.appendAudio(pcm);
    }
};

/// Real dependencies for insertion_adapter.zig. The adapter owns the asynchronous
/// Insertion policy; daemon.zig supplies the concrete macOS mechanism, Settings Snapshot,
/// process quit flag, and reverse edge into the Coordinator.
const RealInsertionDeps = struct {
    inserter: *insertmod.Inserter,
    store: *config.Store,

    co_ctx: *anyopaque = undefined,
    on_done: *const fn (*anyopaque, coord.InsertResult) void = undefined,

    pub fn insertionMethod(self: *RealInsertionDeps) insertmod.Method {
        return self.store.current().insertion;
    }
    pub fn insert(self: *RealInsertionDeps, method: insertmod.Method, text: [*:0]const u8) insertmod.InsertError!void {
        return self.inserter.insert(method, text);
    }
    pub fn complete(self: *RealInsertionDeps, result: coord.InsertResult) void {
        self.on_done(self.co_ctx, result);
    }
    pub fn shouldQuit(_: *RealInsertionDeps) bool {
        return g_quit.load(.acquire);
    }
    pub fn idle(_: *RealInsertionDeps) void {
        _ = usleep(2_000);
    }
};
const InsertionAdapter = insertion_adapter.InsertionAdapter(RealInsertionDeps);

/// Deadline seam: a small timer thread. `arm` (Coordinator entering `awaiting_final`) sets
/// a fire time; `cancel` (final arrived) clears it. The loop fires `.deadline` once if the
/// window elapses while still armed — the cmpxchg makes a cancel/arm race lose cleanly, and
/// the Coordinator ignores a stale `.deadline` anyway (phase guard).
const DeadlineAdapter = struct {
    fire_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0), // 0 = disarmed

    co_ctx: *anyopaque = undefined,
    on_fire: *const fn (*anyopaque) void = undefined,

    pub fn arm(self: *DeadlineAdapter) void {
        self.fire_at.store(session_mod.nowMs() + insert_deadline_ms, .release);
    }
    pub fn cancel(self: *DeadlineAdapter) void {
        self.fire_at.store(0, .release);
    }
    fn timerLoop(self: *DeadlineAdapter) void {
        while (!g_quit.load(.acquire)) {
            const at = self.fire_at.load(.acquire);
            if (at != 0 and session_mod.nowMs() >= at) {
                if (self.fire_at.cmpxchgStrong(at, 0, .acq_rel, .monotonic) == null)
                    self.on_fire(self.co_ctx);
            }
            _ = usleep(50_000);
        }
    }
};

// The Coordinator's dependency set, wired to the real adapters above.
const RealDeps = struct {
    audio: *cap.Capture,
    transcription: *TranscriptionAdapter,
    insertion: *InsertionAdapter,
    deadline: *DeadlineAdapter,
    feedback: *surface.Surface,
};
const Coord = coord.Coordinator(RealDeps);

// Reverse-edge trampolines: the adapters' worker/timer threads carry the Coordinator as an
// opaque pointer and re-enter it here (its concrete type is known at this wiring site).
fn insertDoneTramp(ctx: *anyopaque, result: coord.InsertResult) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.{ .inserted = result });
}
fn deadlineFireTramp(ctx: *anyopaque) void {
    const co: *Coord = @ptrCast(@alignCast(ctx));
    co.handle(.deadline);
}

/// The whole daemon: the long-lived modules, the real adapters, and the Coordinator they
/// feed. A single instance lives on `run`'s stack for the process lifetime; its address is
/// handed to every thread and to the tap as its callback context, so it must not move.
const Daemon = struct {
    io: std.Io,
    alloc: std.mem.Allocator,

    // ---- live settings (#16, made mutable by #32/#34): the immutable-snapshot store.
    //      The menu is the sole writer; every reader acquire-loads a coherent snapshot
    //      at use (tap → talk_key, insert worker → insertion, session connect → params).
    store: config.Store,

    /// Menu-bar "Pause dictation" (#34): a paused daemon ignores Talk Key presses (the
    /// key keeps its normal OS meaning). Runtime-only — not a config.zon field.
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ---- long-lived modules ----
    capture: cap.Capture = .{},
    inserter: insertmod.Inserter = .{},
    cues: feedback.Cues = .{},
    hud: hud_mod.Hud = .{},
    menu: menu_mod.Menu = .{},
    tap: tapmod.Tap = undefined, // built in run()

    // ---- the Coordinator's real adapters + the Coordinator itself (wired in run()) ----
    transcription: TranscriptionAdapter = .{},
    insertion: InsertionAdapter = undefined,
    deadline: DeadlineAdapter = .{},
    feedback_surface: surface.Surface = undefined,
    coordinator: Coord = undefined,

    /// Supervisor-thread-only: remembers the last not-configured missing set, so the
    /// same prerequisites are not re-logged every tick.
    readiness_reporter: readiness.Reporter = .{},

    /// Always-on live-transcript subscriber: Final Transcripts from the read-loop thread
    /// trampoline into the Coordinator. Installed at every Session.connect, before the read
    /// loop starts — never mid-stream. Partials are not subscribed — the HUD shows no text
    /// (wayfinder #27); their log lives upstream in session.zig (#18).
    fn observer(self: *Daemon) session_mod.TranscriptObserver {
        return .{ .ctx = self, .on_final = obsFinal };
    }
    fn obsFinal(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.coordinator.handle(.{ .final = text });
    }

    /// Capture chunk sink: forward PCM to the current Session (created lazily by the
    /// supervisor). A press only starts Capture once a session exists, so the null case is
    /// belt-and-braces for a chunk delivered during teardown.
    fn audioSink(ctx: ?*anyopaque, pcm: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.transcription.appendAudio(pcm);
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

    fn supervisorLoop(self: *Daemon) void {
        var announced = false;
        var first = true;
        while (!g_quit.load(.acquire)) {
            if (!first) sleepInterruptible(supervisor_tick_ms);
            first = false;
            if (g_quit.load(.acquire)) return;

            // 1. Build the Transcription Session the moment the API key is present.
            if (!self.transcription.available()) {
                if (config.loadApiKeyOnly(self.io, self.alloc)) |key| {
                    const sess = Session.connect(self.io, self.alloc, key, .{ .ctx = self, .get = getParams }, self.observer()) catch |e| {
                        feedback.log("  supervisor: session connect failed: {s} — will retry\n", .{@errorName(e)});
                        continue;
                    };
                    self.transcription.set(sess);
                    feedback.log("  supervisor: API key found — Transcription Session connecting…\n", .{});
                }
            }

            // 2. Grants — silent preflight (no re-prompt).
            const im = tapmod.Tap.listenGranted();
            const pe = insertmod.postEventGranted();

            // 3. Bring the created-but-disabled tap live once Input Monitoring appears.
            if (im and !self.tap.isEnabled()) {
                if (self.tap.enable())
                    feedback.log("  supervisor: Input Monitoring granted — Talk Key tap is live\n", .{})
                else
                    feedback.log("  supervisor: Input Monitoring looks granted but the tap won't enable — a daemon restart may be needed\n", .{});
            }

            // 4. Configured? (PostEvent is also preflighted per-insert, so a later revoke is
            //    caught there too; here it just gates the "READY" banner + reporting.)
            const rs = self.readinessSnapshot(im, pe);
            if (readiness.configured(rs)) {
                _ = self.readiness_reporter.next(rs);
                if (!announced) {
                    announced = true;
                    feedback.log("  READY — hold {s}, speak, release; the transcript lands at the cursor.\n", .{keyName(self.store.current().talk_key)});
                }
            } else {
                announced = false;
                self.reportMissing(rs);
            }
        }
    }

    /// Log the missing prerequisites once per distinct set (not every tick), with one error
    /// cue so a headless user hears that the daemon is waiting on them.
    fn reportMissing(self: *Daemon, rs: readiness.Snapshot) void {
        const report = self.readiness_reporter.next(rs) orelse return;

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

    fn readinessSnapshot(self: *Daemon, im: bool, pe: bool) readiness.Snapshot {
        const session_ready = if (self.transcription.current()) |s| s.isReady() else false;
        return .{
            .key_present = self.transcription.available(),
            .input_monitoring_granted = im,
            .post_event_granted = pe,
            .tap_enabled = self.tap.isEnabled(),
            .session_ready = session_ready,
            .paused = self.paused.load(.acquire),
        };
    }

    fn menuStatus(status: readiness.Status) menu_mod.Status {
        return switch (status) {
            .ready => .ready,
            .reconnecting => .reconnecting,
            .no_key => .no_key,
            .input_monitoring_needed => .input_monitoring_needed,
            .accessibility_needed => .accessibility_needed,
        };
    }

    // menu.Host callbacks — all run on the main thread (menu action / chrome pump).

    /// Health for the two-tier icon + status line, in the menu's priority order. The
    /// same signals the supervisor gates "configured" on, read non-destructively.
    fn menuHealth(ctx: *anyopaque) menu_mod.Health {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const h = readiness.health(self.readinessSnapshot(tapmod.Tap.listenGranted(), insertmod.postEventGranted()));
        return .{ .paused = h.paused, .status = menuStatus(h.status) };
    }

    /// A session-shaped setting changed: nudge the Session to cycle when idle. Before
    /// the first connect there is nothing to mark — that connect reads the snapshot.
    fn menuMarkSessionDirty(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (self.transcription.current()) |s| s.markParamsDirty();
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
pub fn run(io: std.Io, alloc: std.mem.Allocator) !void {
    // Settings load always (defaults if absent); the secret is NOT required up front — the
    // supervisor waits for it (self-heal). The parsed Settings become the first immutable
    // snapshot in the Store (#32); every later change swaps in a fresh heap copy.
    const first_snapshot = try alloc.create(config.Settings);
    first_snapshot.* = config.loadSettingsOnly(io, alloc);
    const settings = first_snapshot.*;
    std.debug.print("config: talk_key={s} model=\"{s}\" language=\"{s}\" delay=\"{s}\" noise_reduction={s} insertion={s} overlay={}\n", .{
        @tagName(settings.talk_key), settings.model, settings.language, settings.delay, @tagName(settings.noise_reduction), @tagName(settings.insertion), settings.overlay,
    });

    var daemon = Daemon{
        .io = io,
        .alloc = alloc,
        .store = config.Store.init(first_snapshot),
    };

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
    daemon.insertion = InsertionAdapter.init(.{ .inserter = &daemon.inserter, .store = &daemon.store });
    daemon.coordinator = Coord.init(.{
        .audio = &daemon.capture,
        .transcription = &daemon.transcription,
        .insertion = &daemon.insertion,
        .deadline = &daemon.deadline,
        .feedback = &daemon.feedback_surface,
    });
    // Reverse edges: the worker/timer threads re-enter the now-constructed Coordinator.
    daemon.insertion.deps.co_ctx = &daemon.coordinator;
    daemon.insertion.deps.on_done = insertDoneTramp;
    daemon.deadline.co_ctx = &daemon.coordinator;
    daemon.deadline.on_fire = deadlineFireTramp;

    // ---- Talk Key tap: prompt for the two event grants once, then create the tap on THIS
    //      (main) run loop. A created-but-disabled tap is fine — the supervisor enables it
    //      once Input Monitoring appears. Only a null port is a genuine hard failure. ----
    const listen_ok = tapmod.Tap.requestListenAccess();
    const post_ok = insertmod.requestPostEventAccess();
    feedback.log("TCC grants for the type-wave daemon:\n", .{});
    feedback.log("  Input Monitoring (Talk Key tap): {s}\n", .{if (listen_ok) "granted" else "NOT granted — waiting"});
    feedback.log("  PostEvent        (Insertion):    {s}\n", .{if (post_ok) "granted" else "NOT granted — waiting"});
    // (Microphone is prompted lazily on the first Capture start.)

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
        .health = Daemon.menuHealth,
        .markSessionDirty = Daemon.menuMarkSessionDirty,
        .setOverlay = Daemon.menuSetOverlay,
        .setPaused = Daemon.menuSetPaused,
        .storeApiKey = Daemon.menuStoreApiKey,
        .quit = Daemon.menuQuit,
    });
    feedback.log("  menu bar: {s}\n", .{if (menu_up) "status item up" else "no display — running headless (no status item)"});

    // ---- threads ----
    const worker = try std.Thread.spawn(.{}, InsertionAdapter.workerLoop, .{&daemon.insertion});
    worker.detach();
    const timer = try std.Thread.spawn(.{}, DeadlineAdapter.timerLoop, .{&daemon.deadline});
    timer.detach();
    // The supervisor is JOINED at shutdown (below), so it can't race the session teardown.
    const supervisor = try std.Thread.spawn(.{}, Daemon.supervisorLoop, .{&daemon});

    _ = signal(SIGINT, onSignal);
    _ = signal(SIGTERM, onSignal);
    const watcher = try std.Thread.spawn(.{}, quitWatcher, .{CFRunLoopGetMain()});
    watcher.detach();

    feedback.log("type-wave daemon up — self-healing. SIGTERM/Ctrl-C to quit.\n", .{});

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
    if (daemon.transcription.current()) |sess| sess.shutdown();
    feedback.log("bye.\n", .{});
}
