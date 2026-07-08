//! type-wave — daemon skeleton (wayfinder #14).
//!
//! The minimal foreground loop that proves the two prototype halves compose in a
//! single process: hold the Talk Key → CoreAudio Capture streams to the OpenAI
//! Transcription Session → on release, the Final Transcript is inserted at the cursor
//! of the Focused Target. Settings load from config (wayfinder #16); the session keeps
//! itself warm and reconnects between Utterances (wayfinder #17). No feedback subsystem
//! or self-healing yet — those are wayfinder #18–#19. `prototypes/` stays frozen.
//!
//! Threading, and why the slow work is off the tap callback:
//!   - main thread     : installs the tap, then blocks in CFRunLoopRun servicing it.
//!   - run-loop thread  : the tap callback. Fires onPress/onRelease. Must stay fast
//!                        (a slow callback makes the OS disable the tap), so it does
//!                        only the cheap edge work (begin/start; stop/commit) and
//!                        hands the blocking wait-for-final + ~400 ms paste to…
//!   - worker thread    : waits for the Final Transcript, then performs the Insertion.
//!   - read-loop thread : the websocket handler (session.zig), parses server events.
//!   - maintenance thread: (session.zig) keepalive ping + expiry/drop reconnect.
//!   - quit watcher     : waits for SIGINT/SIGTERM, then stops the run loop.
//!   - AudioQueue thread: delivers Capture chunks, forwarded to the session.
//! Cross-thread coordination is via the session's atomics + its write mutex.
//!
//! NB (deferred to #19's state-machine grilling): overlapping Utterances (a new
//! press while the worker is still inserting the previous one) are not hardened
//! here — the onPress/onRelease `recording` guard assumes press → hold → release →
//! settle, which holds for a human at rest between Utterances.

const std = @import("std");
const cap = @import("capture.zig");
const session_mod = @import("session.zig");
const tapmod = @import("tap.zig");
const insertmod = @import("insert.zig");
const config = @import("config.zig");

const Session = session_mod.Session;

// Force the __TEXT,__info_plist section (src/info_plist.zig) to be analysed and kept:
// it carries the daemon's stable bundle identity + mic usage string (wayfinder #15).
comptime {
    _ = &@import("info_plist.zig").info_plist;
}

extern "c" fn usleep(usec: c_uint) c_int;
// Fatal-startup paths still exit the process; the OS reclaims the socket. The normal
// quit path is graceful now (SIGINT/SIGTERM -> stop the run loop -> session.shutdown,
// which does the websocket close-frame drain — wayfinder #17).
extern "c" fn exit(code: c_int) noreturn;

const CFRunLoopRef = ?*anyopaque;
extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
extern "c" fn CFRunLoopStop(rl: CFRunLoopRef) void;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) callconv(.c) usize;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;

/// Raised by the SIGINT/SIGTERM handler; the quit watcher polls it and stops the run
/// loop so main can fall through to a graceful shutdown. The handler itself does only
/// this async-signal-safe store.
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

/// Human-readable name for the configured Talk Key, for the startup banner.
fn keyName(k: tapmod.TalkKey) []const u8 {
    return switch (k) {
        .right_option => "Right-Option",
        .left_option => "Left-Option",
        .globe => "Globe/Fn",
    };
}

fn audioSink(ctx: ?*anyopaque, pcm: []const u8) void {
    const s: *Session = @ptrCast(@alignCast(ctx.?));
    s.appendAudio(pcm);
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

/// Wires the three pieces together and carries the state the tap callbacks and the
/// worker share. Passed to the tap as its callback context.
const App = struct {
    session: *Session,
    capture: *cap.Capture,
    inserter: *insertmod.Inserter,

    /// From config (wayfinder #16): which key drives an Utterance, and how the Final
    /// Transcript is inserted. Read-only after startup.
    talk_key: tapmod.TalkKey,
    insert_method: insertmod.Method,

    /// Touched only on the run-loop thread (onPress/onRelease never overlap), so it
    /// needs no atomic: guards against a repeat press before release.
    recording: bool = false,

    /// Raised by onRelease (release), drained by the worker (acquire): "an Utterance
    /// was committed — go wait for its Final Transcript and insert it".
    insert_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ---- tap callbacks: run on the run-loop thread, kept fast ----

    fn onPress(ctx: ?*anyopaque, key: tapmod.TalkKey, _: i64, _: u64) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (key != self.talk_key) return;
        if (self.recording) return;
        self.recording = true;
        self.session.beginUtterance();
        self.capture.start() catch |e| {
            std.debug.print("  capture.start failed: {}\n", .{e});
            self.session.endUtterance();
            self.recording = false;
            return;
        };
        std.debug.print("[REC ] speaking… release Right-Option to insert.\n", .{});
    }

    fn onRelease(ctx: ?*anyopaque, key: tapmod.TalkKey) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (key != self.talk_key) return;
        if (!self.recording) return;
        self.recording = false;
        self.capture.stop(); // synchronous; final buffers flush (and forward) during this call
        self.session.endUtterance(); // stop forwarding before committing
        self.session.commitUtterance() catch |e| std.debug.print("  commit error: {}\n", .{e});
        if (!self.capture.heardSound())
            std.debug.print("  (warning: only silence captured — Microphone permission denied?)\n", .{});
        self.insert_pending.store(true, .release);
    }

    // ---- worker thread: the blocking wait + the slow Insertion, off the callback ----

    fn workerLoop(self: *App) void {
        var buf: [8192]u8 = undefined;
        while (true) {
            if (!self.insert_pending.swap(false, .acquire)) {
                _ = usleep(2_000);
                continue;
            }
            if (!waitFor(&self.session.got_final, 15_000)) {
                std.debug.print("  (no transcript within 15s — nothing inserted)\n", .{});
                continue;
            }
            const n = self.session.final_len;
            if (n == 0) {
                std.debug.print("  (empty transcript — nothing to insert)\n", .{});
                continue;
            }
            // NUL-terminate for insert.paste (it becomes an NSString).
            const len = @min(n, buf.len - 1);
            @memcpy(buf[0..len], self.session.final[0..len]);
            buf[len] = 0;
            const z: [*:0]const u8 = @ptrCast(&buf);
            self.inserter.insert(self.insert_method, z) catch |e| std.debug.print("  insert failed: {s}\n", .{explainInsert(e)});
        }
    }
};

fn explainInsert(e: insertmod.InsertError) []const u8 {
    return switch (e) {
        error.PostEventDenied => "no PostEvent grant — enable this terminal under System Settings > Privacy & Security > Accessibility, then re-run",
    };
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("type-wave — daemon skeleton (wayfinder #14)\n\n", .{});

    // ---- config: settings from ~/.config/type-wave/config.zon (defaults if absent),
    //      secret from ~/.config/type-wave/env or the env var (wayfinder #16) ----
    const cfg = config.load(io, alloc) catch |e| switch (e) {
        error.NoApiKey => return error.NoApiKey, // load() already logged how to fix it
    };
    const s = cfg.settings;
    std.debug.print("config: talk_key={s} model=\"{s}\" language=\"{s}\" delay=\"{s}\" noise_reduction={s} insertion={s}\n", .{
        @tagName(s.talk_key), s.model, s.language, s.delay, @tagName(s.noise_reduction), @tagName(s.insertion),
    });

    // ---- TCC: request the two event grants up front, report status ----
    const listen_ok = tapmod.Tap.requestListenAccess();
    const post_ok = insertmod.requestPostEventAccess();
    std.debug.print("TCC (attributed to THIS terminal for a foreground run):\n", .{});
    std.debug.print("  Input Monitoring (Talk Key tap): {s}\n", .{if (listen_ok) "granted" else "NOT granted"});
    std.debug.print("  PostEvent        (Insertion):    {s}\n", .{if (post_ok) "granted" else "NOT granted"});
    if (!listen_ok or !post_ok)
        std.debug.print("  → grant the missing permission(s) to this terminal and re-run (a prompt may have appeared).\n", .{});
    // (Microphone is prompted lazily on the first Capture start, attributed to the terminal.)

    // ---- Transcription Session: connect (starts the read loop + the warm-lifecycle
    //      maintenance thread internally) and wait until it is READY (wayfinder #17) ----
    std.debug.print("\nconnecting to wss://{s}/v1/realtime …\n", .{session_mod.host});
    const session = try Session.connect(io, alloc, cfg.api_key, .{
        .model = s.model,
        .language = s.language,
        .delay = s.delay,
        .noise_reduction = s.noiseReductionType(),
    });

    if (!session.waitReady(10_000)) {
        std.debug.print("timed out waiting for session.updated — aborting.\n", .{});
        exit(1);
    }

    // ---- Capture: create the queue, forward chunks to the session ----
    var capture = cap.Capture{};
    try capture.init();
    defer capture.deinit();
    capture.ctx = session;
    capture.on_chunk = audioSink;

    // ---- Insertion ----
    var inserter = insertmod.Inserter{};
    inserter.init();

    // ---- wire the shared state, spawn the worker ----
    var app = App{
        .session = session,
        .capture = &capture,
        .inserter = &inserter,
        .talk_key = s.talk_key,
        .insert_method = s.insertion,
    };
    const worker = try std.Thread.spawn(.{}, App.workerLoop, .{&app});
    worker.detach();

    // ---- Talk Key tap → run loop (blocks here) ----
    var tap = tapmod.Tap{ .cbs = .{
        .ctx = &app,
        .on_press = App.onPress,
        .on_release = App.onRelease,
    } };
    tap.install() catch |e| {
        switch (e) {
            error.TapCreateFailed => std.debug.print("\nCGEventTapCreate returned NULL — cannot observe the Talk Key.\n", .{}),
            error.TapDisabled => std.debug.print(
                \\
                \\The Talk Key tap was created but is DISABLED — Input Monitoring isn't
                \\granted to this terminal yet. Grant it (see above) and re-run.
                \\
            , .{}),
        }
        exit(1);
    };

    // Quit path: SIGINT/SIGTERM set a flag; the watcher stops the run loop so `tap.run()`
    // returns and we shut the session down gracefully (websocket close-frame drain, #17).
    _ = signal(SIGINT, onSignal);
    _ = signal(SIGTERM, onSignal);
    const watcher = try std.Thread.spawn(.{}, quitWatcher, .{CFRunLoopGetMain()});
    watcher.detach();

    std.debug.print(
        \\
        \\Ready. HOLD {s}, speak, release — the transcript is inserted at the cursor.
        \\(Listen-only tap: {s} still works normally elsewhere.) Ctrl-C to quit.
        \\
    , .{ keyName(s.talk_key), keyName(s.talk_key) });

    tap.run(); // CFRunLoopRun — blocks until the quit watcher stops the loop

    std.debug.print("\nshutting down — closing the Transcription Session…\n", .{});
    session.shutdown(); // graceful websocket close (close frame + drain), then free the link
    session.deinit();
    std.debug.print("bye.\n", .{});
}
