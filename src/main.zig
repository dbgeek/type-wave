//! type-wave — daemon skeleton (wayfinder #14).
//!
//! The minimal foreground loop that proves the two prototype halves compose in a
//! single process: hold Right-Option (the Talk Key) → CoreAudio Capture streams to
//! the OpenAI Transcription Session → on release, the Final Transcript is inserted
//! at the cursor of the Focused Target. Defaults are hardcoded; there is no config,
//! feedback subsystem, warm/reconnect lifecycle, self-healing, or packaging yet —
//! those are wayfinder #15–#19. `prototypes/` stays frozen as reference.
//!
//! Threading, and why the slow work is off the tap callback:
//!   - main thread     : installs the tap, then blocks in CFRunLoopRun servicing it.
//!   - run-loop thread  : the tap callback. Fires onPress/onRelease. Must stay fast
//!                        (a slow callback makes the OS disable the tap), so it does
//!                        only the cheap edge work (begin/start; stop/commit) and
//!                        hands the blocking wait-for-final + ~400 ms paste to…
//!   - worker thread    : waits for the Final Transcript, then performs the Insertion.
//!   - read-loop thread : the websocket handler (session.zig), parses server events.
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

const Session = session_mod.Session;

extern "c" fn usleep(usec: c_uint) c_int;
// Abort paths exit the process; the OS reclaims the socket, so we never race the
// read-loop thread by closing its fd underneath it. Graceful close is #17.
extern "c" fn exit(code: c_int) noreturn;

/// The single Talk Key for the skeleton (map default; config is #16).
const talk_key: tapmod.TalkKey = .right_option;

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

    /// Touched only on the run-loop thread (onPress/onRelease never overlap), so it
    /// needs no atomic: guards against a repeat press before release.
    recording: bool = false,

    /// Raised by onRelease (release), drained by the worker (acquire): "an Utterance
    /// was committed — go wait for its Final Transcript and insert it".
    insert_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ---- tap callbacks: run on the run-loop thread, kept fast ----

    fn onPress(ctx: ?*anyopaque, key: tapmod.TalkKey, _: i64, _: u64) void {
        if (key != talk_key) return;
        const self: *App = @ptrCast(@alignCast(ctx.?));
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
        if (key != talk_key) return;
        const self: *App = @ptrCast(@alignCast(ctx.?));
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
            self.inserter.paste(z) catch |e| std.debug.print("  insert failed: {s}\n", .{explainInsert(e)});
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

    // ---- secret: read directly from the env (config-from-file is #16) ----
    const api_key_z = std.c.getenv("OPENAI_API_KEY") orelse {
        std.debug.print("OPENAI_API_KEY not set. Run inside `nix develop` (see issue #7).\n", .{});
        return error.NoApiKey;
    };
    const api_key = std.mem.span(api_key_z);

    // ---- TCC: request the two event grants up front, report status ----
    const listen_ok = tapmod.Tap.requestListenAccess();
    const post_ok = insertmod.requestPostEventAccess();
    std.debug.print("TCC (attributed to THIS terminal for a foreground run):\n", .{});
    std.debug.print("  Input Monitoring (Talk Key tap): {s}\n", .{if (listen_ok) "granted" else "NOT granted"});
    std.debug.print("  PostEvent        (Insertion):    {s}\n", .{if (post_ok) "granted" else "NOT granted"});
    if (!listen_ok or !post_ok)
        std.debug.print("  → grant the missing permission(s) to this terminal and re-run (a prompt may have appeared).\n", .{});
    // (Microphone is prompted lazily on the first Capture start, attributed to the terminal.)

    // ---- Transcription Session: connect + wait until it is READY ----
    std.debug.print("\nconnecting to wss://{s}/v1/realtime …\n", .{session_mod.host});
    const session = try Session.connect(io, alloc, api_key);
    defer session.deinit();

    var handler = session_mod.Handler{ .session = session };
    const read_thread = try session.startReadLoop(&handler);
    defer read_thread.join();

    if (!waitFor(&session.ready, 10_000)) {
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
    var app = App{ .session = session, .capture = &capture, .inserter = &inserter };
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

    std.debug.print(
        \\
        \\Ready. HOLD Right-Option, speak, release — the transcript is inserted at the cursor.
        \\(Listen-only tap: Right-Option still works normally elsewhere.) Ctrl-C to quit.
        \\
    , .{});

    tap.run(); // CFRunLoopRun — blocks until Ctrl-C
}
