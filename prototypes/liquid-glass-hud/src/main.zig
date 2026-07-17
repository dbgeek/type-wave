//! main.zig — Liquid Glass HUD spike harness (wayfinder #41 + #44). Throwaway.
//!
//! Wraps the proven waveform (#25: CALayer-per-bar, 20 Hz pump, implicit
//! anims off) in an NSGlassEffectView capsule and swaps the custom red/green
//! for system accent + semantic colors (#40). Every glass look axis is
//! switchable live from this terminal while the pill floats:
//!
//!   - glass style Regular/Clear, tint none/accent, corner radius
//!   - bar color accent/label/white
//!   - processing animation: accent dots / neutral dots / glass pulse
//!   - window shadow on/off, size, bar presets
//!
//! #44 adds the motion axes on top of #41's locked look:
//!
//!   - show/hide: pop (today) / fade / materialize
//!   - recording→processing: cut (today) / crossfade / morph / swell
//!   - a speed dial for slow-mo eyeballing, and a one-key full Utterance
//!     lifecycle demo (show → record → processing → hide)
//!
//! Threading mirrors the daemon (and #25's harness): producers push one level
//! per 50 ms into a lock-guarded queue; a CFRunLoopTimer on the main thread
//! (20 Hz — the daemon's rate, proven in #25) drains it and pokes the layers.

const std = @import("std");
const glass = @import("glass.zig");

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
// The #26 mapping: dBFS with a floor, −60 dB → flat, −10 dB → full bar. Map
// #39's fog flags this for possible retuning once bars sit on glass — react.
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
    mode: glass.Mode = .recording,
    source: Source = .talk,
    look: glass.Look = .{},
    look_dirty: bool = false,
    anim: glass.ProcessingAnim = .dots_neutral, // #44 verdict
    motion: glass.Motion = .{},
    demo_running: bool = false,

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
var g_pill: glass.Pill = .{};

// ---- synthetic voice: a speech-like envelope, one sample per 50 ms -------------
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
        const rate: f32 = if (self.target > self.level) 0.6 else 0.35;
        self.level += (self.target - self.level) * rate;
        return self.level * (0.85 + 0.3 * frand());
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

// ---- render pump (main thread, 20 Hz — the daemon's proven rate) ---------------
fn renderTick(_: CFRunLoopTimerRef, _: ?*anyopaque) callconv(.c) void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Snapshot + drain under the lock; never message ObjC while holding it.
    var levels: [128]f32 = undefined;
    os_unfair_lock_lock(&g_shared.mu);
    const n = g_shared.qlen;
    @memcpy(levels[0..n], g_shared.q[0..n]);
    g_shared.qlen = 0;
    const mode = g_shared.mode;
    const anim = g_shared.anim;
    const look = g_shared.look;
    const motion = g_shared.motion;
    const look_dirty = g_shared.look_dirty;
    g_shared.look_dirty = false;
    os_unfair_lock_unlock(&g_shared.mu);

    if (look_dirty) g_pill.applyLook(look);
    if (mode == .recording) for (levels[0..n]) |v| g_pill.pushLevel(v);
    g_pill.render(mode, anim, motion, CFAbsoluteTimeGetCurrent());
}

// ---- lifecycle demo: one full Utterance, so the motion reads as a whole --------
fn demoSeq() void {
    const steps = [_]struct { mode: glass.Mode, dwell_ms: u32 }{
        .{ .mode = .hidden, .dwell_ms = 600 }, // clear the stage first
        .{ .mode = .recording, .dwell_ms = 2500 }, // press: capsule appears, bars scroll
        .{ .mode = .processing, .dwell_ms = 1500 }, // release: held over Insertion
        .{ .mode = .hidden, .dwell_ms = 0 }, // resolution: capsule leaves
    };
    for (steps) |step| {
        os_unfair_lock_lock(&g_shared.mu);
        g_shared.mode = step.mode;
        os_unfair_lock_unlock(&g_shared.mu);
        if (step.dwell_ms > 0) _ = usleep(step.dwell_ms * 1000);
    }
    os_unfair_lock_lock(&g_shared.mu);
    g_shared.demo_running = false;
    os_unfair_lock_unlock(&g_shared.mu);
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
        "  [mode={s} voice={s} glass={s} tint={s} bars={s} radius={s} shadow={} pill={d:.0}x{d:.0} bar={d:.0}w/{d:.0}g({d}) processing={s} show={s} switch={s} speed={d:.1}]\n",
        .{
            @tagName(s.mode),          @tagName(s.source),        @tagName(s.look.style),
            @tagName(s.look.tint),     @tagName(s.look.bars),     @tagName(s.look.radius),
            s.look.shadow,             s.look.pill_w,             s.look.pill_h,
            s.look.bar_w,              s.look.bar_gap,            glass.barCount(s.look),
            @tagName(s.anim),          @tagName(s.motion.show),   @tagName(s.motion.switch_anim),
            s.motion.speed,
        },
    );
}

fn handle(ch: u8) void {
    os_unfair_lock_lock(&g_shared.mu);
    var s = &g_shared;
    var mic_on: ?bool = null;
    var start_demo = false;
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
        'g' => {
            s.look.style = switch (s.look.style) {
                .regular => .clear,
                .clear => .none, // bare: wavs + dots only, no capsule
                .none => .regular,
            };
            s.look_dirty = true;
        },
        'n' => {
            s.look.tint = switch (s.look.tint) {
                .none => .accent_soft,
                .accent_soft => .accent_strong,
                .accent_strong => .none,
            };
            s.look_dirty = true;
        },
        'c' => {
            s.look.bars = switch (s.look.bars) {
                .accent => .label,
                .label => .white,
                .white => .accent,
            };
            s.look_dirty = true;
        },
        'k' => {
            s.look.radius = switch (s.look.radius) {
                .capsule => .soft,
                .soft => .sdk_default,
                .sdk_default => .capsule,
            };
            s.look_dirty = true;
        },
        'x' => {
            s.look.shadow = !s.look.shadow;
            s.look_dirty = true;
        },
        '1', '2', '3' => {
            const p = bar_presets[ch - '1'];
            s.look.bar_w = p.w;
            s.look.bar_gap = p.gap;
            s.look_dirty = true;
        },
        'z' => {
            if (s.look.pill_w == 420) {
                s.look.pill_w = 340;
                s.look.pill_h = 52;
            } else if (s.look.pill_w == 340) {
                s.look.pill_w = 300;
                s.look.pill_h = 44;
            } else if (s.look.pill_h == 44) {
                s.look.pill_w = 300;
                s.look.pill_h = 22; // ultra-slim: a sliver of glass under the text
            } else {
                s.look.pill_w = 420;
                s.look.pill_h = 60;
            }
            s.look_dirty = true;
        },
        // Animations only differ while processing — jump there so it's visible.
        'd' => {
            s.anim = switch (s.anim) {
                .dots_accent => .dots_neutral,
                .dots_neutral => .glass_pulse,
                .glass_pulse => .dots_accent,
            };
            s.mode = .processing;
        },
        // ---- #44 motion axes -------------------------------------------------
        'a' => s.motion.show = switch (s.motion.show) {
            .pop => .fade,
            .fade => .materialize,
            .materialize => .pop,
        },
        'f' => s.motion.switch_anim = switch (s.motion.switch_anim) {
            .cut => .crossfade,
            .crossfade => .morph,
            .morph => .swell,
            .swell => .cut,
        },
        'u' => s.motion.speed = if (s.motion.speed == 1.0)
            2.5 // slow-mo, to see what the transition actually does
        else if (s.motion.speed == 2.5)
            0.7 // snappier than default
        else
            1.0,
        'j' => if (!s.demo_running) {
            s.demo_running = true;
            start_demo = true;
        },
        'q' => {
            os_unfair_lock_unlock(&g_shared.mu);
            std.process.exit(0);
        },
        else => {
            os_unfair_lock_unlock(&g_shared.mu);
            return;
        },
    }
    os_unfair_lock_unlock(&g_shared.mu);

    if (start_demo) {
        std.debug.print("  demo: one full Utterance — show, record ~2.5s, processing ~1.5s, hide\n", .{});
        const th = std.Thread.spawn(.{}, demoSeq, .{}) catch {
            os_unfair_lock_lock(&g_shared.mu);
            g_shared.demo_running = false;
            os_unfair_lock_unlock(&g_shared.mu);
            return;
        };
        th.detach();
    }
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
        std.debug.print("init failed (headless, or NSGlassEffectView missing) — nothing to prototype here\n", .{});
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

    const interval = 1.0 / 20.0;
    const timer = CFRunLoopTimerCreate(null, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, renderTick, null);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);

    std.debug.print(
        \\
        \\Liquid Glass HUD spike (wayfinder #41 + #44) — a glass capsule with a
        \\scrolling accent waveform should be at the bottom-centre of the screen.
        \\
        \\Commands (letter + Enter):
        \\  r  recording (scrolling waveform)      p  processing (post-release hold)
        \\  h  hide the pill                       t/w/s  synthetic voice: talk/whisper/silence
        \\  m  toggle LIVE microphone input        g  glass style: Regular / Clear / None
        \\                                            (None = bare wavs+dots, no capsule)
        \\  n  cycle glass tint (none / accent     c  cycle bar color (accent / label / white)
        \\     soft / accent strong)               k  cycle corner radius (capsule / 16 / 8)
        \\  d  cycle processing animation          x  toggle window shadow
        \\     (accent dots / neutral dots /       1/2/3  bars: fine / thin / medium
        \\     glass pulse)                        z  cycle size 420x60 / 340x52 / 300x44 / 300x22
        \\
        \\Motion (#44):
        \\  a  cycle show/hide (pop / fade /       f  cycle recording->processing (cut /
        \\     materialize)                           crossfade / morph / swell)
        \\  u  cycle speed 1.0 / 2.5 slow-mo /     j  demo one full Utterance lifecycle
        \\     0.7 snappy                             (show -> record -> processing -> hide)
        \\  q  quit
        \\
        \\React to the motion via j after picking a/f (u for slow-mo): how the capsule
        \\enters/leaves (a: r then h), and how bars hand over to dots (f: r then p).
        \\The #41 look verdict is the default look; glass_pulse ignores f (bars stay).
        \\
    , .{});
    printStatus();

    objc_autoreleasePoolPop(pool);
    CFRunLoopRun();
}
