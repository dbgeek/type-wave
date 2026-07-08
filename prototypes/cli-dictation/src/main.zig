//! THROWAWAY prototype shell (wayfinder ticket #8). Wires CoreAudio Capture to
//! an OpenAI Transcription Session and drives it from the terminal with ENTER
//! standing in for the real Talk Key. The portable halves are audio.zig and
//! session.zig; this shell is meant to be deleted once the question is answered.

const std = @import("std");
const audio = @import("audio.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;

extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn usleep(usec: c_uint) c_int;
// Quit by exiting the process: the OS reclaims the socket, so we never race the
// read-loop thread by closing its fd underneath it. A graceful websocket close
// (close frame + drain) is daemon work — see ticket #10.
extern "c" fn exit(code: c_int) noreturn;

fn audioSink(ctx: ?*anyopaque, pcm: []const u8) void {
    const s: *Session = @ptrCast(@alignCast(ctx.?));
    s.appendAudio(pcm);
}

/// Blocking read of one line from stdin (terminal is line-buffered).
fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const r = read(0, buf[n..].ptr, 1);
        if (r <= 0) break;
        if (buf[n] == '\n') break;
        n += 1;
    }
    return buf[0..n];
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

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const api_key_z = std.c.getenv("OPENAI_API_KEY") orelse {
        std.debug.print("OPENAI_API_KEY not set. Run inside `nix develop` (see issue #7).\n", .{});
        return error.NoApiKey;
    };
    const api_key = std.mem.span(api_key_z);

    std.debug.print("type-wave — CLI dictation prototype\n", .{});
    std.debug.print("connecting to wss://{s}/v1/realtime ...\n", .{session_mod.host});

    const session = try Session.connect(io, alloc, api_key);
    defer session.deinit();

    var handler = session_mod.Handler{ .session = session };
    const read_thread = try session.startReadLoop(&handler);
    defer read_thread.join();

    if (!waitFor(&session.ready, 10_000)) {
        std.debug.print("timed out waiting for session.updated — aborting.\n", .{});
        exit(1);
    }

    var capture = audio.Capture{};
    try capture.init();
    defer capture.deinit();
    capture.ctx = session;
    capture.on_chunk = audioSink;

    std.debug.print(
        \\
        \\Ready. ENTER stands in for the Talk Key:
        \\  ENTER to START an Utterance, speak, ENTER again to STOP.
        \\  The FIRST start pops a macOS microphone dialog for your terminal —
        \\  grant it, then start a fresh Utterance.
        \\  'q' then ENTER quits.
        \\
    , .{});

    var line: [64]u8 = undefined;
    while (true) {
        std.debug.print("\n[idle] ENTER=start  q=quit > ", .{});
        const l = readLine(&line);
        if (l.len >= 1 and (l[0] == 'q' or l[0] == 'Q')) {
            std.debug.print("bye.\n", .{});
            exit(0);
        }

        session.beginUtterance();
        try capture.start();
        std.debug.print("[REC ] speaking... ENTER to stop.\n", .{});
        _ = readLine(&line);
        capture.stop(); // synchronous; final buffers flush (and forward) during this call
        session.endUtterance(); // stop forwarding before committing
        session.commitUtterance() catch |e| std.debug.print("  commit error: {}\n", .{e});

        if (!capture.heardSound()) {
            std.debug.print("  (warning: only silence captured — mic permission denied? System Settings > Privacy & Security > Microphone)\n", .{});
        }

        if (!waitFor(&session.got_final, 15_000))
            std.debug.print("  (no transcript within 15s)\n", .{});
    }
}
