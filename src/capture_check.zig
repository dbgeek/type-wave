//! capture_check.zig — regression probe for Capture's start/stop cycle.
//!
//! Locks down the "dictation works once" bug (diagnosed 2026-07-08): AudioQueueStop's
//! implied reset strips the queue of its buffers (each in-callback re-enqueue fails
//! EnqueueDuringReset), so without `start` re-arming the queue, every Utterance after
//! the first records nothing. This probe cycles start → 1s → stop three times and
//! requires every round to deliver chunks.
//!
//! Run with `zig build capture-check` on a real machine — it performs live input IO
//! (TCC-visible; a denied Microphone grant still passes, since denial delivers
//! zero-filled chunks with noErr and the chunk count is the signal). Exit 0 = pass.

const std = @import("std");
const cap = @import("capture.zig");

extern "c" fn usleep(usec: c_uint) c_int;

var chunk_count = std.atomic.Value(u32).init(0);

fn sink(_: ?*anyopaque, pcm: []const u8) void {
    _ = pcm;
    _ = chunk_count.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var c = cap.Capture{};
    try c.init();
    defer c.deinit();
    c.on_chunk = sink;

    var failed = false;
    var round: usize = 1;
    while (round <= 3) : (round += 1) {
        chunk_count.store(0, .monotonic);
        try c.start();
        _ = usleep(1_000_000);
        c.stop();
        const n = chunk_count.load(.monotonic);
        std.debug.print("capture-check round {d}: {d} chunks, heardSound={}\n", .{ round, n, c.heardSound() });
        if (n == 0) failed = true;
    }
    if (failed) {
        std.debug.print("capture-check FAIL: a round delivered 0 chunks (the works-once bug is back)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("capture-check PASS: every round delivered chunks\n", .{});
}
