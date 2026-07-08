//! type-wave — entry point (wayfinder #19).
//!
//! A whisper-friendly, hold-to-talk dictation daemon for macOS: hold the Talk Key, speak,
//! release, and the transcript lands at the cursor of whatever app is focused. This file
//! is intentionally thin — it sets up the allocator/`std.Io` and hands off to `daemon.run`,
//! which owns the connection state machine, the Utterance lifecycle, and the self-healing
//! headless assembly. See `daemon.zig` for the design.
//!
//! One subcommand: `type-wave --set-key` stores the OpenAI API key in the login keychain
//! (wayfinder #33). Run it via the *installed signed* binary (`~/.local/bin/type-wave`) —
//! the keychain item's ACL keys to its creator's code signature, so only then does the
//! daemon read it prompt-free. See keychain.zig.

const std = @import("std");
const daemon = @import("daemon.zig");
const keychain = @import("keychain.zig");

// Force the __TEXT,__info_plist section (src/info_plist.zig) to be analysed and kept: it
// carries the daemon's stable bundle identity + mic usage string (wayfinder #15).
comptime {
    _ = &@import("info_plist.zig").info_plist;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.c_allocator;

    const argv = init.args.vector;
    if (argv.len > 1) {
        const arg = std.mem.span(argv[1]);
        if (argv.len == 2 and std.mem.eql(u8, arg, "--set-key")) return setKey();
        std.debug.print(
            \\usage: type-wave [--set-key]
            \\
            \\  (no args)   run the dictation daemon
            \\  --set-key   read the OpenAI API key from stdin and store it in the login
            \\              keychain. Run via the installed signed binary
            \\              (~/.local/bin/type-wave) so the daemon reads it prompt-free.
            \\
        , .{});
        std.process.exit(2);
    }

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("type-wave — headless dictation daemon (wayfinder #19)\n\n", .{});
    try daemon.run(io, alloc);
}

/// `--set-key`: one line from stdin → keychain. Echo is suppressed on a terminal so the
/// secret doesn't land in the scrollback; piping (`echo "$KEY" | type-wave --set-key`)
/// works the same. The input buffer is zeroed before exit.
fn setKey() !void {
    const stdin_fd: std.posix.fd_t = 0;
    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);

    const tty = std.c.isatty(stdin_fd) != 0;
    const saved: ?std.posix.termios = if (tty) blk: {
        std.debug.print("Paste the OpenAI API key and press Enter (input hidden): ", .{});
        const old = std.posix.tcgetattr(stdin_fd) catch break :blk null;
        var raw = old;
        raw.lflag.ECHO = false;
        std.posix.tcsetattr(stdin_fd, .NOW, raw) catch break :blk null;
        break :blk old;
    } else null;

    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(stdin_fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, buf[total - n .. total], '\n') != null) break;
    }
    if (saved) |old| std.posix.tcsetattr(stdin_fd, .NOW, old) catch {};
    if (tty) std.debug.print("\n", .{});

    const line = if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |nl| buf[0..nl] else buf[0..total];
    const key = std.mem.trim(u8, line, " \t\r");
    if (key.len == 0) {
        std.debug.print("--set-key: no key on stdin — nothing stored.\n", .{});
        std.process.exit(1);
    }

    const st = keychain.storeKey(key);
    if (st == keychain.errSecSuccess) {
        std.debug.print(
            "Stored in the login keychain (service \"{s}\", account \"{s}\").\n" ++
                "The daemon picks it up within a few seconds — no restart needed.\n",
            .{ keychain.service, keychain.account },
        );
    } else {
        var msg: [256]u8 = undefined;
        std.debug.print("--set-key: keychain store failed: {s}\n", .{keychain.describe(st, &msg)});
        std.process.exit(1);
    }
}
