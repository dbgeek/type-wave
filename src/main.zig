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
const model_store = @import("model_store.zig");
const local_backend = @import("local_backend.zig");

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
        if (argv.len == 2 and std.mem.eql(u8, arg, "--set-hf-token")) return setHuggingFaceToken();
        if (argv.len == 2 and std.mem.eql(u8, arg, "--install-model")) {
            installModel(init.environ) catch |failure| {
                std.debug.print("--install-model: {s}\n", .{@errorName(failure)});
                std.process.exit(1);
            };
            return;
        }
        std.debug.print(
            \\usage: type-wave [--set-key | --set-hf-token | --install-model]
            \\
            \\  (no args)   run the dictation daemon
            \\  --set-key   read the OpenAI API key from stdin and store it in the login
            \\              keychain. Run via the installed signed binary
            \\              (~/.local/bin/type-wave) so the daemon reads it prompt-free.
            \\  --set-hf-token
            \\              read a Hugging Face token from stdin and store it in its own
            \\              login-Keychain item.
            \\  --install-model
            \\              explicitly acquire, verify, smoke-test, and atomically activate
            \\              the pinned KB Whisper Model Installation. HF_TOKEN overrides
            \\              Keychain for this foreground operation and is never persisted.
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
    try setSecret("OpenAI API key", keychain.account, keychain.storeKey);
}

fn setHuggingFaceToken() !void {
    try setSecret("Hugging Face token", keychain.hugging_face_account, keychain.storeHuggingFaceToken);
}

fn setSecret(
    display_name: []const u8,
    item_account: []const u8,
    store: *const fn ([]const u8) keychain.OSStatus,
) !void {
    const stdin_fd: std.posix.fd_t = 0;
    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);

    const tty = std.c.isatty(stdin_fd) != 0;
    const saved: ?std.posix.termios = if (tty) blk: {
        std.debug.print("Paste the {s} and press Enter (input hidden): ", .{display_name});
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
        std.debug.print("no secret on stdin — nothing stored.\n", .{});
        std.process.exit(1);
    }

    const st = store(key);
    if (st == keychain.errSecSuccess) {
        std.debug.print(
            "Stored in the login keychain (service \"{s}\", account \"{s}\").\n" ++
                "The credential remains separate from type-wave's other login-Keychain item.\n",
            .{ keychain.service, item_account },
        );
    } else {
        var msg: [256]u8 = undefined;
        std.debug.print("keychain store failed: {s}\n", .{keychain.describe(st, &msg)});
        std.process.exit(1);
    }
}

const HelperSmoke = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,

    pub fn run(self: *HelperSmoke, model: []const u8) ![32]u8 {
        try local_backend.smokeTest(self.allocator, self.io, self.executable, model);
        return model_store.sha256File(self.io, self.executable);
    }
};

fn installModel(environ: std.process.Environ) !void {
    const allocator = std.heap.c_allocator;
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    var helper_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const helper = try std.fmt.bufPrint(&helper_buffer, "{s}/.local/libexec/type-wave/type-wave-whisper", .{home});

    var owned_token: ?[:0]const u8 = null;
    defer if (owned_token) |token| {
        std.crypto.secureZero(u8, @constCast(token));
        allocator.free(token);
    };
    const token: []const u8 = environ.getPosix("HF_TOKEN") orelse token: {
        switch (keychain.readHuggingFaceToken(allocator)) {
            .key => |stored| {
                owned_token = stored;
                break :token stored;
            },
            .absent => return error.MissingHuggingFaceToken,
            .err => return error.HuggingFaceKeychainUnavailable,
        }
    };

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().access(io, helper, .{});

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var transport = model_store.HttpTransport{ .client = &client };
    var smoke = HelperSmoke{ .allocator = allocator, .io = io, .executable = helper };
    var operation = model_store.Operation(model_store.HttpTransport, HelperSmoke).init(
        allocator,
        io,
        root,
        model_store.pinned_manifest,
        &transport,
        &smoke,
    );

    std.debug.print("Model Operation: downloading pinned KB Whisper artifact ({d} bytes)\n", .{model_store.pinned_manifest.size});
    try operation.install(token);
    std.debug.print("Model Operation: verified, smoke-tested, and activated {s}@{s}\n", .{ model_store.pinned_manifest.repository, model_store.pinned_manifest.revision });
}
