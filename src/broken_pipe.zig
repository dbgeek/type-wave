//! The process-wide disposition for SIGPIPE: a pipe whose reader is gone is an **error at
//! the write**, never the end of the process.
//!
//! Every pipe this project writes into is one it also tears down deliberately. The
//! Coordinator's 10-second hard cancel kills the Whisper Helper precisely *because* that
//! closes the pipe and wakes a writer blocked mid-Segment (a Segment payload runs to roughly
//! 1.25 MiB against a 64 KiB pipe buffer, so the writer routinely is blocked), and the same
//! shape covers a helper that crashes mid-frame and a Model Operation child still narrating
//! into pipes the daemon has stopped draining. At SIGPIPE's default disposition the blocked
//! write's next syscall terminates the whole process instead — in place of the crash →
//! fail-active → backoff → relaunch ladder `whisper_process_helper.zig` already implements for
//! exactly this situation, and which only runs if the write is allowed to *return* its error.
//!
//! `std.Io.Threaded.init` happens to install a do-nothing SIGPIPE handler of its own, and both
//! binaries build one before their first pipe write, so today that accident is what keeps them
//! alive. It is an implementation detail of the pinned toolchain, and it is scoped: `deinit`
//! puts the *previous* disposition back, so any stretch outside a live `Threaded` runs at the
//! default action — as a Model Operation child's terminal `failed` event does, written after
//! its `Threaded` is gone. Owning the disposition here makes it unconditional and permanent:
//! installed before the first `Threaded` exists, it is also what every `deinit` restores.
//!
//! `ignore` is idempotent and thread-safe. Each entry point establishes it before it can reach
//! a pipe (`main.zig`, `whisper_helper.zig`), and `whisper_ipc.writeFd` re-asserts it at the
//! write itself so no future entry point can silently regress the IPC path. SIG_IGN survives
//! `execve`, so a helper the daemon spawns inherits it even before its own `main` runs; it
//! establishes the disposition anyway, because the helper is also runnable on its own.

const std = @import("std");

var established = std.atomic.Value(bool).init(false);

fn install() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &action, null);
}

/// Establish the disposition. Safe to call from anywhere, any number of times, on any thread:
/// the flag is a fast path off the write path, and two threads that race past it both install
/// the identical action, which is what `sigaction` already is — idempotent.
pub fn ignore() void {
    if (established.load(.acquire)) return;
    install();
    established.store(true, .release);
}

test "the disposition installed is ignore, not the default action of terminating" {
    // The test runner's own `std.Io.Threaded` owns SIGPIPE for the length of the run, so the
    // assertion borrows the disposition and hands it back. It is never parked at SIG_DFL on
    // the way: other tests leave detached threads writing into pipes behind them.
    var borrowed: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &borrowed);
    defer std.posix.sigaction(.PIPE, &borrowed, null);

    install();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &current);
    try std.testing.expectEqual(std.posix.SIG.IGN, current.handler.handler);
}
