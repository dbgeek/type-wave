//! THROWAWAY spike shell (wayfinder ticket #9, "Prototype the hold-to-talk
//! insertion spike"). Observes the Talk Key globally and, on release, inserts a
//! canned string into whatever app has focus — the OS half of type-wave, with no
//! OpenAI in the loop. Right-Option → paste (primary); Left-Option → keystroke
//! (fallback), so both mechanisms can be A/B'd across apps in one run.
//!
//! The 400 ms paste runs on a worker thread, NOT in the tap callback: a slow
//! callback makes the OS disable the tap (crib sheet §6). The tap callback only
//! records the release edge and signals the worker.
//!
//! Delete or graduate once #9's question is answered — tap.zig and insert.zig are
//! the portable graduation candidates; this shell is scaffolding.

const std = @import("std");
const tapmod = @import("tap.zig");
const insertmod = @import("insert.zig");

extern "c" fn usleep(usec: c_uint) c_int;

// std.time lost milliTimestamp/Timer on this nightly (timing moved into std.Io);
// a monotonic clock for the "held N ms" diagnostic is a one-liner in C.
const timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
const CLOCK_MONOTONIC: c_int = 6; // macOS <time.h>

fn nowMs() i64 {
    var ts: timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

/// Identifiable, and deliberately Unicode-rich: ✅ (BMP), é (BMP), 😀 (a surrogate
/// pair — exercises the keystroke path's chunk-boundary guard).
const canned = "type-wave insertion spike ✅ — café 😀";

const Shell = struct {
    inserter: *insertmod.Inserter,
    utf8: [:0]const u8,
    utf16: []const u16,

    /// Set by the tap callback (run-loop thread), consumed by the worker.
    /// Insertions fire on human timescales, so a light poll beats threading a
    /// std.Io handle through the C callback just for a condvar.
    pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(req_none),
    press_ms: i64 = 0,

    const req_none: u8 = 0;
    const req_paste: u8 = 1;
    const req_keystroke: u8 = 2;

    // ---- tap callbacks (run on the run-loop thread; kept fast) ----

    fn onPress(ctx: ?*anyopaque, key: tapmod.TalkKey, keycode: i64, flags: u64) void {
        const self: *Shell = @ptrCast(@alignCast(ctx.?));
        self.press_ms = nowMs();
        const name = if (key == .right_option) "Right-Option -> paste" else "Left-Option -> keystroke";
        std.debug.print("[Talk Key v] {s}  (keycode 0x{X}, flags 0x{X})\n", .{ name, keycode, flags });
    }

    fn onRelease(ctx: ?*anyopaque, key: tapmod.TalkKey) void {
        const self: *Shell = @ptrCast(@alignCast(ctx.?));
        const held = nowMs() - self.press_ms;
        const mech: u8 = if (key == .right_option) req_paste else req_keystroke;
        std.debug.print("[Talk Key ^] held {d} ms -> inserting via {s}\n", .{ held, if (mech == req_paste) "paste" else "keystroke" });
        self.pending.store(mech, .release);
    }

    // ---- worker thread: performs the (slow) Insertion off the tap callback ----

    fn inserterLoop(self: *Shell) void {
        while (true) {
            const req = self.pending.swap(req_none, .acquire);
            if (req == req_none) {
                _ = usleep(5_000);
                continue;
            }
            secureHolderNote();
            const ok = switch (req) {
                req_paste => blk: {
                    self.inserter.paste(self.utf8.ptr) catch |e| {
                        std.debug.print("  paste failed: {s}\n", .{explain(e)});
                        break :blk false;
                    };
                    break :blk true;
                },
                req_keystroke => blk: {
                    self.inserter.keystroke(self.utf16) catch |e| {
                        std.debug.print("  keystroke failed: {s}\n", .{explain(e)});
                        break :blk false;
                    };
                    break :blk true;
                },
                else => false,
            };
            if (ok) std.debug.print("  posted via {s} — check whether the text landed in the focused app.\n", .{if (req == req_paste) "paste" else "keystroke"});
        }
    }
};

fn explain(e: insertmod.InsertError) []const u8 {
    return switch (e) {
        error.PostEventDenied => "no PostEvent grant — enable this terminal under System Settings > Privacy & Security > Accessibility, then re-run",
    };
}

/// If Secure Event Input is active, name who holds it (crib sheet §6). We still
/// attempt the insert — whether posting survives secure input is the open
/// question this spike is here to answer.
fn secureHolderNote() void {
    if (!insertmod.secureInputActive()) return;
    var buf: [256]u8 = undefined;
    if (insertmod.secureInputHolderPid()) |pid| {
        const name = insertmod.procName(pid, &buf);
        std.debug.print("  (!) Secure Event Input ACTIVE — held by {s} (pid {d}); posting anyway, watch whether it lands.\n", .{ if (name.len > 0) name else "unknown", pid });
    } else {
        std.debug.print("  (!) Secure Event Input ACTIVE — holder unknown; posting anyway, watch whether it lands.\n", .{});
    }
}

pub fn main() !void {
    std.debug.print("type-wave — insertion spike (wayfinder #9): the OS half, no OpenAI.\n\n", .{});

    // ---- TCC: request both grants up front, report status ----
    const listen_ok = tapmod.Tap.requestListenAccess();
    const post_ok = insertmod.requestPostEventAccess();
    std.debug.print("TCC status (attributed to THIS terminal for a CLI run):\n", .{});
    std.debug.print("  Input Monitoring  (Talk Key tap):   {s}\n", .{if (listen_ok) "granted" else "NOT granted"});
    std.debug.print("  PostEvent         (Insertion):      {s}\n", .{if (post_ok) "granted" else "NOT granted"});
    if (!listen_ok or !post_ok) {
        std.debug.print(
            \\
            \\Grant the missing permission(s) to this terminal, then re-run:
            \\  - Input Monitoring -> System Settings > Privacy & Security > Input Monitoring
            \\  - PostEvent        -> System Settings > Privacy & Security > Accessibility
            \\A prompt may have just appeared; if not, add the terminal by hand
            \\(use the + button and pick your terminal app).
            \\
        , .{});
    }
    if (insertmod.secureInputActive()) {
        var buf: [256]u8 = undefined;
        if (insertmod.secureInputHolderPid()) |pid| {
            const name = insertmod.procName(pid, &buf);
            std.debug.print(
                \\
                \\  (!) Secure Event Input is ACTIVE — held by {s} (pid {d}).
                \\      If that's your terminal, turn off its "Secure Keyboard Entry" for a
                \\      clean test. The spike posts anyway so we can see if it matters.
                \\
            , .{ if (name.len > 0) name else "unknown", pid });
        } else {
            std.debug.print("  (!) Secure Event Input is ACTIVE (holder unknown). The spike posts anyway.\n", .{});
        }
    }

    // ---- canned string -> UTF-16 for the keystroke path ----
    var utf16_buf: [256]u16 = undefined;
    const utf16_len = try std.unicode.utf8ToUtf16Le(&utf16_buf, canned);

    var inserter = insertmod.Inserter{};
    inserter.init();

    var shell = Shell{
        .inserter = &inserter,
        .utf8 = canned,
        .utf16 = utf16_buf[0..utf16_len],
    };

    const worker = try std.Thread.spawn(.{}, Shell.inserterLoop, .{&shell});
    worker.detach();

    var tap = tapmod.Tap{ .cbs = .{
        .ctx = &shell,
        .on_press = Shell.onPress,
        .on_release = Shell.onRelease,
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
        std.process.exit(1);
    };

    std.debug.print(
        \\
        \\Ready — observing globally (listen-only; the Option keys still work normally).
        \\Focus ANY app, then:
        \\  - HOLD Right-Option, release  -> PASTE the canned string   (primary)
        \\  - HOLD Left-Option,  release  -> KEYSTROKE the canned string (fallback)
        \\
        \\Test targets for #9: a terminal, a browser text field, Cursor, Notes.
        \\Heads-up: while this runs, EVERY Option tap inserts the canned string —
        \\that's expected here (the real daemon only inserts when a transcript exists).
        \\Canned string: "{s}"
        \\Ctrl-C to quit.
        \\
    , .{canned});

    tap.run(); // CFRunLoopRun — blocks until Ctrl-C
}
