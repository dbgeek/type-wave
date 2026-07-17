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

extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) callconv(.c) usize;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
var g_model_cancel = std.atomic.Value(usize).init(0);

fn onModelCancel(_: c_int) callconv(.c) void {
    const address = g_model_cancel.load(.acquire);
    if (address != 0) {
        const requested: *std.atomic.Value(bool) = @ptrFromInt(address);
        requested.store(true, .release);
    }
}

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
        if (argv.len == 2 and (std.mem.eql(u8, arg, "--install-model") or std.mem.eql(u8, arg, "--update-model") or std.mem.eql(u8, arg, "--resume-model"))) {
            const resume_partial = std.mem.eql(u8, arg, "--resume-model");
            const update_only = std.mem.eql(u8, arg, "--update-model");
            installModel(init.environ, resume_partial, update_only) catch |failure| {
                std.debug.print("{s}: {s}\n", .{ arg, @errorName(failure) });
                std.process.exit(1);
            };
            return;
        }
        if (argv.len == 2 and std.mem.eql(u8, arg, "--discard-model")) return discardModel(init.environ);
        if (argv.len == 2 and std.mem.eql(u8, arg, "--remove-model")) return removeModel(init.environ);
        if (argv.len == 2 and std.mem.eql(u8, arg, "--forget-hf-token")) return forgetHuggingFaceToken(init.environ);
        if (argv.len == 2 and std.mem.eql(u8, arg, "--model-status")) return modelStatus(init.environ);
        if (argv.len == 2 and std.mem.eql(u8, arg, "--verify-model")) return verifyModel(init.environ);
        if (argv.len == 2 and std.mem.eql(u8, arg, "--repair-model")) return repairModel(init.environ);
        std.debug.print(
            \\usage: type-wave [--set-key | --set-hf-token | --install-model | --update-model | --resume-model | --discard-model | --remove-model | --forget-hf-token | --model-status | --verify-model | --repair-model]
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
            \\  --update-model
            \\              explicitly stage and validate the embedded replacement while
            \\              the working Model Installation remains available, then activate.
            \\  --resume-model
            \\              explicitly resume validator-matched paused model work.
            \\  --discard-model
            \\              discard paused model work without changing the active installation.
            \\  --remove-model
            \\              after confirmation, drain local dictation, unload the helper, and
            \\              remove the Model Installation and staged Model Operation data
            \\              without changing selection
            \\              or the Hugging Face token.
            \\  --forget-hf-token
            \\              cooperatively stop authenticated transfer, preserve resumable data,
            \\              and delete only the Hugging Face login-Keychain item.
            \\  --model-status
            \\              inspect paused model work without making a network request.
            \\  --verify-model
            \\              hash and verify the complete active Model Installation offline.
            \\  --repair-model
            \\              verify first, preserve valid data, and ask before authenticated
            \\              network acquisition of a missing or invalid artifact.
            \\
        , .{});
        std.process.exit(2);
    }

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    reportPausedModel(io, init.environ, false) catch |failure|
        std.debug.print("Model Operation recovery check: {s}\n", .{@errorName(failure)});

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

    pub fn run(self: *HelperSmoke, model: []const u8, cancel: *const model_store.CancelToken) ![32]u8 {
        if (cancel.isRequested()) return error.ModelOperationCancelled;
        try local_backend.smokeTest(self.allocator, self.io, self.executable, model, cancel.signalFlag());
        if (cancel.isRequested()) return error.ModelOperationCancelled;
        return model_store.sha256File(self.io, self.executable);
    }
};

fn installModel(environ: std.process.Environ, resume_partial: bool, update_only: bool) !void {
    const allocator = std.heap.c_allocator;
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    var helper_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const helper = try std.fmt.bufPrint(&helper_buffer, "{s}/.local/libexec/type-wave/type-wave-whisper", .{home});

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const update_available = try model_store.updateAvailable(io, root, model_store.pinned_manifest);
    if (update_only and !update_available) {
        std.debug.print("Model Installation: already matches the embedded identity; no update available.\n", .{});
        return;
    }

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
    operation.observer = .{ .ctx = &operation, .on_event = printModelEvent };
    g_model_cancel.store(@intFromPtr(operation.cancellationSignal()), .release);
    defer g_model_cancel.store(0, .release);
    _ = signal(SIGINT, onModelCancel);
    _ = signal(SIGTERM, onModelCancel);

    const recovery = try operation.recover();
    if (recovery.phase == .paused and !resume_partial) {
        std.debug.print(
            "Model Operation: paused at {d}/{d} bytes; choose --resume-model or --discard-model.\n",
            .{ recovery.bytes.completed, recovery.bytes.total },
        );
        return error.PartialRequiresExplicitResume;
    }
    if (resume_partial) {
        std.debug.print("Model Operation: explicitly resuming pinned KB Whisper artifact at {d}/{d} bytes\n", .{ recovery.bytes.completed, recovery.bytes.total });
        try operation.resumePartial(token);
    } else {
        if (update_available)
            std.debug.print("Model Operation: staging replacement beside the working Model Installation ({d} bytes)\n", .{model_store.pinned_manifest.size})
        else
            std.debug.print("Model Operation: downloading pinned KB Whisper artifact ({d} bytes)\n", .{model_store.pinned_manifest.size});
        try operation.install(token);
    }
    std.debug.print("Model Operation: verified, smoke-tested, and activated {s}@{s}\n", .{ model_store.pinned_manifest.repository, model_store.pinned_manifest.revision });
}

fn printModelEvent(_: *anyopaque, event: model_store.OperationEvent) void {
    switch (event) {
        .downloading => |bytes| std.debug.print("Model Operation: downloading {d}/{d} bytes\n", .{ bytes.completed, bytes.total }),
        .retrying => |retry| std.debug.print(
            "Model Operation: retry {d}/{d} in {d} ms at {d}/{d} bytes\n",
            .{ retry.attempt, retry.budget, retry.delay_ms, retry.bytes.completed, retry.bytes.total },
        ),
        .verifying => |bytes| std.debug.print("Model Operation: verifying {d}/{d} bytes\n", .{ bytes.completed, bytes.total }),
        .smoke_testing => std.debug.print("Model Operation: smoke testing\n", .{}),
        .waiting_for_inference => std.debug.print("Model Operation: waiting for active local inference to drain\n", .{}),
        .activating => std.debug.print("Model Operation: activating (cancellation deferred)\n", .{}),
        .removing => std.debug.print("Model Operation: removing the Model Installation and staged data\n", .{}),
    }
}

fn discardModel(environ: std.process.Environ) !void {
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    try model_store.discardIncomplete(io, root, model_store.pinned_manifest);
    std.debug.print("Model Operation: discarded paused work; active Model Installation unchanged.\n", .{});
}

const UnusedTransport = struct {};
const UnusedSmoke = struct {};

fn removeModel(environ: std.process.Environ) !void {
    if (!confirmModelRemoval()) return error.ModelRemovalNotConfirmed;
    const allocator = std.heap.c_allocator;
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var transport = UnusedTransport{};
    var smoke = UnusedSmoke{};
    var operation = model_store.Operation(UnusedTransport, UnusedSmoke).init(allocator, io, root, model_store.pinned_manifest, &transport, &smoke);
    operation.observer = .{ .ctx = &operation, .on_event = printModelEvent };
    g_model_cancel.store(@intFromPtr(operation.cancellationSignal()), .release);
    defer g_model_cancel.store(0, .release);
    _ = signal(SIGINT, onModelCancel);
    _ = signal(SIGTERM, onModelCancel);
    try operation.remove();
    std.debug.print("Model Installation: removed. Local remains selected when configured and is unavailable until Install. Hugging Face token preserved.\n", .{});
}

fn forgetHuggingFaceToken(environ: std.process.Environ) !void {
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try model_store.requestCredentialRevocation(io, root);
    std.debug.print("Hugging Face token: stopping any active authenticated Model Operation before forgetting it…\n", .{});
    var revocation = try model_store.finishCredentialRevocation(io, root);
    defer revocation.deinit();
    const status = keychain.deleteHuggingFaceToken();
    if (status != keychain.errSecSuccess and status != keychain.errSecItemNotFound) {
        var message: [256]u8 = undefined;
        std.debug.print("Hugging Face token: keychain delete failed: {s}\n", .{keychain.describe(status, &message)});
        return error.HuggingFaceKeychainUnavailable;
    }
    std.debug.print("Hugging Face token: forgotten. Installed and safely resumable model data retained.\n", .{});
}

fn modelStatus(environ: std.process.Environ) !void {
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    try reportPausedModel(threaded.io(), environ, true);
}

fn verifyModel(environ: std.process.Environ) !void {
    const allocator = std.heap.c_allocator;
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    var helper_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const helper = try std.fmt.bufPrint(&helper_buffer, "{s}/.local/libexec/type-wave/type-wave-whisper", .{home});
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var transport = model_store.HttpTransport{ .client = &client };
    var smoke = HelperSmoke{ .allocator = allocator, .io = io, .executable = helper };
    var operation = model_store.Operation(model_store.HttpTransport, HelperSmoke).init(allocator, io, root, model_store.pinned_manifest, &transport, &smoke);
    operation.additional_trusted_manifests = &model_store.trusted_manifests;
    operation.observer = .{ .ctx = &operation, .on_event = printModelEvent };
    try printIntegrity(try operation.verify());
}

fn repairModel(environ: std.process.Environ) !void {
    const allocator = std.heap.c_allocator;
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    var helper_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const helper = try std.fmt.bufPrint(&helper_buffer, "{s}/.local/libexec/type-wave/type-wave-whisper", .{home});
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var transport = model_store.HttpTransport{ .client = &client };
    var smoke = HelperSmoke{ .allocator = allocator, .io = io, .executable = helper };
    var operation = model_store.Operation(model_store.HttpTransport, HelperSmoke).init(allocator, io, root, model_store.pinned_manifest, &transport, &smoke);
    operation.additional_trusted_manifests = &model_store.trusted_manifests;
    operation.observer = .{ .ctx = &operation, .on_event = printModelEvent };

    const integrity = try operation.verify();
    switch (integrity) {
        .usable => {
            std.debug.print("Model Installation: usable; Repair preserved all valid data and used no network.\n", .{});
            return;
        },
        .absent => return error.NoModelInstallation,
        .corrupt => |reason| {
            std.debug.print("Model Installation: corrupt ({s}).\n", .{@tagName(reason)});
        },
    }

    operation.repair(null) catch |failure| switch (failure) {
        error.MissingHuggingFaceToken => {},
        else => return failure,
    };
    if ((try operation.verify()) == .usable) {
        std.debug.print("Model Installation: repaired valid local data offline; no network used.\n", .{});
        return;
    }

    if (!confirmRepairNetworkUse()) return error.ModelRepairNotConfirmed;
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
    try std.Io.Dir.cwd().access(io, helper, .{});
    try operation.repair(token);
    std.debug.print("Model Installation: repaired, verified, smoke-tested, and activated.\n", .{});
}

fn printIntegrity(integrity: model_store.InstallationIntegrity) !void {
    switch (integrity) {
        .absent => std.debug.print("Model Installation: absent.\n", .{}),
        .usable => |identity| std.debug.print("Model Installation: usable; verified {d} bytes, sha256={s}.\n", .{ identity.size, &std.fmt.bytesToHex(identity.sha256, .lower) }),
        .corrupt => |reason| std.debug.print("Model Installation: corrupt ({s}); Repair or Remove is required.\n", .{@tagName(reason)}),
    }
}

fn confirmRepairNetworkUse() bool {
    std.debug.print("Repair needs authenticated network access for invalid artifact data in the Model Installation. Continue? Type yes: ", .{});
    var buffer: [16]u8 = undefined;
    const count = std.posix.read(0, &buffer) catch return false;
    const answer = std.mem.trim(u8, buffer[0..count], " \t\r\n");
    return std.mem.eql(u8, answer, "yes");
}

fn confirmModelRemoval() bool {
    std.debug.print("Remove the local Model Installation and all staged Model Operation data? Local backend selection and Hugging Face token will be preserved. Type remove: ", .{});
    var buffer: [16]u8 = undefined;
    const count = std.posix.read(0, &buffer) catch return false;
    const answer = std.mem.trim(u8, buffer[0..count], " \t\r\n");
    return std.mem.eql(u8, answer, "remove");
}

fn reportPausedModel(io: std.Io, environ: std.process.Environ, show_idle: bool) !void {
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try model_store.rootPath(home, &root_buffer);
    const recovery = try model_store.recoveryState(io, root, model_store.pinned_manifest);
    if (recovery.phase == .paused) {
        std.debug.print(
            "Model Operation: paused at {d}/{d} bytes (no network activity); Resume: --resume-model; Discard: --discard-model.\n",
            .{ recovery.bytes.completed, recovery.bytes.total },
        );
    } else if (try model_store.updateAvailable(io, root, model_store.pinned_manifest)) {
        std.debug.print("Model Installation: update available; the working installation remains ready. Run --update-model to stage it explicitly.\n", .{});
    } else if (show_idle) {
        std.debug.print("Model Operation: no paused work.\n", .{});
    }
}
