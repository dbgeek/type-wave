//! main.zig — waveform HUD spike harness (wayfinder #25). Throwaway.
//!
//! Proves, end to end:
//!   Q1  A scrolling bar waveform + a green processing animation, rendered by a
//!       fixed row of CALayers poked from the render pump — purely via the ObjC
//!       runtime from Zig (wave.zig). No view subclass, no objc_allocateClassPair.
//!   Q1b Is the daemon's 20 Hz pump smooth enough, or does the rate (or CA's
//!       implicit animations) need to change? Toggle both live and compare.
//!   Look (HITL) — bar presets, colours, pill size, processing-animation style
//!       are all switchable from this terminal while the pill floats.
//!
//! Threading mirrors the daemon: producers (a synthetic voice envelope thread, or
//! the AudioQueue's own thread when the live mic tap is on) push one level per
//! 50 ms into a lock-guarded queue — the exact cadence of Capture's buffers. A
//! CFRunLoopTimer on the main thread (the render pump) drains it and pokes the
//! layers. Main thread runs CFRunLoopRun, same as src/tap.zig.

const std = @import("std");
const wave = @import("wave.zig");

const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn usleep(usec: c_uint) c_int;

const os_unfair_lock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *os_unfair_lock) void;
extern "c" fn os_unfair_lock_unlock(lock: *os_unfair_lock) void;

inline fn appMsg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
inline fn appMsgVoid(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op));
}
inline fn setActivationPolicy(app: id, policy: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(app, sel_registerName("setActivationPolicy:"), policy);
}
const NSApplicationActivationPolicyAccessory: c_long = 2;

// ---- CFRunLoop render pump ----------------------------------------------------
const CFRunLoopTimerRef = ?*anyopaque;
const CFRunLoopRef = ?*anyopaque;
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddTimer(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: ?*anyopaque) void;
extern "c" fn CFRunLoopTimerInvalidate(timer: CFRunLoopTimerRef) void;
extern "c" fn CFRunLoopTimerCreate(
    alloc: ?*anyopaque,
    fireDate: f64,
    interval: f64,
    flags: c_ulong,
    order: c_long,
    callout: *const fn (CFRunLoopTimerRef, ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) CFRunLoopTimerRef;
extern "c" fn CFRunLoopRun() void;
extern var kCFRunLoopCommonModes: ?*anyopaque;

// ---- level mapping: raw RMS -> bar height (0..1) -------------------------------
// THE knob ticket #26 decides for real. dBFS with a floor: −60 dB → 0 (flat),
// −10 dB → full bar. Linear amplitude would make whispers invisible; in dB a
// whisper (~−48..−34 dBFS) lands at 0.25–0.5 of the pill — visibly alive.
const floor_db: f32 = -60.0;
const ceil_db: f32 = -10.0;

fn levelToNorm(rms: f32) f32 {
    const db = 20.0 * @log10(@max(rms, 0.00001));
    return std.math.clamp((db - floor_db) / (ceil_db - floor_db), 0.0, 1.0);
}

// ---- shared state: producers + stdin write, render pump reads ------------------
const Source = enum { talk, whisper, silence, mic };

const Shared = struct {
    mu: os_unfair_lock = .{},
    q: [128]f32 = @splat(0),
    qlen: usize = 0,
    mode: wave.Mode = .recording,
    source: Source = .talk,
    look: wave.Look = .{},
    look_dirty: bool = false,
    variant: wave.AnimVariant = .wave,
    implicit: bool = false,
    pump_hz: f64 = 20,
    pump_dirty: bool = false,

    fn pushLevel(self: *Shared, v: f32) void {
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        if (self.qlen < self.q.len) {
            self.q[self.qlen] = v;
            self.qlen += 1;
        }
    }
};

var g_shared: Shared = .{};
var g_pill: wave.Pill = .{};

// ---- synthetic voice: a speech-like envelope, one sample per 50 ms -------------
// Syllable bursts with inter-word dips and occasional pauses, in LINEAR RMS so it
// exercises the same dB mapping the mic path uses. Ranges eyeballed from typical
// dictation: talk ≈ −34..−9 dBFS, whisper ≈ −48..−34, silence ≈ noise floor.
var rand_state: u64 = 0x2545F4914F6CDD1D;
fn frand() f32 {
    rand_state ^= rand_state << 13;
    rand_state ^= rand_state >> 7;
    rand_state ^= rand_state << 17;
    return @as(f32, @floatFromInt(rand_state >> 40)) / @as(f32, @floatFromInt(@as(u32, 1) << 24));
}

const Env = struct {
    level: f32 = 0.001,
    target: f32 = 0.001,
    ticks_left: u32 = 0,

    fn tick(self: *Env, lo: f32, hi: f32) f32 {
        if (self.ticks_left == 0) {
            if (frand() < 0.12) { // inter-word / breath pause
                self.target = lo * 0.3;
                self.ticks_left = 4 + @as(u32, @intFromFloat(frand() * 10));
            } else { // a syllable
                self.target = lo + frand() * (hi - lo);
                self.ticks_left = 2 + @as(u32, @intFromFloat(frand() * 5));
            }
        }
        self.ticks_left -= 1;
        const rate: f32 = if (self.target > self.level) 0.6 else 0.35; // fast attack, slower decay
        self.level += (self.target - self.level) * rate;
        return self.level * (0.85 + 0.3 * frand()); // per-sample jitter
    }
};

fn producer() void {
    var env: Env = .{};
    while (true) {
        _ = usleep(50 * 1000); // Capture's buffer cadence: one level per 50 ms
        os_unfair_lock_lock(&g_shared.mu);
        const src = g_shared.source;
        const mode = g_shared.mode;
        os_unfair_lock_unlock(&g_shared.mu);
        if (mode != .recording or src == .mic) continue;

        const rms: f32 = switch (src) {
            .talk => env.tick(0.02, 0.35),
            .whisper => env.tick(0.004, 0.018),
            .silence => 0.0004 + 0.0004 * frand(),
            .mic => unreachable,
        };
        g_shared.pushLevel(levelToNorm(rms));
    }
}

// ---- live mic tap: AudioQueue, trimmed from src/capture.zig ---------------------
const OSStatus = i32;
const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};
const AudioQueueRef = ?*opaque {};
const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: *anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?*anyopaque,
    mPacketDescriptionCount: u32,
};
const AudioQueueBufferRef = ?*AudioQueueBuffer;
const AudioTimeStamp = opaque {};
const AudioQueueInputCallback = *const fn (?*anyopaque, AudioQueueRef, AudioQueueBufferRef, *const AudioTimeStamp, u32, ?*anyopaque) callconv(.c) void;
extern "c" fn AudioQueueNewInput(inFormat: *const AudioStreamBasicDescription, inCallbackProc: AudioQueueInputCallback, inUserData: ?*anyopaque, inCallbackRunLoop: ?*anyopaque, inCallbackRunLoopMode: ?*anyopaque, inFlags: u32, outAQ: *AudioQueueRef) OSStatus;
extern "c" fn AudioQueueAllocateBuffer(inAQ: AudioQueueRef, inBufferByteSize: u32, outBuffer: *AudioQueueBufferRef) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(inAQ: AudioQueueRef, inBuffer: AudioQueueBufferRef, inNumPacketDescs: u32, inPacketDescs: ?*anyopaque) OSStatus;
extern "c" fn AudioQueueStart(inAQ: AudioQueueRef, inStartTime: ?*const AudioTimeStamp) OSStatus;
extern "c" fn AudioQueueStop(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;

var g_mic_queue: AudioQueueRef = null;
var g_mic_buffers: [3]AudioQueueBufferRef = @splat(null);
var g_mic_ready = false;

/// Audio queue's own thread. RMS over the 50 ms buffer -> the same dB mapping.
fn onMicBuffer(_: ?*anyopaque, queue: AudioQueueRef, buffer: AudioQueueBufferRef, _: *const AudioTimeStamp, _: u32, _: ?*anyopaque) callconv(.c) void {
    const b = buffer.?;
    const bytes: [*]const u8 = @ptrCast(b.mAudioData);
    const samples = std.mem.bytesAsSlice(i16, bytes[0..b.mAudioDataByteSize]);
    var acc: f64 = 0;
    for (samples) |s| {
        const x = @as(f64, @floatFromInt(s)) / 32768.0;
        acc += x * x;
    }
    if (samples.len > 0) {
        const rms: f32 = @floatCast(@sqrt(acc / @as(f64, @floatFromInt(samples.len))));
        os_unfair_lock_lock(&g_shared.mu);
        const wanted = g_shared.source == .mic and g_shared.mode == .recording;
        os_unfair_lock_unlock(&g_shared.mu);
        if (wanted) g_shared.pushLevel(levelToNorm(rms));
    }
    _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
}

fn micStart() bool {
    if (!g_mic_ready) {
        const format = AudioStreamBasicDescription{
            .mSampleRate = 24000,
            .mFormatID = 0x6C70636D, // 'lpcm'
            .mFormatFlags = (1 << 2) | (1 << 3), // signed int, packed
            .mBytesPerPacket = 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = 16,
        };
        if (AudioQueueNewInput(&format, onMicBuffer, null, null, null, 0, &g_mic_queue) != 0) return false;
        for (&g_mic_buffers) |*buf| {
            if (AudioQueueAllocateBuffer(g_mic_queue, 2400, buf) != 0) return false; // 50 ms @ 24 kHz s16
        }
        g_mic_ready = true;
    }
    for (g_mic_buffers) |buf| _ = AudioQueueEnqueueBuffer(g_mic_queue, buf, 0, null);
    return AudioQueueStart(g_mic_queue, null) == 0;
}

fn micStop() void {
    if (g_mic_ready) _ = AudioQueueStop(g_mic_queue, 1);
}

// ---- render pump (main thread) --------------------------------------------------
fn renderTick(timer: CFRunLoopTimerRef, _: ?*anyopaque) callconv(.c) void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Snapshot + drain under the lock; never message ObjC while holding it.
    var levels: [128]f32 = undefined;
    os_unfair_lock_lock(&g_shared.mu);
    const n = g_shared.qlen;
    @memcpy(levels[0..n], g_shared.q[0..n]);
    g_shared.qlen = 0;
    const mode = g_shared.mode;
    const variant = g_shared.variant;
    const implicit = g_shared.implicit;
    const look = g_shared.look;
    const look_dirty = g_shared.look_dirty;
    g_shared.look_dirty = false;
    const pump_dirty = g_shared.pump_dirty;
    const pump_hz = g_shared.pump_hz;
    g_shared.pump_dirty = false;
    os_unfair_lock_unlock(&g_shared.mu);

    if (look_dirty) g_pill.applyLook(look);
    if (mode == .recording) for (levels[0..n]) |v| g_pill.pushLevel(v);
    g_pill.render(mode, variant, implicit, CFAbsoluteTimeGetCurrent());

    // Rate switch: retire this timer and hand the pump to a fresh one.
    if (pump_dirty) {
        CFRunLoopTimerInvalidate(timer);
        addPumpTimer(pump_hz);
    }
}

fn addPumpTimer(hz: f64) void {
    const interval = 1.0 / hz;
    const timer = CFRunLoopTimerCreate(null, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, renderTick, null);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
}

// ---- stdin command driver --------------------------------------------------------
const bar_presets = [_]struct { name: []const u8, w: f64, gap: f64 }{
    .{ .name = "fine", .w = 3, .gap = 2 },
    .{ .name = "thin", .w = 4, .gap = 3 },
    .{ .name = "medium", .w = 6, .gap = 4 },
};

fn printStatus() void {
    os_unfair_lock_lock(&g_shared.mu);
    const s = g_shared;
    os_unfair_lock_unlock(&g_shared.mu);
    std.debug.print(
        "  [mode={s} voice={s} bars={d:.0}w/{d:.0}g({d}) scheme={s} pill={d:.0}x{d:.0} pump={d:.0}Hz implicit_anims={} processing_anim={s}]\n",
        .{
            @tagName(s.mode),          @tagName(s.source), s.look.bar_w,
            s.look.bar_gap,            wave.barCount(s.look), @tagName(s.look.scheme),
            s.look.pill_w,             s.look.pill_h,      s.pump_hz,
            s.implicit,                @tagName(s.variant),
        },
    );
}

fn handle(ch: u8) void {
    os_unfair_lock_lock(&g_shared.mu);
    var s = &g_shared;
    var mic_on: ?bool = null;
    switch (ch) {
        'r' => s.mode = .recording,
        'p' => s.mode = .processing,
        'h' => s.mode = .hidden,
        't' => s.source = .talk,
        'w' => s.source = .whisper,
        's' => s.source = .silence,
        'm' => {
            if (s.source == .mic) {
                s.source = .talk;
                mic_on = false;
            } else {
                s.source = .mic;
                mic_on = true;
            }
        },
        '1', '2', '3' => {
            const p = bar_presets[ch - '1'];
            s.look.bar_w = p.w;
            s.look.bar_gap = p.gap;
            s.look_dirty = true;
        },
        'c' => {
            s.look.scheme = switch (s.look.scheme) {
                .transparent_tinted_bars => .red_pill_white_bars,
                .red_pill_white_bars => .dark_pill_tinted_bars,
                .dark_pill_tinted_bars => .transparent_tinted_bars,
            };
            s.look_dirty = true;
        },
        'z' => {
            if (s.look.pill_w == 250) {
                s.look.pill_w = 300;
                s.look.pill_h = 48;
            } else if (s.look.pill_w == 300) {
                s.look.pill_w = 420;
                s.look.pill_h = 60;
            } else {
                s.look.pill_w = 250;
                s.look.pill_h = 38;
            }
            s.look_dirty = true;
        },
        'd' => s.variant = switch (s.variant) {
            .wave => .dots,
            .dots => .breathe,
            .breathe => .wave,
        },
        'f' => s.pump_hz = if (s.pump_hz == 20) 30 else if (s.pump_hz == 30) 60 else 20,
        'a' => s.implicit = !s.implicit,
        'q' => {
            os_unfair_lock_unlock(&g_shared.mu);
            std.process.exit(0);
        },
        else => {
            os_unfair_lock_unlock(&g_shared.mu);
            return;
        },
    }
    if (ch == 'f') s.pump_dirty = true;
    os_unfair_lock_unlock(&g_shared.mu);

    if (mic_on) |on| {
        if (on) {
            if (!micStart()) {
                std.debug.print("  mic tap failed to start (AudioQueue error)\n", .{});
                os_unfair_lock_lock(&g_shared.mu);
                g_shared.source = .talk;
                os_unfair_lock_unlock(&g_shared.mu);
            } else {
                std.debug.print("  mic ON — first use prompts for Microphone access (attributed to this terminal)\n", .{});
            }
        } else {
            micStop();
        }
    }
    printStatus();
}

fn stdinLoop() void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(0, &buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |ch| handle(ch);
    }
}

pub fn main() void {
    const pool = objc_autoreleasePoolPush();

    const app = appMsg(objc_getClass("NSApplication"), "sharedApplication");
    setActivationPolicy(app, NSApplicationActivationPolicyAccessory);
    appMsgVoid(app, "finishLaunching");

    if (!g_pill.init(g_shared.look)) {
        std.debug.print("no display ([NSScreen mainScreen] is nil) — nothing to prototype here\n", .{});
        return;
    }

    const worker = std.Thread.spawn(.{}, producer, .{}) catch {
        std.debug.print("failed to spawn the synthetic-voice thread\n", .{});
        return;
    };
    worker.detach();
    const stdin_thread = std.Thread.spawn(.{}, stdinLoop, .{}) catch {
        std.debug.print("failed to spawn the stdin thread\n", .{});
        return;
    };
    stdin_thread.detach();

    addPumpTimer(20);

    std.debug.print(
        \\
        \\Waveform HUD spike (wayfinder #25) — a small transparent scrolling waveform
        \\should be at the bottom-centre of the screen, fed by a synthetic "talking" voice.
        \\
        \\Commands (letter + Enter):
        \\  r  recording (scrolling waveform)      p  processing (green, post-release)
        \\  h  hide the pill                       t/w/s  synthetic voice: talk/whisper/silence
        \\  m  toggle LIVE microphone input        1/2/3  bars: fine / thin / medium
        \\  c  cycle scheme (transparent /         z  cycle size 250x38 / 300x48 / 420x60
        \\     red pill / dark pill)               f  cycle render pump 20 -> 30 -> 60 Hz
        \\  d  cycle processing animation          a  toggle CA implicit animations
        \\     (wave / dots / breathe)             q  quit
        \\
        \\React to: whisper visibility (w — bars must visibly move), scroll feel at 20 Hz
        \\vs 60 Hz (f) and with implicit animations (a), and which processing look wins (d).
        \\
    , .{});
    printStatus();

    objc_autoreleasePoolPop(pool);
    CFRunLoopRun();
}
