//! main.zig — Metal HUD spike (wayfinder #356, map #355). Throwaway.
//!
//! Proves, end to end and purely through the ObjC runtime C API from Zig:
//!   - MTLCreateSystemDefaultDevice + a runtime MSL compile of the HUD SDF shader
//!     (src/hud.metal, ported from prototypes/hud-micro-motion) into a render pipeline;
//!   - a transparent CAMetalLayer on the daemon's exact nonactivating-panel recipe,
//!     composited premultiplied over whatever is behind it;
//!   - display-rate pacing, two ways: NSScreen's CADisplayLink (macOS 14+, a runtime
//!     target class as in src/menu.zig) vs a 120 Hz CFRunLoopTimer — both started and
//!     stopped with the pill so a hidden pill costs nothing;
//!   - the per-frame CPU cost of building the scene + encoding the pass.
//!
//! The scene is a subset of the prototype's track B: glide scroll, organic newest bar,
//! loudness opacity, edge dissolve, silence ripple, unfurl, gather into dots, squash &
//! stretch — goo Always at 5 pt, glow 0.75 (the locked values).
//!
//! Main thread runs CFRunLoopRun, same as the daemon (src/tap.zig). Commands arrive on
//! stdin through a CFFileDescriptor source, so everything stays on that one thread.
//!
//!   zig build run                      interactive (commands below)
//!   HUD_SPIKE_BENCH=1 zig build run    scripted pacing/cost run, prints stats, exits

const std = @import("std");

// ---- ObjC runtime -----------------------------------------------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn objc_allocateClassPair(superclass: id, name: [*:0]const u8, extra: usize) id;
extern "c" fn objc_registerClassPair(c: id) void;
extern "c" fn class_addMethod(c: id, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

// ---- C frameworks -------------------------------------------------------------------
extern "c" fn MTLCreateSystemDefaultDevice() id;
extern "c" fn CACurrentMediaTime() f64;
extern "c" fn clock() c_ulong; // process CPU time, µs on macOS (CLOCKS_PER_SEC = 1e6)
extern var NSRunLoopCommonModes: id;

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}
inline fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

// ---- typed objc_msgSend shims, one per argument shape --------------------------------
inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel(op));
}
inline fn msgv(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op));
}
inline fn msg1(self: id, op: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel(op), a);
}
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op), a);
}
inline fn msgBool(self: id, op: [*:0]const u8, b: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op), b);
}
inline fn msgLong(self: id, op: [*:0]const u8, n: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op), n);
}
inline fn msgULong(self: id, op: [*:0]const u8, n: c_ulong) void {
    const f: *const fn (id, SEL, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op), n);
}
inline fn msgIdx(self: id, op: [*:0]const u8, n: c_ulong) id {
    const f: *const fn (id, SEL, c_ulong) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel(op), n);
}
inline fn msgDouble(self: id, op: [*:0]const u8, x: f64) void {
    const f: *const fn (id, SEL, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op), x);
}
inline fn msgF64(self: id, op: [*:0]const u8) f64 {
    const f: *const fn (id, SEL) callconv(.c) f64 = @ptrCast(&objc_msgSend);
    return f(self, sel(op));
}

const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const CGSize = extern struct { w: f64, h: f64 };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const CAFrameRateRange = extern struct { minimum: f32, maximum: f32, preferred: f32 };

inline fn msgRect(self: id, op: [*:0]const u8, r: NSRect) void {
    const f: *const fn (id, SEL, NSRect) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel(op), r);
}
inline fn msgRetRect(self: id, op: [*:0]const u8) NSRect {
    const f: *const fn (id, SEL) callconv(.c) NSRect = @ptrCast(&objc_msgSend);
    return f(self, sel(op));
}
inline fn nsString(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSString"), sel("stringWithUTF8String:"), s);
}
fn describe(err: id) [*:0]const u8 {
    if (err == null) return "(no NSError)";
    const f: *const fn (id, SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc_msgSend);
    return f(msg(err, "localizedDescription"), sel("UTF8String"));
}

// ---- AppKit / window constants (same recipe as src/hud.zig) --------------------------
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskNonactivatingPanel: c_ulong = 1 << 7;
const NSBackingStoreBuffered: c_ulong = 2;
const NSStatusWindowLevel: c_long = 25;
const NSWindowCollectionBehaviorCanJoinAllSpaces: c_ulong = 1 << 0;
const NSWindowCollectionBehaviorStationary: c_ulong = 1 << 4;
const NSWindowCollectionBehaviorFullScreenAuxiliary: c_ulong = 1 << 8;

// ---- Metal constants ---------------------------------------------------------------
const MTLPixelFormatBGRA8Unorm: c_ulong = 80;
const MTLLoadActionClear: c_ulong = 2;
const MTLStoreActionStore: c_ulong = 1;
const MTLPrimitiveTypeTriangle: c_ulong = 3;

// ---- CoreFoundation run loop -------------------------------------------------------
const CFRef = ?*anyopaque;
extern "c" fn CFRunLoopGetCurrent() CFRef;
extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRunLoopAddTimer(rl: CFRef, timer: CFRef, mode: CFRef) void;
extern "c" fn CFRunLoopAddSource(rl: CFRef, source: CFRef, mode: CFRef) void;
extern "c" fn CFRunLoopTimerInvalidate(timer: CFRef) void;
extern "c" fn CFRelease(obj: CFRef) void;
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" fn CFRunLoopTimerCreate(
    alloc: CFRef,
    fireDate: f64,
    interval: f64,
    flags: c_ulong,
    order: c_long,
    callout: *const fn (CFRef, ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) CFRef;
extern "c" fn CFFileDescriptorCreate(
    alloc: CFRef,
    fd: c_int,
    closeOnInvalidate: u8,
    callout: *const fn (CFRef, c_ulong, ?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) CFRef;
extern "c" fn CFFileDescriptorEnableCallBacks(f: CFRef, types: c_ulong) void;
extern "c" fn CFFileDescriptorCreateRunLoopSource(alloc: CFRef, f: CFRef, order: c_long) CFRef;
extern var kCFRunLoopCommonModes: CFRef;
const kCFFileDescriptorReadCallBack: c_ulong = 1;

// ============================================================================
// The scene — a subset of prototypes/hud-micro-motion's engine (track B)
// ============================================================================
const pill_w: f64 = 300;
const pill_h: f64 = 22;
const bar_w: f64 = 6;
const bar_gap: f64 = 4;
const pad_x: f64 = 20;
const min_bar_h: f64 = 3;
const max_bar_h: f64 = pill_h * 0.72;
const slot: f64 = bar_w + bar_gap;
const n_bars: usize = @intFromFloat(@floor((pill_w - 2 * pad_x + bar_gap) / slot)); // 26
const row_w: f64 = @as(f64, @floatFromInt(n_bars)) * slot - bar_gap;
const x0: f64 = (pill_w - row_w) / 2.0;
const dot_size: f64 = @min(12.0, pill_h * 0.4);
const dot_gap: f64 = dot_size * (10.0 / 12.0);
const dot_bounce: f64 = @min(11.0, (pill_h - dot_size) / 2.0 - 1.0);
const dots_row_w: f64 = 3 * dot_size + 2 * dot_gap;
const cy: f64 = pill_h / 2;
const cx_mid: f64 = pill_w / 2;

// The drawing region: the pill plus room for spring overshoot and glow.
const region_w: f64 = 340;
const region_h: f64 = 50;
const ox: f64 = (region_w - pill_w) / 2;
const oy: f64 = (region_h - pill_h) / 2;

const sample_dt: f64 = 0.05; // one level per 50 ms Capture buffer
const goo_k: f32 = 5.0; // locked: Always, 5 pt
const glow_strength: f32 = 0.75; // locked

fn barCX(i: f64) f64 {
    return x0 + i * slot + bar_w / 2;
}
fn dotCX(j: f64) f64 {
    return (pill_w - dots_row_w) / 2 + j * (dot_size + dot_gap) + dot_size / 2;
}
fn clamp01(x: f64) f64 {
    return std.math.clamp(x, 0.0, 1.0);
}
fn lerp(a: f64, b: f64, f: f64) f64 {
    return a + (b - a) * f;
}
fn smoothstep(e0: f64, e1: f64, x: f64) f64 {
    const t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3 - 2 * t);
}
fn springOut(p: f64) f64 {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    return 1 - @exp(-6 * p) * @cos(9 * p);
}
fn backOut(p0: f64) f64 {
    const s = 1.7;
    const p = clamp01(p0) - 1;
    return 1 + (s + 1) * p * p * p + s * p * p;
}
/// hud.zig's easeOut, cubic-bezier(0.17, 0.7, 0.3, 1), solved by Newton iteration.
fn ease(x: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    const c_x = 3 * 0.17;
    const b_x = 3 * (0.3 - 0.17) - c_x;
    const a_x = 1 - c_x - b_x;
    const c_y = 3 * 0.7;
    const b_y = 3 * (1.0 - 0.7) - c_y;
    const a_y = 1 - c_y - b_y;
    var t = x;
    for (0..8) |_| {
        const e = ((a_x * t + b_x) * t + c_x) * t - x;
        const d = (3 * a_x * t + 2 * b_x) * t + c_x;
        if (@abs(e) < 1e-6 or @abs(d) < 1e-6) break;
        t -= e / d;
    }
    t = clamp01(t);
    return ((a_y * t + b_y) * t + c_y) * t;
}
fn levelToNorm(rms: f64) f64 {
    const db = 20.0 * @log10(@max(rms, 0.00001));
    return clamp01((db + 60.0) / 50.0);
}

const Role = enum { label, secondary };
const Prim = struct { cx: f64, cy: f64, w: f64, h: f64, a: f64, role: Role };
const Bar = struct { i: f64, cx: f64, w: f64, h: f64, a: f64 };

// Synthetic voice: words of syllables with gaps (the prototype's envelope), in linear RMS.
const Voice = struct {
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x7a11),
    whisper: bool = false,
    in_word: bool = false,
    until: f64 = 0,
    word_start: f64 = 0,
    peak: f64 = -30,
    rate: f64 = 5,

    fn rnd(self: *Voice) f64 {
        return self.prng.random().float(f64);
    }
    fn sample(self: *Voice, t: f64) f64 {
        if (t >= self.until) {
            if (self.in_word) {
                self.in_word = false;
                self.until = t + 0.06 + self.rnd() * (if (self.rnd() < 0.2) @as(f64, 0.4) else 0.15);
            } else {
                self.in_word = true;
                self.word_start = t;
                self.until = t + 0.22 + self.rnd() * 0.5;
                self.peak = if (self.whisper) -44 + self.rnd() * 8 else -26 + self.rnd() * 12;
                self.rate = 4 + self.rnd() * 2.5;
            }
        }
        if (!self.in_word) return std.math.pow(f64, 10, ((if (self.whisper) @as(f64, -64) else -58) + self.rnd() * 4) / 20);
        const syl = std.math.pow(f64, @abs(@sin(std.math.pi * self.rate * (t - self.word_start))), 0.6);
        return std.math.pow(f64, 10, (self.peak - (1 - syl) * 18 + (self.rnd() - 0.5) * 3) / 20);
    }
};

const Scene = struct {
    mode: enum { bars, dots } = .bars,
    hist: [n_bars + 1]f64 = @splat(0), // hist[n_bars] newest; hist[0] the bar scrolling off
    env: f64 = 0,
    shift_at: f64 = -1e9,
    next_sample: f64 = 0,
    show_at: f64 = -1e9,
    release_at: f64 = -1e9,
    snap: [n_bars + 1]Bar = undefined,
    voice: Voice = .{},

    fn startBars(self: *Scene, t: f64) void {
        self.mode = .bars;
        self.hist = @splat(0);
        self.env = 0;
        self.shift_at = -1e9;
        self.next_sample = t + sample_dt;
        self.show_at = t;
        self.release_at = -1e9;
    }
    fn startDots(self: *Scene, t: f64) void {
        if (self.mode == .dots) return;
        self.snap = self.bars(t);
        self.mode = .dots;
        self.release_at = t;
    }

    /// Drain every Capture buffer due by `t`: one sample shifts the scroll one slot.
    fn advance(self: *Scene, t: f64) void {
        if (self.mode != .bars) return;
        if (t - self.next_sample > 1.0) self.next_sample = t; // after a long hide
        while (t >= self.next_sample) : (self.next_sample += sample_dt) {
            var n = levelToNorm(self.voice.sample(self.next_sample));
            self.env = if (n >= self.env) n else self.env + (n - self.env) * 0.5; // organic envelope
            n = self.env;
            std.mem.copyForwards(f64, self.hist[0..n_bars], self.hist[1..]);
            self.hist[n_bars] = n;
            self.shift_at = self.next_sample;
        }
    }

    fn bars(self: *const Scene, t: f64) [n_bars + 1]Bar {
        var out: [n_bars + 1]Bar = undefined;
        const p = clamp01((t - self.shift_at) / sample_dt);
        const glide = slot * (1 - p);
        for (&out, 0..) |*b, k| {
            const i = @as(f64, @floatFromInt(k)) - 1;
            var norm = self.hist[k];
            if (k == n_bars) norm *= backOut((t - self.shift_at) / 0.09); // newest springs in
            var h = min_bar_h + @max(0, norm) * (max_bar_h - min_bar_h);
            const quiet = 1 - smoothstep(0.02, 0.10, norm); // listening ripple in silence
            h += 1.6 * quiet * smoothstep(0.15, 0.5, t - self.show_at) * (0.5 + 0.5 * @sin(2 * std.math.pi * 1.2 * t - i * 0.55));
            var w = bar_w;
            var a: f64 = 1;
            const cx = barCX(i) + glide;
            if (k == 0) a *= 1 - p; // the bar scrolling off
            a *= 0.42 + 0.58 * std.math.pow(f64, clamp01(norm), 0.6); // loudness opacity
            a *= smoothstep(x0 - 4, x0 + 64, cx) * (1 - smoothstep(x0 + row_w - bar_w / 2, x0 + row_w + slot, cx)); // edge dissolve
            const q = clamp01((t - self.show_at - @abs(i - (@as(f64, n_bars) - 1) / 2) * 0.009) / 0.26); // unfurl
            const s = springOut(q);
            w *= s;
            h *= s;
            a *= clamp01(q * 3);
            b.* = .{ .i = i, .cx = cx, .w = w, .h = h, .a = a };
        }
        return out;
    }

    /// Everything drawn at `t`, into `buf`; returns the live count.
    fn prims(self: *const Scene, t: f64, buf: []Prim) usize {
        var n: usize = 0;
        switch (self.mode) {
            .bars => for (self.bars(t)) |b| {
                buf[n] = .{ .cx = b.cx, .cy = cy, .w = b.w, .h = b.h, .a = b.a, .role = .label };
                n += 1;
            },
            .dots => {
                const tr = t - self.release_at;
                if (tr < 0.5) for (self.snap) |b| { // gather bars into the dots
                    const j = @min(2.0, @max(0.0, @floor(b.i * 3 / @as(f64, n_bars))));
                    const dist = @abs(b.cx - dotCX(j));
                    const p = ease(clamp01(tr / (0.15 + 0.15 * @min(1, dist / 100))));
                    buf[n] = .{ .cx = lerp(b.cx, dotCX(j), p), .cy = cy, .w = lerp(b.w, dot_size * 0.7, p), .h = lerp(b.h, dot_size * 0.7, p), .a = b.a * (1 - smoothstep(0.5, 1, p)), .role = .label };
                    n += 1;
                };
                const q = clamp01((tr - 0.10) / 0.22);
                const appear_s = @max(0, backOut(q));
                const appear_a = clamp01(q * 2.5);
                const amp = dot_bounce * smoothstep(0.18, 0.55, tr);
                for (0..3) |jj| {
                    const j: f64 = @floatFromInt(jj);
                    const ph = t * 5 + j * 0.8;
                    const k = amp / dot_bounce;
                    const sv = @abs(@sin(ph));
                    const cv = @abs(@cos(ph));
                    buf[n] = .{
                        .cx = dotCX(j),
                        .cy = cy + amp * @sin(ph),
                        .w = dot_size * (1 - k * (0.07 * cv - 0.08 * sv)) * appear_s, // squash & stretch
                        .h = dot_size * (1 + k * (0.14 * cv - 0.08 * sv)) * appear_s,
                        .a = appear_a,
                        .role = .secondary,
                    };
                    n += 1;
                }
            },
        }
        // pill-level unfurl spring
        const gs = 0.93 + 0.07 * springOut(clamp01((t - self.show_at) / 0.4));
        for (buf[0..n]) |*p| {
            p.cx = cx_mid + (p.cx - cx_mid) * gs;
            p.cy = cy + (p.cy - cy) * gs;
            p.w *= gs;
            p.h *= gs;
        }
        return n;
    }
};

// ============================================================================
// Metal
// ============================================================================
const max_prims = 48;
/// Byte-for-byte the `U` struct in hud.metal.
const Uniforms = extern struct {
    res: [2]f32,
    px: f32,
    count: i32,
    k: f32,
    glow: f32,
    _pad: [2]f32 = .{ 0, 0 },
    geo: [max_prims][4]f32,
    col: [max_prims][4]f32,
    fade: [max_prims]f32,
};
comptime {
    std.debug.assert(@sizeOf(Uniforms) == 1760); // setFragmentBytes limit is 4096
    std.debug.assert(@offsetOf(Uniforms, "geo") == 32);
}

const msl_source = @embedFile("hud.metal");

const Gpu = struct {
    device: id = null,
    queue: id = null,
    pipeline: id = null,
    layer: id = null,
    scale: f64 = 2,
};

/// A semantic NSColor resolved to straight sRGB components against the current
/// appearance — the per-frame counterpart of hud.zig's `systemColor` + `cgColor`.
fn srgb(name: [*:0]const u8) [4]f32 {
    const dynamic = msg(cls("NSColor"), name);
    const c = msg1(dynamic, "colorUsingColorSpace:", msg(cls("NSColorSpace"), "sRGBColorSpace"));
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    var a: f64 = 0;
    const f: *const fn (id, SEL, *f64, *f64, *f64, *f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(c, sel("getRed:green:blue:alpha:"), &r, &g, &b, &a);
    return .{ @floatCast(r), @floatCast(g), @floatCast(b), @floatCast(a) };
}

fn initMetal(gpu: *Gpu, scale: f64) bool {
    gpu.device = MTLCreateSystemDefaultDevice();
    if (gpu.device == null) {
        std.debug.print("FAIL: no Metal device\n", .{});
        return false;
    }
    gpu.queue = msg(gpu.device, "newCommandQueue");

    const t0 = CACurrentMediaTime();
    var err: id = null;
    const newLib: *const fn (id, SEL, id, id, *id) callconv(.c) id = @ptrCast(&objc_msgSend);
    const lib = newLib(gpu.device, sel("newLibraryWithSource:options:error:"), nsString(msl_source), null, &err);
    if (lib == null) {
        std.debug.print("FAIL: MSL compile: {s}\n", .{describe(err)});
        return false;
    }
    const compile_ms = (CACurrentMediaTime() - t0) * 1000;

    const desc = msg(msg(cls("MTLRenderPipelineDescriptor"), "alloc"), "init");
    msg1v(desc, "setVertexFunction:", msg1(lib, "newFunctionWithName:", nsString("vs")));
    msg1v(desc, "setFragmentFunction:", msg1(lib, "newFunctionWithName:", nsString("fs")));
    msgULong(msgIdx(msg(desc, "colorAttachments"), "objectAtIndexedSubscript:", 0), "setPixelFormat:", MTLPixelFormatBGRA8Unorm);
    const newPipe: *const fn (id, SEL, id, *id) callconv(.c) id = @ptrCast(&objc_msgSend);
    gpu.pipeline = newPipe(gpu.device, sel("newRenderPipelineStateWithDescriptor:error:"), desc, &err);
    if (gpu.pipeline == null) {
        std.debug.print("FAIL: pipeline: {s}\n", .{describe(err)});
        return false;
    }

    const layer = msg(cls("CAMetalLayer"), "layer");
    msg1v(layer, "setDevice:", gpu.device);
    msgULong(layer, "setPixelFormat:", MTLPixelFormatBGRA8Unorm);
    msgBool(layer, "setOpaque:", false);
    msgBool(layer, "setFramebufferOnly:", true);
    msgDouble(layer, "setContentsScale:", scale);
    msgRect(layer, "setFrame:", .{ .x = 0, .y = 0, .w = region_w, .h = region_h });
    const setSize: *const fn (id, SEL, CGSize) callconv(.c) void = @ptrCast(&objc_msgSend);
    setSize(layer, sel("setDrawableSize:"), .{ .w = region_w * scale, .h = region_h * scale });
    gpu.layer = layer;
    gpu.scale = scale;

    const name: [*:0]const u8 = blk: {
        const f: *const fn (id, SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc_msgSend);
        break :blk f(msg(gpu.device, "name"), sel("UTF8String"));
    };
    std.debug.print("OK: device \"{s}\", MSL compiled + pipeline built in {d:.1} ms\n", .{ name, compile_ms });
    return true;
}

/// Encode and present one frame of `scene` at `t`. Returns false if no drawable was free.
fn drawFrame(gpu: *Gpu, scene: *const Scene, t: f64) bool {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    var buf: [max_prims]Prim = undefined;
    const n = scene.prims(t, &buf);
    const label = srgb("labelColor");
    const secondary = srgb("secondaryLabelColor");

    var u: Uniforms = .{
        .res = .{ @floatCast(region_w * gpu.scale), @floatCast(region_h * gpu.scale) },
        .px = @floatCast(gpu.scale),
        .count = 0,
        .k = goo_k,
        .glow = if (state.glow) glow_strength else 0,
        .geo = undefined,
        .col = undefined,
        .fade = undefined,
    };
    var live: usize = 0;
    for (buf[0..n]) |p| {
        if (p.a <= 0.003 or p.w <= 0.02 or p.h <= 0.02) continue;
        const c = if (p.role == .label) label else secondary;
        u.geo[live] = .{ @floatCast(ox + p.cx), @floatCast(oy + (pill_h - p.cy)), @floatCast(p.w), @floatCast(p.h) };
        u.col[live] = .{ c[0], c[1], c[2], c[3] * @as(f32, @floatCast(p.a)) };
        u.fade[live] = @floatCast(clamp01(p.a));
        live += 1;
    }
    u.count = @intCast(live);

    const drawable = msg(gpu.layer, "nextDrawable");
    if (drawable == null) return false;

    const rpd = msg(cls("MTLRenderPassDescriptor"), "renderPassDescriptor");
    const att = msgIdx(msg(rpd, "colorAttachments"), "objectAtIndexedSubscript:", 0);
    msg1v(att, "setTexture:", msg(drawable, "texture"));
    msgULong(att, "setLoadAction:", MTLLoadActionClear);
    msgULong(att, "setStoreAction:", MTLStoreActionStore);
    const setClear: *const fn (id, SEL, MTLClearColor) callconv(.c) void = @ptrCast(&objc_msgSend);
    setClear(att, sel("setClearColor:"), .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    const cb = msg(gpu.queue, "commandBuffer");
    const enc = msg1(cb, "renderCommandEncoderWithDescriptor:", rpd);
    msg1v(enc, "setRenderPipelineState:", gpu.pipeline);
    const setBytes: *const fn (id, SEL, *const anyopaque, c_ulong, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
    setBytes(enc, sel("setFragmentBytes:length:atIndex:"), &u, @sizeOf(Uniforms), 0);
    const draw: *const fn (id, SEL, c_ulong, c_ulong, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
    draw(enc, sel("drawPrimitives:vertexStart:vertexCount:"), MTLPrimitiveTypeTriangle, 0, 3);
    msgv(enc, "endEncoding");
    msg1v(cb, "presentDrawable:", drawable);
    msgv(cb, "commit");
    return true;
}

// ============================================================================
// Harness state, pacing, stats
// ============================================================================
const Pacing = enum { link, timer };

const State = struct {
    gpu: Gpu = .{},
    scene: Scene = .{},
    panel: id = null,
    link: id = null,
    timer: CFRef = null,
    pacing: Pacing = .link,
    visible: bool = false,
    glow: bool = true,

    // stats window
    win_start: f64 = 0,
    cpu_start: c_ulong = 0,
    frames: u32 = 0,
    no_drawable: u32 = 0,
    last_cb: f64 = 0,
    max_gap: f64 = 0,
    late: u32 = 0, // callbacks > 1.5 display periods apart
    build_s: f64 = 0, // CPU seconds inside drawFrame
    period: f64 = 1.0 / 120.0,
};
var state: State = .{};

fn onFrame(t_target: f64) void {
    const now = CACurrentMediaTime();
    if (state.last_cb > 0) {
        const gap = now - state.last_cb;
        state.max_gap = @max(state.max_gap, gap);
        if (gap > state.period * 1.5) state.late += 1;
    }
    state.last_cb = now;
    if (!state.visible) return;
    state.scene.advance(t_target);
    const b0 = CACurrentMediaTime();
    if (drawFrame(&state.gpu, &state.scene, t_target)) state.frames += 1 else state.no_drawable += 1;
    state.build_s += CACurrentMediaTime() - b0;
}

// CADisplayLink target: -[TWSpikeLinkTarget onFrame:(CADisplayLink *)link]
fn linkFired(_: id, _: SEL, link: id) callconv(.c) void {
    onFrame(msgF64(link, "targetTimestamp"));
}
fn timerFired(_: CFRef, _: ?*anyopaque) callconv(.c) void {
    onFrame(CACurrentMediaTime() + state.period);
}

fn makeLink() void {
    const target_cls = objc_allocateClassPair(cls("NSObject"), "TWSpikeLinkTarget", 0);
    _ = class_addMethod(target_cls, sel("onFrame:"), @ptrCast(&linkFired), "v@:@");
    objc_registerClassPair(target_cls);
    const target = msg(msg(target_cls, "alloc"), "init");

    const screen = msg(cls("NSScreen"), "mainScreen");
    const mk: *const fn (id, SEL, id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    state.link = mk(screen, sel("displayLinkWithTarget:selector:"), target, sel("onFrame:"));
    if (state.link == null) {
        std.debug.print("FAIL: NSScreen displayLinkWithTarget:selector: returned nil\n", .{});
        return;
    }
    const setRange: *const fn (id, SEL, CAFrameRateRange) callconv(.c) void = @ptrCast(&objc_msgSend);
    setRange(state.link, sel("setPreferredFrameRateRange:"), .{ .minimum = 60, .maximum = 120, .preferred = 120 });
    msgBool(state.link, "setPaused:", true);
    const add: *const fn (id, SEL, id, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    add(state.link, sel("addToRunLoop:forMode:"), msg(cls("NSRunLoop"), "currentRunLoop"), NSRunLoopCommonModes);
    std.debug.print("OK: CADisplayLink from NSScreen (runtime target class)\n", .{});
}

fn startDrawing() void {
    state.last_cb = 0;
    switch (state.pacing) {
        .link => if (state.link != null) msgBool(state.link, "setPaused:", false),
        .timer => {
            state.timer = CFRunLoopTimerCreate(null, CFAbsoluteTimeGetCurrent(), state.period, 0, 0, timerFired, null);
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), state.timer, kCFRunLoopCommonModes);
        },
    }
}
fn stopDrawing() void {
    if (state.link != null) msgBool(state.link, "setPaused:", true);
    if (state.timer != null) {
        CFRunLoopTimerInvalidate(state.timer);
        CFRelease(state.timer);
        state.timer = null;
    }
}

fn show() void {
    state.visible = true;
    state.scene.startBars(CACurrentMediaTime());
    msgv(state.panel, "orderFrontRegardless"); // never makeKey — the #20 recipe
    startDrawing();
}
fn hide() void {
    state.visible = false;
    stopDrawing();
    msg1v(state.panel, "orderOut:", null);
}
fn setPacing(p: Pacing) void {
    stopDrawing();
    state.pacing = p;
    if (state.visible) startDrawing();
}

fn resetStats() void {
    state.win_start = CACurrentMediaTime();
    state.cpu_start = clock();
    state.frames = 0;
    state.no_drawable = 0;
    state.max_gap = 0;
    state.late = 0;
    state.build_s = 0;
}
fn report(label: []const u8) void {
    const wall = CACurrentMediaTime() - state.win_start;
    const cpu_s = @as(f64, @floatFromInt(clock() - state.cpu_start)) / 1e6;
    const fps = @as(f64, @floatFromInt(state.frames)) / wall;
    const per_frame_us = if (state.frames > 0) state.build_s / @as(f64, @floatFromInt(state.frames)) * 1e6 else 0;
    std.debug.print(
        "{s:<22} fps {d:6.1}  late {d:3}  max gap {d:5.1} ms  no-drawable {d:2}  cpu {d:5.2}%  build+encode {d:6.1} µs/frame\n",
        .{ label, fps, state.late, state.max_gap * 1000, state.no_drawable, cpu_s / wall * 100, per_frame_us },
    );
    resetStats();
}

// ---- commands (stdin, or the --bench script) --------------------------------------
fn command(c: u8) void {
    switch (c) {
        'b' => if (state.visible) state.scene.startBars(CACurrentMediaTime()),
        'd' => state.scene.startDots(CACurrentMediaTime()),
        'l' => setPacing(.link),
        't' => setPacing(.timer),
        'h' => hide(),
        's' => if (!state.visible) show(),
        'w' => state.scene.voice.whisper = true,
        'n' => state.scene.voice.whisper = false,
        'g' => state.glow = !state.glow,
        'r' => report("interactive"),
        'q' => std.process.exit(0),
        else => {},
    }
}

fn stdinFired(f: CFRef, _: c_ulong, _: ?*anyopaque) callconv(.c) void {
    var buf: [64]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) std.process.exit(0);
    for (buf[0..@intCast(n)]) |c| command(c);
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
}

// The bench script: (seconds after start, command, report label before running it).
const Step = struct { at: f64, cmd: u8, label: ?[]const u8 = null };
const bench = [_]Step{
    .{ .at = 0.5, .cmd = 's' },
    .{ .at = 1.0, .cmd = 'r', .label = "warmup (link)" },
    .{ .at = 5.0, .cmd = 'd', .label = "link · bars" },
    .{ .at = 8.0, .cmd = 't', .label = "link · dots" },
    .{ .at = 8.5, .cmd = 'b', .label = "switch" },
    .{ .at = 12.5, .cmd = 'd', .label = "timer · bars" },
    .{ .at = 15.5, .cmd = 'h', .label = "timer · dots" },
    .{ .at = 19.5, .cmd = 'q', .label = "hidden (no drawing)" },
};
var bench_i: usize = 0;
var bench_t0: f64 = 0;
fn benchFired(_: CFRef, _: ?*anyopaque) callconv(.c) void {
    const el = CACurrentMediaTime() - bench_t0;
    while (bench_i < bench.len and el >= bench[bench_i].at) : (bench_i += 1) {
        const s = bench[bench_i];
        if (s.label) |l| report(l);
        if (s.cmd != 'r') command(s.cmd);
    }
}

pub fn main() void {
    const bench_mode = getenv("HUD_SPIKE_BENCH") != null;
    _ = objc_autoreleasePoolPush(); // outermost pool for setup; never popped (process lifetime)

    // Accessory-policy app, launched without a Dock icon (src/appkit.zig).
    const app = msg(cls("NSApplication"), "sharedApplication");
    const setPolicy: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = setPolicy(app, sel("setActivationPolicy:"), 2);
    const screen = msg(cls("NSScreen"), "mainScreen");
    if (screen == null) {
        std.debug.print("FAIL: headless (no main screen)\n", .{});
        std.process.exit(1);
    }
    msgv(app, "finishLaunching");

    const scale = msgF64(screen, "backingScaleFactor");
    if (!initMetal(&state.gpu, scale)) std.process.exit(1);

    // The panel: the daemon's focus-avoidance recipe, sized to the drawing region and
    // placed so the pill's centre sits where the daemon's does (bottom-centre, y + 140).
    const sf = msgRetRect(screen, "frame");
    const rect = NSRect{ .x = sf.x + (sf.w - region_w) / 2, .y = sf.y + 140 - oy, .w = region_w, .h = region_h };
    const mkPanel: *const fn (id, SEL, NSRect, c_ulong, c_ulong, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
    const panel = mkPanel(msg(cls("NSPanel"), "alloc"), sel("initWithContentRect:styleMask:backing:defer:"), rect, NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel, NSBackingStoreBuffered, false);
    state.panel = panel;
    msgLong(panel, "setLevel:", NSStatusWindowLevel);
    msgBool(panel, "setIgnoresMouseEvents:", true);
    msgBool(panel, "setFloatingPanel:", true);
    msgBool(panel, "setBecomesKeyOnlyIfNeeded:", true);
    msgULong(panel, "setCollectionBehavior:", NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary);
    msgBool(panel, "setOpaque:", false);
    msg1v(panel, "setBackgroundColor:", msg(cls("NSColor"), "clearColor"));
    msgBool(panel, "setHasShadow:", false);
    const content = msg(panel, "contentView");
    msgBool(content, "setWantsLayer:", true);
    msg1v(msg(content, "layer"), "addSublayer:", state.gpu.layer);
    std.debug.print("OK: panel {d:.0}x{d:.0} at ({d:.0},{d:.0}) on a {d:.0}x{d:.0} screen, backing scale {d:.1}\n", .{ rect.w, rect.h, rect.x, rect.y, sf.w, sf.h, scale });

    makeLink();

    if (bench_mode) {
        bench_t0 = CACurrentMediaTime();
        const tm = CFRunLoopTimerCreate(null, CFAbsoluteTimeGetCurrent(), 0.05, 0, 0, benchFired, null);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), tm, kCFRunLoopCommonModes);
    } else {
        const fd = CFFileDescriptorCreate(null, 0, 0, stdinFired, null);
        CFFileDescriptorEnableCallBacks(fd, kCFFileDescriptorReadCallBack);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFFileDescriptorCreateRunLoopSource(null, fd, 0), kCFRunLoopCommonModes);
        std.debug.print(
            \\
            \\  s show   h hide     b bars (recording)   d dots (gather)
            \\  l pacing: CADisplayLink   t pacing: 120 Hz CFRunLoopTimer
            \\  w whisper  n normal voice   g toggle glow   r report stats   q quit
            \\  (letters + Enter)
            \\
        , .{});
        show();
        resetStats();
    }
    CFRunLoopRun();
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
