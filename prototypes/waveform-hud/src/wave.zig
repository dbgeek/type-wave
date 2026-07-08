//! wave.zig — the silent waveform pill, PURELY through the ObjC runtime C API
//! from Zig (wayfinder #25). Throwaway prototype: proves the **CALayer-per-bar**
//! mechanism (the cheapest candidate — a fixed row of sublayers whose frames the
//! render pump pokes each tick; no view subclassing, no drawRect:, no
//! objc_allocateClassPair) plus a green processing animation, inside the exact
//! panel recipe already proven by #20 and shipped in src/hud.zig.
//!
//! Main-thread only, except nothing: every function here is called from the
//! render pump (a CFRunLoopTimer on the main thread). Producers never touch this
//! file — the harness (main.zig) drains their level queue and calls pushLevel/
//! render from the tick.

const std = @import("std");

// ---- ObjC runtime primitives (same as src/hud.zig) ---------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

// ---- typed objc_msgSend shims -------------------------------------------------
inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
inline fn msgv(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op));
}
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
}
inline fn msgBool(self: id, op: [*:0]const u8, b: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), b);
}
inline fn msgLong(self: id, op: [*:0]const u8, n: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), n);
}
inline fn msgULong(self: id, op: [*:0]const u8, n: c_ulong) void {
    const f: *const fn (id, SEL, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), n);
}
inline fn msgDouble(self: id, op: [*:0]const u8, x: f64) void {
    const f: *const fn (id, SEL, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}
// CALayer.opacity is a plain C float, not CGFloat.
inline fn msgFloat(self: id, op: [*:0]const u8, x: f32) void {
    const f: *const fn (id, SEL, f32) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}

// NSRect/CGRect: four f64 = an HFA, passed in v0–v3 by the arm64 C ABI (src/hud.zig).
const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };

inline fn msgRect(self: id, op: [*:0]const u8, r: Rect) void {
    const f: *const fn (id, SEL, Rect) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), r);
}
// [panel setFrame:display:]
inline fn msgRectBool(self: id, op: [*:0]const u8, r: Rect, b: bool) void {
    const f: *const fn (id, SEL, Rect, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), r, b);
}
inline fn rgba(r: f64, g: f64, b: f64, a: f64) id {
    const f: *const fn (id, SEL, f64, f64, f64, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSColor"), sel_registerName("colorWithSRGBRed:green:blue:alpha:"), r, g, b, a);
}
inline fn cgColor(nscolor: id) id {
    return msg(nscolor, "CGColor");
}
inline fn makePanel(rect: Rect, style: c_ulong, backing: c_ulong) id {
    const allocd = msg(cls("NSPanel"), "alloc");
    const f: *const fn (id, SEL, Rect, c_ulong, c_ulong, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithContentRect:styleMask:backing:defer:"), rect, style, backing, false);
}
inline fn mainScreen() id {
    return msg(cls("NSScreen"), "mainScreen");
}
inline fn screenFrame(screen: id) Rect {
    const f: *const fn (id, SEL) callconv(.c) Rect = @ptrCast(&objc_msgSend);
    return f(screen, sel_registerName("frame"));
}

// ---- window/style constants (same recipe as src/hud.zig, proven by #20) ------
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskNonactivatingPanel: c_ulong = 1 << 7;
const NSBackingStoreBuffered: c_ulong = 2;
const NSStatusWindowLevel: c_long = 25;
const NSWindowCollectionBehaviorCanJoinAllSpaces: c_ulong = 1 << 0;
const NSWindowCollectionBehaviorStationary: c_ulong = 1 << 4;
const NSWindowCollectionBehaviorFullScreenAuxiliary: c_ulong = 1 << 8;

// ---- the tunables the human reacts to (HITL) ----------------------------------
pub const max_bars = 96; // layers allocated once; presets use a prefix and hide the rest

pub const Mode = enum { hidden, recording, processing };

pub const Scheme = enum {
    red_pill_white_bars, // today's recording-red pill, white bars; green pill while processing
    dark_pill_tinted_bars, // charcoal pill always; the BARS carry the state colour
    transparent_tinted_bars, // NO pill at all — just the bars floating over the screen
};

pub const AnimVariant = enum { wave, dots, breathe };

pub const Look = struct {
    pill_w: f64 = 250,
    pill_h: f64 = 38,
    bar_w: f64 = 3,
    bar_gap: f64 = 2,
    scheme: Scheme = .transparent_tinted_bars,
};

const pad_x: f64 = 20; // inner margin before the first / after the last bar
const min_bar_h: f64 = 3; // silence reads as a flat dotted line, not an empty pill
const dot_size: f64 = 12;
const dot_gap: f64 = 10;

/// How many bars a Look fits. Also how much history the pill shows:
/// at one level per 50 ms Capture buffer, nbars/20 seconds scroll across it.
pub fn barCount(look: Look) usize {
    const usable = look.pill_w - 2 * pad_x;
    const per = look.bar_w + look.bar_gap;
    const n: usize = @intFromFloat(@floor((usable + look.bar_gap) / per));
    return @min(n, max_bars);
}

pub const Pill = struct {
    panel: id = null,
    layer: id = null, // contentView's CALayer — the rounded pill
    bars: [max_bars]id = @splat(null),
    dots: [3]id = @splat(null),
    look: Look = .{},
    nbars: usize = 0,

    /// Scroll buffer: levels[max_bars-1] is the newest sample (rightmost bar);
    /// pushLevel shifts left. Bars themselves never move — heights march.
    levels: [max_bars]f32 = @splat(0),

    shown: bool = false,

    // Colour/visibility are (mode, scheme, variant)-dependent, not per-tick —
    // cache what was last applied so a tick only pokes bar heights.
    last_mode: ?Mode = null,
    last_scheme: ?Scheme = null,
    last_variant: ?AnimVariant = null,

    /// Build the panel + all layers, hidden. Main thread, before the run loop.
    /// Returns false when headless ([NSScreen mainScreen] is nil).
    pub fn init(self: *Pill, look: Look) bool {
        const screen = mainScreen();
        if (screen == null) return false;

        const panel = makePanel(
            .{ .x = 0, .y = 0, .w = look.pill_w, .h = look.pill_h },
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
        );
        self.panel = panel;

        // The focus-avoidance recipe, verbatim from src/hud.zig (proven by #20).
        msgLong(panel, "setLevel:", NSStatusWindowLevel);
        msgBool(panel, "setIgnoresMouseEvents:", true);
        msgBool(panel, "setFloatingPanel:", true);
        msgBool(panel, "setBecomesKeyOnlyIfNeeded:", true);
        msgULong(
            panel,
            "setCollectionBehavior:",
            NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorStationary |
                NSWindowCollectionBehaviorFullScreenAuxiliary,
        );
        msgBool(panel, "setOpaque:", false);
        msg1v(panel, "setBackgroundColor:", msg(cls("NSColor"), "clearColor"));
        msgBool(panel, "setHasShadow:", true);

        const content = msg(panel, "contentView");
        msgBool(content, "setWantsLayer:", true);
        const layer = msg(content, "layer");
        self.layer = layer;

        // The whole mechanism: a row of plain CALayers. [CALayer layer] returns
        // autoreleased; addSublayer: retains, so the hierarchy owns them after this.
        for (&self.bars) |*bar| {
            bar.* = msg(cls("CALayer"), "layer");
            msgBool(bar.*, "setHidden:", true);
            msg1v(layer, "addSublayer:", bar.*);
        }
        for (&self.dots) |*dot| {
            dot.* = msg(cls("CALayer"), "layer");
            msgBool(dot.*, "setHidden:", true);
            msgDouble(dot.*, "setCornerRadius:", dot_size / 2);
            msg1v(layer, "addSublayer:", dot.*);
        }

        self.applyLook(look);
        return true;
    }

    /// Re-frame the panel (bottom-centre) and lay the bar row out for a Look.
    /// Main thread. Cheap enough to call on every preset/size/scheme switch.
    pub fn applyLook(self: *Pill, look: Look) void {
        self.look = look;
        self.nbars = barCount(look);

        const sf = screenFrame(mainScreen());
        msgRectBool(self.panel, "setFrame:display:", .{
            .x = sf.x + (sf.w - look.pill_w) / 2.0,
            .y = sf.y + 140,
            .w = look.pill_w,
            .h = look.pill_h,
        }, true);
        msgDouble(self.layer, "setCornerRadius:", look.pill_h / 2.0);

        const row_w = @as(f64, @floatFromInt(self.nbars)) * (look.bar_w + look.bar_gap) - look.bar_gap;
        const x0 = (look.pill_w - row_w) / 2.0;
        for (self.bars, 0..) |bar, i| {
            if (i >= self.nbars) {
                msgBool(bar, "setHidden:", true);
                continue;
            }
            const fi: f64 = @floatFromInt(i);
            msgDouble(bar, "setCornerRadius:", look.bar_w / 2.0);
            msgRect(bar, "setFrame:", .{
                .x = x0 + fi * (look.bar_w + look.bar_gap),
                .y = (look.pill_h - min_bar_h) / 2.0,
                .w = look.bar_w,
                .h = min_bar_h,
            });
        }
        const dots_w = 3 * dot_size + 2 * dot_gap;
        for (self.dots, 0..) |dot, j| {
            const fj: f64 = @floatFromInt(j);
            msgRect(dot, "setFrame:", .{
                .x = (look.pill_w - dots_w) / 2.0 + fj * (dot_size + dot_gap),
                .y = (look.pill_h - dot_size) / 2.0,
                .w = dot_size,
                .h = dot_size,
            });
        }
        self.last_mode = null; // force a recolour + visibility pass next render
    }

    /// One level sample (0..1) = one new bar at the right edge. Main thread.
    pub fn pushLevel(self: *Pill, v: f32) void {
        std.mem.copyForwards(f32, self.levels[0 .. max_bars - 1], self.levels[1..]);
        self.levels[max_bars - 1] = v;
    }

    /// Reflect a mode into the layers. Called every pump tick from the main
    /// thread; `t` (seconds) drives the processing animation. `implicit_anims`
    /// leaves Core Animation's 0.25 s implicit transactions ON instead of
    /// disabling them — the toggle that answers "does 20 Hz need CA's help".
    pub fn render(self: *Pill, mode: Mode, variant: AnimVariant, implicit_anims: bool, t: f64) void {
        msgv(cls("CATransaction"), "begin");
        msgBool(cls("CATransaction"), "setDisableActions:", !implicit_anims);
        defer msgv(cls("CATransaction"), "commit");

        if (mode == .hidden) {
            if (self.shown) {
                msgv(self.panel, "orderOut:");
                self.shown = false;
                self.levels = @splat(0); // next Utterance starts from a flat line
            }
            return;
        }

        self.recolorIfNeeded(mode, variant);

        const look = self.look;
        const max_h = look.pill_h * 0.72; // proportional headroom — holds up at 38 px too
        const row_w = @as(f64, @floatFromInt(self.nbars)) * (look.bar_w + look.bar_gap) - look.bar_gap;
        const x0 = (look.pill_w - row_w) / 2.0;

        switch (mode) {
            .hidden => unreachable,
            .recording => {
                for (0..self.nbars) |i| {
                    const lv: f64 = @floatCast(self.levels[max_bars - self.nbars + i]);
                    self.setBarHeight(i, x0, min_bar_h + lv * (max_h - min_bar_h));
                }
            },
            .processing => switch (variant) {
                // A green wave marching through the bars.
                .wave => {
                    for (0..self.nbars) |i| {
                        const fi: f64 = @floatFromInt(i);
                        const s = 0.5 + 0.5 * @sin(t * 6.0 - fi * 0.55);
                        self.setBarHeight(i, x0, min_bar_h + (0.30 + 0.35 * s) * (max_h - min_bar_h));
                    }
                },
                // Three bouncing dots (the bars are hidden by recolorIfNeeded).
                .dots => {
                    for (self.dots, 0..) |dot, j| {
                        const fj: f64 = @floatFromInt(j);
                        const bounce = 8.0 * @sin(t * 5.0 + fj * 0.8);
                        const dots_w = 3 * dot_size + 2 * dot_gap;
                        msgRect(dot, "setFrame:", .{
                            .x = (look.pill_w - dots_w) / 2.0 + fj * (dot_size + dot_gap),
                            .y = (look.pill_h - dot_size) / 2.0 + bounce,
                            .w = dot_size,
                            .h = dot_size,
                        });
                    }
                },
                // The waveform freezes where the release caught it; the pill breathes.
                .breathe => {
                    for (0..self.nbars) |i| {
                        const lv: f64 = @floatCast(self.levels[max_bars - self.nbars + i]);
                        self.setBarHeight(i, x0, min_bar_h + lv * (max_h - min_bar_h));
                    }
                    msgFloat(self.layer, "setOpacity:", @floatCast(0.72 + 0.24 * @sin(t * 3.0)));
                },
            },
        }

        if (!self.shown) {
            msgv(self.panel, "orderFrontRegardless"); // never makeKey — #20's recipe
            self.shown = true;
        }
    }

    fn setBarHeight(self: *Pill, i: usize, x0: f64, h: f64) void {
        const fi: f64 = @floatFromInt(i);
        msgRect(self.bars[i], "setFrame:", .{
            .x = x0 + fi * (self.look.bar_w + self.look.bar_gap),
            .y = (self.look.pill_h - h) / 2.0,
            .w = self.look.bar_w,
            .h = h,
        });
    }

    /// Colours + which layer family is visible change per (mode, scheme, variant),
    /// not per tick — apply only on transitions so a tick is just height pokes.
    fn recolorIfNeeded(self: *Pill, mode: Mode, variant: AnimVariant) void {
        if (self.last_mode == mode and self.last_scheme == self.look.scheme and self.last_variant == variant) return;
        self.last_mode = mode;
        self.last_scheme = self.look.scheme;
        self.last_variant = variant;

        const recording_red = rgba(0.78, 0.16, 0.18, 0.95); // src/hud.zig's recording colour
        const committed_green = rgba(0.11, 0.44, 0.22, 0.95); // src/hud.zig's final colour
        const charcoal = rgba(0.10, 0.10, 0.12, 0.92);
        const clear = rgba(0, 0, 0, 0);
        const white = rgba(1.0, 1.0, 1.0, 0.95);
        const tint_red = rgba(1.0, 0.38, 0.38, 1.0);
        const tint_green = rgba(0.30, 0.85, 0.45, 1.0);

        const pill_bg, const bar_color, const dot_color = switch (self.look.scheme) {
            .red_pill_white_bars => switch (mode) {
                .recording => .{ recording_red, white, white },
                else => .{ committed_green, white, white },
            },
            .dark_pill_tinted_bars => switch (mode) {
                .recording => .{ charcoal, tint_red, tint_green },
                else => .{ charcoal, tint_green, tint_green },
            },
            .transparent_tinted_bars => switch (mode) {
                .recording => .{ clear, tint_red, tint_green },
                else => .{ clear, tint_green, tint_green },
            },
        };

        msg1v(self.layer, "setBackgroundColor:", cgColor(pill_bg));
        // A window shadow around an invisible pill draws a ghost outline — drop it
        // for the transparent scheme (the bars are too thin to need one anyway).
        msgBool(self.panel, "setHasShadow:", self.look.scheme != .transparent_tinted_bars);
        msgv(self.panel, "invalidateShadow");
        msgFloat(self.layer, "setOpacity:", 1.0); // breathe re-modulates it per tick

        const dots_mode = (mode == .processing and variant == .dots);
        for (self.bars, 0..) |bar, i| {
            msg1v(bar, "setBackgroundColor:", cgColor(bar_color));
            msgBool(bar, "setHidden:", dots_mode or i >= self.nbars);
        }
        for (self.dots) |dot| {
            msg1v(dot, "setBackgroundColor:", cgColor(dot_color));
            msgBool(dot, "setHidden:", !dots_mode);
        }
    }
};
