//! main.zig — overlay HUD spike harness (wayfinder #20).
//!
//! Proves the two design questions end to end:
//!   Q1  A borderless, always-on-top NSPanel + streaming text, built purely from Zig
//!       through the ObjC runtime (see hud.zig).
//!   Q2  It floats over the Focused Target WITHOUT stealing focus — so keep typing in
//!       another app while the pill animates; if your keystrokes keep landing there,
//!       Insertion is safe.
//!
//! Threading mirrors the real daemon: a background thread stands in for the read-loop
//! thread that produces Partial Transcripts (session.zig), writing the latest text into
//! a mutex-guarded buffer; a **CFRunLoopTimer on the main thread** reads it and pokes the
//! HUD. The main thread runs **CFRunLoopRun()** — the very call src/tap.zig uses — so this
//! confirms the HUD composes with the tap's run loop rather than needing [NSApp run].

const std = @import("std");
const hud = @import("hud.zig");

const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn usleep(usec: c_uint) c_int;

// os_unfair_lock: zero-initializable macOS spinlock (libSystem). std.Thread.Mutex is
// gone on this Zig nightly and std.Io.Mutex needs an Io instance — this is the smallest
// correct guard for the producer/render handoff.
const os_unfair_lock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *os_unfair_lock) void;
extern "c" fn os_unfair_lock_unlock(lock: *os_unfair_lock) void;

// ---- NSApplication setup shims ----------------------------------------------
inline fn appMsg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
inline fn appMsgVoid(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op));
}
inline fn setActivationPolicy(app: id, policy: c_long) void {
    // Accessory (2): no Dock icon, no menu bar, and — crucially — the app does not
    // force-activate when it shows a window. Combined with the nonactivating panel and
    // orderFrontRegardless, nothing pulls focus off the Focused Target.
    const f: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(app, sel_registerName("setActivationPolicy:"), policy);
}
const NSApplicationActivationPolicyAccessory: c_long = 2;

// ---- CFRunLoopTimer render pump (main thread) -------------------------------
const CFRunLoopTimerRef = ?*anyopaque;
const CFRunLoopRef = ?*anyopaque;
const CFRunLoopTimerContext = extern struct {
    version: c_long = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
};
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddTimer(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: ?*anyopaque) void;
extern "c" fn CFRunLoopTimerCreate(
    alloc: ?*anyopaque,
    fireDate: f64,
    interval: f64,
    flags: c_ulong,
    order: c_long,
    callout: *const fn (CFRunLoopTimerRef, ?*anyopaque) callconv(.c) void,
    context: ?*CFRunLoopTimerContext,
) CFRunLoopTimerRef;
extern "c" fn CFRunLoopRun() void;
extern var kCFRunLoopCommonModes: ?*anyopaque;

fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// Stands in for the read-loop thread's Partial Transcript state. The producer thread
/// writes; the render pump reads. A mutex is plenty at this cadence.
const Shared = struct {
    mu: os_unfair_lock = .{},
    buf: [512]u8 = undefined,
    len: usize = 0,
    state: hud.State = .idle,

    fn set(self: *Shared, state: hud.State, text: []const u8) void {
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        self.state = state;
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }
    fn snapshot(self: *Shared, out: []u8) struct { state: hud.State, len: usize } {
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.buf[0..n]);
        return .{ .state = self.state, .len = n };
    }
};

const RenderCtx = struct { shared: *Shared, hud: *hud.Hud };

/// Runs on the main thread every ~50 ms: copy the latest partial out and render it.
/// An autorelease pool keeps the per-tick NSString/NSColor churn from piling up.
fn renderTick(_: CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const ctx: *RenderCtx = @ptrCast(@alignCast(info.?));
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    var zbuf: [513]u8 = undefined;
    const snap = ctx.shared.snapshot(zbuf[0..512]);
    zbuf[snap.len] = 0; // NUL-terminate for stringWithUTF8String:
    ctx.hud.setText(snap.state, zbuf[0..snap.len :0].ptr);
}

/// The fake dictation loop: idle → stream a phrase word-by-word (recording) → hold the
/// Final a beat → repeat. Same shape as a real Utterance so the HUD sees realistic input.
fn producer(shared: *Shared) void {
    const phrases = [_][]const u8{
        "let me refactor the session lifecycle",
        "wayfinder charts the whole effort as tickets",
        "hold right option and it transcribes at the cursor",
    };
    var i: usize = 0;
    while (true) {
        shared.set(.idle, "hold to talk");
        sleepMs(1400);

        const phrase = phrases[i % phrases.len];
        i += 1;

        // Reveal one more word every ~190 ms — the streaming Partial Transcript.
        var end: usize = 0;
        while (end < phrase.len) {
            var j = end;
            while (j < phrase.len and phrase[j] == ' ') j += 1;
            while (j < phrase.len and phrase[j] != ' ') j += 1;
            end = j;
            shared.set(.recording, phrase[0..end]);
            sleepMs(190);
        }
        sleepMs(350); // fully spoken, key still down

        shared.set(.final, phrase); // Final Transcript — the green flash before Insertion
        sleepMs(1100);
    }
}

pub fn main() void {
    const pool = objc_autoreleasePoolPush();

    // Shared, accessory-policy app: present UI, own no Dock icon, never force-activate.
    const app = appMsg(objc_getClass("NSApplication"), "sharedApplication");
    setActivationPolicy(app, NSApplicationActivationPolicyAccessory);
    // finishLaunching wires up AppKit enough to draw, WITHOUT [NSApp run] taking over the
    // loop — leaving CFRunLoopRun (below) to drive it, exactly like the daemon's tap.
    appMsgVoid(app, "finishLaunching");

    var h: hud.Hud = .{};
    h.init();

    var shared = Shared{};
    shared.set(.idle, "hold to talk");

    const worker = std.Thread.spawn(.{}, producer, .{&shared}) catch {
        std.debug.print("failed to spawn the partials producer thread\n", .{});
        return;
    };
    worker.detach();

    var ctx = RenderCtx{ .shared = &shared, .hud = &h };
    var timer_ctx = CFRunLoopTimerContext{ .info = &ctx };
    const timer = CFRunLoopTimerCreate(null, CFAbsoluteTimeGetCurrent() + 0.05, 0.05, 0, 0, renderTick, &timer_ctx);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);

    std.debug.print(
        \\
        \\Overlay HUD spike — a floating pill should appear at the bottom-centre of the
        \\main screen, cycling: charcoal "hold to talk" -> red streaming words -> green final.
        \\
        \\THE TEST (wayfinder #20, Q2): click into ANY app — a terminal, a browser field,
        \\Cursor — and keep typing. Your keystrokes must keep landing there while the pill
        \\animates. If focus never jumps to the pill, Insertion is safe.
        \\
        \\Also confirm: it floats above other windows, ignores clicks (click "through" it),
        \\and rides along when you switch Spaces / enter a full-screen app.
        \\
        \\Ctrl-C to quit.
        \\
    , .{});

    // Drop the setup pool: the panel/label/app are owned by the view hierarchy now.
    objc_autoreleasePoolPop(pool);

    CFRunLoopRun(); // the same call src/tap.zig makes — blocks until Ctrl-C
}
