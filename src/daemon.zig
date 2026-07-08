//! daemon.zig — the headless type-wave daemon (wayfinder #19).
//!
//! The capstone that turns the proven modules into a real daily-driver background
//! daemon: hold the Talk Key → CoreAudio Capture streams to the warm OpenAI
//! Transcription Session → on release the Final Transcript is inserted at the cursor of
//! the Focused Target — running headless under the LaunchAgent (wayfinder #15), settings
//! and secret from config (#16), the session keeping itself warm and reconnecting between
//! Utterances (#17), every transition and failure surfaced through feedback (#18).
//!
//! # Two orthogonal state machines
//!
//! 1. **Configuration phase** (this file, the self-heal supervisor): `not-configured`
//!    ⇄ `configured`. The gate is (an API key is present) AND (Input Monitoring granted)
//!    AND (PostEvent granted). Missing prerequisites do NOT crash the daemon — under the
//!    LaunchAgent's `KeepAlive={SuccessfulExit=false}` a non-zero exit would crash-loop.
//!    Instead the supervisor thread polls (~3 s), builds the Transcription Session the
//!    moment a key appears, brings the created-but-disabled Talk Key tap live the moment
//!    Input Monitoring appears, and promotes the daemon to `configured` with zero manual
//!    restart. `exit(0)` is reserved for a clean SIGTERM/bootout.
//!
//! 2. **Link state** (owned by session.zig): connecting / ready / reconnecting / closed.
//!    The session self-manages it; the daemon only reads `isReady()` / `isPoisoned()`.
//!
//! # Utterance lifecycle & its edges (grilled for #19)
//!
//!   - **Overlap / rapid double-tap** — a `busy` span covers press → Insertion-done. A
//!     press arriving while a prior Utterance is still resolving is dropped (logged), so
//!     the worker's read of the shared Final Transcript never races a fresh beginUtterance.
//!     `hold_active` (run-loop-thread-only) pairs press↔release so a *rejected* press's
//!     release is a no-op.
//!   - **Press mid-reconnect** — kept as #17's behavior: begin + buffer Capture locally +
//!     defer the commit; markReadyAndFlush replays it in order on reconnect. NOT dropped.
//!   - **Deferred/slow Insertion** — a single release-anchored deadline
//!     (`insert_deadline_ms`): the worker begins within ms of release and waits that long
//!     for the Final Transcript, covering both the live and the reconnect-spanning path.
//!     Past it, the Utterance is dropped (error cue) so stale text never lands and `busy`
//!     never blocks new Utterances indefinitely.
//!   - **Link drop mid-Utterance** — session.zig poisons the Utterance (its head audio is
//!     lost server-side); the daemon reads `isPoisoned()` on release and abandons it
//!     cleanly (error cue, no truncated Insertion) instead of committing a fragment.
//!   - **TCC revoked mid-Utterance** — the tap self-heals + surfaces via `onTapDisabled`
//!     (#18); PostEvent is preflighted per insert (Inserter); mic silence is detected.
//!
//! # Threads
//!   - main thread      : installs the tap + the overlay HUD render pump (a CFRunLoopTimer,
//!                         wayfinder #22), then blocks in CFRunLoopRun servicing both. All
//!                         AppKit calls happen here (on the render pump); other threads only
//!                         `hud.publish` into a mutex-guarded buffer the pump reads.
//!   - run-loop thread   : the tap callback. onPress/onRelease. Kept fast (a slow callback
//!                         makes the OS disable the tap) — only the cheap edge work.
//!   - worker thread     : waits for the Final Transcript, then performs the Insertion.
//!   - supervisor thread : the self-heal loop (config phase above).
//!   - read-loop thread  : the websocket handler (session.zig).
//!   - maintenance thread: (session.zig) keepalive ping + expiry/drop reconnect.
//!   - quit watcher      : waits for SIGINT/SIGTERM, then stops the run loop.
//!   - AudioQueue thread : delivers Capture chunks, forwarded to the session.
//! Cross-thread coordination is via atomics + the session's write mutex.

const std = @import("std");
const cap = @import("capture.zig");
const session_mod = @import("session.zig");
const tapmod = @import("tap.zig");
const insertmod = @import("insert.zig");
const config = @import("config.zig");
const feedback = @import("feedback.zig");
const hud_mod = @import("hud.zig");

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
/// Release-anchored Insertion deadline (grilled for #19): the worker starts within ms of
/// Talk Key release, so this bounds both the live wait and a reconnect-spanning wait. Past
/// it the Utterance is dropped rather than inserting stale text or blocking new Utterances.
const insert_deadline_ms: usize = 15_000;

/// Raised by the SIGINT/SIGTERM handler (async-signal-safe store only); the quit watcher
/// polls it and stops the run loop, and the supervisor polls it to end promptly.
var g_quit = std.atomic.Value(bool).init(false);

fn onSignal(_: c_int) callconv(.c) void {
    g_quit.store(true, .release);
}

/// Waits for the quit signal, then stops the main run loop (CFRunLoopStop is documented
/// thread-safe), unblocking `tap.run()` on the main thread.
fn quitWatcher(loop: CFRunLoopRef) void {
    while (!g_quit.load(.acquire)) _ = usleep(50_000);
    CFRunLoopStop(loop);
}

/// A sleep that returns early once quitting, so the supervisor joins promptly at shutdown.
fn sleepInterruptible(ms: usize) void {
    var waited: usize = 0;
    while (waited < ms and !g_quit.load(.acquire)) {
        _ = usleep(50_000);
        waited += 50;
    }
}

fn waitFor(flag: *std.atomic.Value(bool), timeout_ms: usize) bool {
    var waited: usize = 0;
    while (!flag.load(.acquire)) {
        _ = usleep(10_000);
        waited += 10;
        if (waited >= timeout_ms) return false;
    }
    return true;
}

/// Human-readable name for the configured Talk Key, for the log.
fn keyName(k: tapmod.TalkKey) []const u8 {
    return switch (k) {
        .right_option => "Right-Option",
        .left_option => "Left-Option",
        .globe => "Globe/Fn",
    };
}

fn explainInsert(e: insertmod.InsertError) []const u8 {
    return switch (e) {
        error.PostEventDenied => "no PostEvent grant — enable type-wave under System Settings > Privacy & Security > Accessibility",
    };
}

/// Capture chunk sink: forward PCM to the *current* session (created lazily by the
/// supervisor). A press only starts Capture once a session exists (onPress guard), so the
/// null case here is belt-and-braces for a chunk delivered during teardown.
fn audioSink(ctx: ?*anyopaque, pcm: []const u8) void {
    const self: *Daemon = @ptrCast(@alignCast(ctx.?));
    const sess = self.getSession() orelse return;
    sess.appendAudio(pcm);
}

/// The whole daemon: the long-lived pieces plus the state the tap callbacks, the worker,
/// and the supervisor share. A single instance lives on `run`'s stack for the process
/// lifetime; its address is handed to every thread and to the tap as its callback context.
const Daemon = struct {
    io: std.Io,
    alloc: std.mem.Allocator,

    // ---- from config (#16); read-only after startup ----
    settings: config.Settings,
    talk_key: tapmod.TalkKey,
    insert_method: insertmod.Method,
    params: session_mod.TranscriptionParams,

    // ---- long-lived modules ----
    capture: cap.Capture = .{},
    inserter: insertmod.Inserter = .{},
    cues: feedback.Cues = .{},
    /// The live-partials overlay pill (wayfinder #22). Inactive until `hud.init()` succeeds
    /// in run(); every method no-ops while inactive, so a disabled/headless daemon just
    /// falls back to the sound cues. When active it takes over start/stop feedback (the
    /// pill is the signal), leaving only the error cue audible.
    hud: hud_mod.Hud = .{},
    tap: tapmod.Tap = undefined, // built in run()

    /// The warm Transcription Session, created by the supervisor once the API key is
    /// present. Stored as a raw pointer bits value so the load/publish is a plain atomic
    /// (0 = not yet created). Read by the tap callbacks, the worker, and audioSink.
    session_ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Overlap guard (grilled for #19): true from an accepted press until the worker (or a
    /// synchronous early-out) has fully resolved that Utterance's Insertion. A press while
    /// set is dropped. Cross-thread (set on the run-loop thread, cleared by the worker) so
    /// it is atomic.
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Run-loop-thread-only (onPress/onRelease never overlap): marks that *this* hold was
    /// accepted, so a release whose press was rejected (busy / not configured) is a no-op.
    hold_active: bool = false,
    /// Raised by onRelease, drained by the worker: "an Utterance was committed — wait for
    /// its Final Transcript and insert it".
    insert_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Supervisor-thread-only: the last set of missing prerequisites reported, so
    /// not-configured isn't re-logged every tick. 0xFF = nothing reported yet.
    last_missing: u8 = 0xFF,

    fn getSession(self: *Daemon) ?*Session {
        const p = self.session_ptr.load(.acquire);
        if (p == 0) return null;
        const sess: *Session = @ptrFromInt(p);
        return sess;
    }

    // ---- overlay HUD subscription (wayfinder #22) ----
    // The session drives the pill's text: Partial Transcripts colour it red and stream
    // live; the Final Transcript flashes it green (the worker then inserts and hides it).
    // Both run on the read-loop thread and only `hud.publish` (mutex-guarded, no AppKit),
    // so they are safe there. Handed to Session.connect only when the HUD is active.

    fn onPartial(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.hud.publish(.recording, text);
    }

    fn onFinal(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.hud.publish(.final, text);
    }

    fn transcriptObserver(self: *Daemon) ?session_mod.TranscriptObserver {
        if (!self.hud.active) return null; // no HUD ⇒ transcripts stay log-only (#18)
        return .{ .ctx = self, .on_partial = onPartial, .on_final = onFinal };
    }

    // ---- tap callbacks: run on the run-loop thread, kept fast ----

    fn onPress(ctx: ?*anyopaque, key: tapmod.TalkKey, _: i64, _: u64) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (key != self.talk_key) return;

        // Overlap guard: previous Utterance still resolving — drop this press so we never
        // reset the shared Final-Transcript state out from under the worker.
        if (self.busy.load(.acquire)) {
            feedback.log("  Talk Key pressed while the previous Utterance is still inserting — ignored\n", .{});
            return;
        }
        // The tap can be live before the session exists (Input Monitoring granted, key not
        // yet present). With no session there is nowhere to stream to.
        const sess = self.getSession() orelse {
            feedback.log("  Talk Key pressed but no Transcription Session yet (missing API key?) — ignored\n", .{});
            self.cues.err();
            return;
        };

        self.busy.store(true, .release);
        self.hold_active = true;
        sess.beginUtterance();
        self.capture.start() catch |e| {
            feedback.log("  capture.start failed: {s} — Utterance aborted\n", .{@errorName(e)});
            sess.endUtterance();
            self.hold_active = false;
            self.busy.store(false, .release);
            self.cues.err();
            return;
        };
        // Signal "listening" only once Capture is actually up: the pill (red, awaiting the
        // first Partial Transcript) supersedes the start chime when the overlay is on;
        // otherwise the chime carries it (wayfinder #22).
        if (self.hud.active) self.hud.publish(.recording, "") else self.cues.start();
        feedback.log("  [REC] listening — release the Talk Key to insert\n", .{});
    }

    fn onRelease(ctx: ?*anyopaque, key: tapmod.TalkKey) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (key != self.talk_key) return;
        if (!self.hold_active) return; // press was rejected — nothing to end
        self.hold_active = false;

        const sess = self.getSession() orelse {
            self.hud.publish(.hidden, ""); // pill was up since press — take it down
            self.busy.store(false, .release); // session vanished mid-hold (shutdown) — release the guard
            return;
        };
        self.capture.stop(); // synchronous; final buffers flush (and forward) during this call
        sess.endUtterance(); // stop forwarding before committing
        // The pill stays up (showing the last partial) until the Final flashes or the
        // Utterance resolves below; the stop chime only carries this when there's no pill.
        if (!self.hud.active) self.cues.stop();

        // Link dropped mid-Utterance: the head audio already streamed live is gone, so
        // committing would insert a truncated tail. Abandon cleanly (grilled for #19).
        if (sess.isPoisoned()) {
            feedback.log("  Transcription Session dropped mid-Utterance — discarded; hold the Talk Key and say it again\n", .{});
            self.hud.publish(.hidden, ""); // abandon: no truncated tail shown (error cue kept)
            self.cues.err();
            self.busy.store(false, .release);
            return;
        }

        // Mic-silence detection: TCC denial yields all-zero PCM with no error (#18).
        if (!self.capture.heardSound())
            feedback.log("  microphone captured only silence — is Microphone permission granted to this process?\n", .{});

        const expecting = sess.commitUtterance() catch |e| blk: {
            feedback.log("  commit error: {s}\n", .{@errorName(e)});
            break :blk false;
        };
        if (expecting) {
            self.insert_pending.store(true, .release); // worker awaits the Final Transcript; it clears busy
        } else {
            // Nothing committed (no audio) — no Insertion is coming, so resolve now.
            feedback.log("  Utterance produced no audio — nothing to insert\n", .{});
            self.hud.publish(.hidden, ""); // no Final coming — hide the pill now
            self.cues.err();
            self.busy.store(false, .release);
        }
    }

    /// Tap self-heal outcome (#18): a re-enable that didn't take means Input Monitoring was
    /// revoked; surface it. The tap recovers automatically once the grant returns.
    fn onTapDisabled(ctx: ?*anyopaque, by_timeout: bool, reenabled: bool) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (reenabled) {
            feedback.log("  Talk Key tap was disabled ({s}) and re-enabled\n", .{if (by_timeout) "OS timeout" else "user input"});
        } else {
            feedback.log("  Talk Key tap DISABLED and could not be re-enabled — Input Monitoring may be revoked; re-grant it to recover\n", .{});
            self.cues.err();
        }
    }

    // ---- worker thread: the blocking wait + the slow Insertion, off the callback ----

    fn workerLoop(self: *Daemon) void {
        while (!g_quit.load(.acquire)) {
            if (!self.insert_pending.swap(false, .acquire)) {
                _ = usleep(2_000);
                continue;
            }
            self.processUtterance();
        }
    }

    /// Resolve one committed Utterance: wait for its Final Transcript (release-anchored
    /// deadline), then insert. `busy` is cleared however this returns.
    fn processUtterance(self: *Daemon) void {
        defer self.busy.store(false, .release);
        // Hide the pill however this resolves (inserted, empty, timed out, or insert-failed).
        // On the happy path the Final Transcript is already flashing green — published by the
        // read-loop's on_final — and the paste below holds it on screen; this takes it down
        // once the Insertion is done (wayfinder #22).
        defer self.hud.publish(.hidden, "");

        const sess = self.getSession() orelse return;

        if (!waitFor(&sess.got_final, insert_deadline_ms)) {
            feedback.log("  no Final Transcript within {d}s — nothing inserted\n", .{insert_deadline_ms / 1000});
            self.cues.err();
            return;
        }
        const n = sess.final_len;
        if (n == 0) {
            // Empty/failed transcript (mic silence, transcription.failed, …).
            feedback.log("  empty Final Transcript — nothing to insert\n", .{});
            self.cues.err();
            return;
        }
        // NUL-terminate for insert.paste (it becomes an NSString).
        var buf: [8192]u8 = undefined;
        const len = @min(n, buf.len - 1);
        @memcpy(buf[0..len], sess.final[0..len]);
        buf[len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        self.inserter.insert(self.insert_method, z) catch |e| {
            feedback.log("  insertion failed: {s}\n", .{explainInsert(e)});
            self.cues.err();
            return;
        };
        feedback.log("  inserted {d} chars at the cursor\n", .{len});
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
            if (self.getSession() == null) {
                if (config.loadApiKeyOnly(self.io, self.alloc)) |key| {
                    const sess = Session.connect(self.io, self.alloc, key, self.params, self.transcriptObserver()) catch |e| {
                        feedback.log("  supervisor: session connect failed: {s} — will retry\n", .{@errorName(e)});
                        continue;
                    };
                    self.session_ptr.store(@intFromPtr(sess), .release);
                    feedback.log("  supervisor: API key found — Transcription Session connecting…\n", .{});
                }
            }

            // 2. Grants — silent preflight (no re-prompt).
            const im = tapmod.Tap.listenGranted();
            const pe = insertmod.postEventGranted();
            const key_ok = self.getSession() != null;

            // 3. Bring the created-but-disabled tap live once Input Monitoring appears.
            if (im and !self.tap.isEnabled()) {
                if (self.tap.enable())
                    feedback.log("  supervisor: Input Monitoring granted — Talk Key tap is live\n", .{})
                else
                    feedback.log("  supervisor: Input Monitoring looks granted but the tap won't enable — a daemon restart may be needed\n", .{});
            }

            // 4. Configured? (PostEvent is also preflighted per-insert, so a later revoke
            //    is caught there too; here it just gates the "READY" banner + reporting.)
            const configured = key_ok and im and pe and self.tap.isEnabled();
            if (configured) {
                if (!announced) {
                    announced = true;
                    self.last_missing = 0xFF; // so a later drop re-reports what's missing
                    feedback.log("  READY — hold {s}, speak, release; the transcript lands at the cursor.\n", .{keyName(self.talk_key)});
                }
            } else {
                announced = false;
                self.reportMissing(key_ok, im, pe);
            }
        }
    }

    /// Log the missing prerequisites once per distinct set (not every tick), with one
    /// error cue so a headless user hears that the daemon is waiting on them.
    fn reportMissing(self: *Daemon, key_ok: bool, im: bool, pe: bool) void {
        var missing: u8 = 0;
        if (!key_ok) missing |= 1;
        if (!im) missing |= 2;
        if (!pe) missing |= 4;
        if (missing == self.last_missing) return; // already reported this exact set
        self.last_missing = missing;

        feedback.log("  not-configured — waiting on:\n", .{});
        if (!key_ok) feedback.log("    - OPENAI_API_KEY in ~/.config/type-wave/env (issue #7)\n", .{});
        if (!im) feedback.log("    - Input Monitoring for type-wave (System Settings > Privacy & Security > Input Monitoring)\n", .{});
        if (!pe) feedback.log("    - Accessibility for type-wave (System Settings > Privacy & Security > Accessibility)\n", .{});
        self.cues.err();
    }
};

/// Entry point: wire the modules, spawn the threads, and run the tap's run loop until a
/// quit signal. Never exits non-zero for a *recoverable* condition (missing key/grants) —
/// those are the supervisor's job — so the LaunchAgent never crash-loops on them.
pub fn run(io: std.Io, alloc: std.mem.Allocator) !void {
    // Settings load always (defaults if absent); the secret is NOT required up front —
    // the supervisor waits for it (self-heal).
    const settings = config.loadSettingsOnly(io, alloc);
    std.debug.print("config: talk_key={s} model=\"{s}\" language=\"{s}\" delay=\"{s}\" noise_reduction={s} insertion={s} overlay={}\n", .{
        @tagName(settings.talk_key), settings.model, settings.language, settings.delay, @tagName(settings.noise_reduction), @tagName(settings.insertion), settings.overlay,
    });

    var daemon = Daemon{
        .io = io,
        .alloc = alloc,
        .settings = settings,
        .talk_key = settings.talk_key,
        .insert_method = settings.insertion,
        .params = .{
            .model = settings.model,
            .language = settings.language,
            .delay = settings.delay,
            .noise_reduction = settings.noiseReductionType(),
        },
    };

    // ---- modules that need neither a grant nor the key to construct ----
    try daemon.capture.init();
    defer daemon.capture.deinit();
    daemon.capture.ctx = &daemon;
    daemon.capture.on_chunk = audioSink;

    daemon.inserter.init();
    daemon.cues.init();

    // ---- overlay HUD (wayfinder #22): the live-partials pill. Built here, on the main
    //      thread, so its CFRunLoopTimer render pump joins the SAME run loop the tap will
    //      block on (daemon.tap.run → CFRunLoopRun). Off by config, or headless with no
    //      display, both degrade to the sound cues (#18) without failing startup. ----
    if (settings.overlay) {
        if (daemon.hud.init()) {
            daemon.hud.startRenderPump();
            feedback.log("  overlay HUD: on — the pill carries start/stop feedback; the error cue is kept\n", .{});
        } else {
            feedback.log("  overlay HUD: enabled but no display detected — sound-only feedback\n", .{});
        }
    } else {
        feedback.log("  overlay HUD: off (config.overlay=false) — sound-only feedback\n", .{});
    }

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
        .on_press = Daemon.onPress,
        .on_release = Daemon.onRelease,
        .on_disabled = Daemon.onTapDisabled,
    } };
    const tap_live = daemon.tap.install() catch |e| switch (e) {
        error.TapCreateFailed => {
            feedback.log("CGEventTapCreate returned NULL — cannot observe the Talk Key. Exiting.\n", .{});
            return e;
        },
    };
    feedback.log("  Talk Key tap: {s}\n", .{if (tap_live) "live" else "created, waiting for Input Monitoring"});

    // ---- threads ----
    const worker = try std.Thread.spawn(.{}, Daemon.workerLoop, .{&daemon});
    worker.detach();
    // The supervisor is JOINED at shutdown (below), so it can't race the session teardown.
    const supervisor = try std.Thread.spawn(.{}, Daemon.supervisorLoop, .{&daemon});

    _ = signal(SIGINT, onSignal);
    _ = signal(SIGTERM, onSignal);
    const watcher = try std.Thread.spawn(.{}, quitWatcher, .{CFRunLoopGetMain()});
    watcher.detach();

    feedback.log("type-wave daemon up — self-healing. SIGTERM/Ctrl-C to quit.\n", .{});

    daemon.tap.run(); // CFRunLoopRun — blocks until the quit watcher stops the loop

    // Quit: g_quit is set (that's why run() returned). Join the supervisor first so it is
    // not mid-connect, then close the session gracefully (websocket close-frame drain,
    // #17). We deliberately do NOT deinit the session: the process is exiting, the OS
    // reclaims its memory, and skipping the free avoids any race with the detached worker
    // that may still hold the pointer (same process-lifetime-singleton stance as config).
    feedback.log("shutting down…\n", .{});
    supervisor.join();
    if (daemon.getSession()) |sess| sess.shutdown();
    feedback.log("bye.\n", .{});
}
