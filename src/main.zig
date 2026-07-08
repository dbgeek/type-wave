//! type-wave — entry point (wayfinder #19).
//!
//! A whisper-friendly, hold-to-talk dictation daemon for macOS: hold the Talk Key, speak,
//! release, and the transcript lands at the cursor of whatever app is focused. This file
//! is intentionally thin — it sets up the allocator/`std.Io` and hands off to `daemon.run`,
//! which owns the connection state machine, the Utterance lifecycle, and the self-healing
//! headless assembly. See `daemon.zig` for the design.

const std = @import("std");
const daemon = @import("daemon.zig");

// Force the __TEXT,__info_plist section (src/info_plist.zig) to be analysed and kept: it
// carries the daemon's stable bundle identity + mic usage string (wayfinder #15).
comptime {
    _ = &@import("info_plist.zig").info_plist;
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("type-wave — headless dictation daemon (wayfinder #19)\n\n", .{});
    try daemon.run(io, alloc);
}
