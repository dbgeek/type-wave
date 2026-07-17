//! glass.zig — the Liquid Glass capsule HUD, PURELY through the ObjC runtime
//! C API from Zig (wayfinder #41, map #39). Throwaway prototype: wraps the
//! proven CALayer-per-bar waveform (#25) in an `NSGlassEffectView` capsule
//! (macOS 26), drops the custom red/green for system accent + semantic
//! colors, and makes every look axis live-switchable so the human can react.
//!
//! Wiring follows the #40 research crib sheet (docs/research/liquid-glass-api.md):
//! - one NSGlassEffectView as the capsule; bar/dot layers live on a plain
//!   layer-backed NSView assigned via setContentView: (the sanctioned path —
//!   raw CALayers get no vibrancy treatment, so layer colors are derived from
//!   controlAccentColor / semantic NSColors, re-resolved on every recolor).
//! - panel recipe verbatim from src/hud.zig (#20 focus avoidance) — already
//!   the glass-compatible setup (non-opaque, clear background).
//!
//! Main-thread only: every function here is called from the render pump.

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
inline fn msg1(self: id, op: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), a);
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
// colorWithAlphaComponent: takes CGFloat and returns a new NSColor.
inline fn msgDoubleRet(self: id, op: [*:0]const u8, x: f64) id {
    const f: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), x);
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
inline fn msgRectRet(self: id, op: [*:0]const u8, r: Rect) id {
    const f: *const fn (id, SEL, Rect) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), r);
}
// [panel setFrame:display:]
inline fn msgRectBool(self: id, op: [*:0]const u8, r: Rect, b: bool) void {
    const f: *const fn (id, SEL, Rect, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), r, b);
}
inline fn initWithFrame(class_name: [*:0]const u8, r: Rect) id {
    return msgRectRet(msg(cls(class_name), "alloc"), "initWithFrame:", r);
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

// ---- system-native colors (#40 §4/§5): dynamic NSColors, resolved per recolor --
// controlAccentColor / label colors are catalog colors — colorUsingColorSpace:
// is mandatory before component/CGColor use; resolution follows the current
// appearance, so re-resolving per recolor keeps staleness bounded by one show.
inline fn srgb(color: id) id {
    return msg1(color, "colorUsingColorSpace:", msg(cls("NSColorSpace"), "sRGBColorSpace"));
}
inline fn systemColor(name: [*:0]const u8) id {
    return srgb(msg(cls("NSColor"), name));
}
inline fn withAlpha(color: id, a: f64) id {
    return msgDoubleRet(color, "colorWithAlphaComponent:", a);
}
inline fn cgColor(nscolor: id) id {
    return msg(nscolor, "CGColor");
}

// ---- window/style constants (same recipe as src/hud.zig, proven by #20) ------
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskNonactivatingPanel: c_ulong = 1 << 7;
const NSBackingStoreBuffered: c_ulong = 2;
const NSStatusWindowLevel: c_long = 25;
const NSWindowCollectionBehaviorCanJoinAllSpaces: c_ulong = 1 << 0;
const NSWindowCollectionBehaviorStationary: c_ulong = 1 << 4;
const NSWindowCollectionBehaviorFullScreenAuxiliary: c_ulong = 1 << 8;

// ---- the look axes the human reacts to (HITL) ----------------------------------
pub const max_bars = 96; // layers allocated once; presets use a prefix and hide the rest

pub const Mode = enum { hidden, recording, processing };

/// NSGlassEffectViewStyle — the ONLY two public styles (#40 §1.2).
pub const GlassStyle = enum(c_long) { regular = 0, clear = 1 };

pub const BarScheme = enum {
    accent, // controlAccentColor bars — the destination sketch
    label, // labelColor bars — neutral, appearance-adaptive
    white, // fixed white — the old look, for direct comparison
};

/// Glass tintColor pulls the material toward a color (#40 §5). Never-key
/// panels render tint differently from key windows — keep it subtle (§3).
pub const Tint = enum { none, accent_soft, accent_strong }; // nil / accent@0.25 / accent@0.45

pub const ProcessingAnim = enum {
    dots_accent, // three bouncing dots in accent (old winner, new palette)
    dots_neutral, // dots in secondaryLabelColor — quieter
    glass_pulse, // glass-native: waveform freezes, the MATERIAL breathes via tint
};

pub const Radius = enum { capsule, soft, sdk_default }; // pill_h/2 / 16 / 8

pub const Look = struct {
    // 420x60 fine bars: the HITL winner from #25, the ticket's fixed footprint.
    pill_w: f64 = 420,
    pill_h: f64 = 60,
    bar_w: f64 = 3,
    bar_gap: f64 = 2,
    style: GlassStyle = .regular,
    bars: BarScheme = .accent,
    tint: Tint = .none,
    radius: Radius = .capsule,
    shadow: bool = true, // glass shape probably wants the window shadow back (#40 §3)
};

const pad_x: f64 = 20; // inner margin before the first / after the last bar
const min_bar_h: f64 = 3; // silence reads as a flat dotted line, not an empty pill
const dot_size: f64 = 12;
const dot_gap: f64 = 10;

pub fn barCount(look: Look) usize {
    const usable = look.pill_w - 2 * pad_x;
    const per = look.bar_w + look.bar_gap;
    const n: usize = @intFromFloat(@floor((usable + look.bar_gap) / per));
    return @min(n, max_bars);
}

fn cornerRadius(look: Look) f64 {
    return switch (look.radius) {
        .capsule => look.pill_h / 2.0,
        .soft => 16.0,
        .sdk_default => 8.0,
    };
}

pub const Pill = struct {
    panel: id = null,
    glass: id = null, // the NSGlassEffectView capsule
    content: id = null, // plain layer-backed NSView, glass's contentView
    layer: id = null, // content's CALayer — hosts the bar/dot sublayers
    bars: [max_bars]id = @splat(null),
    dots: [3]id = @splat(null),
    look: Look = .{},
    nbars: usize = 0,

    /// Scroll buffer: levels[max_bars-1] is the newest sample (rightmost bar);
    /// pushLevel shifts left. Bars themselves never move — heights march.
    levels: [max_bars]f32 = @splat(0),

    shown: bool = false,

    // Colors/visibility are (mode, anim)-dependent, not per-tick — cache what
    // was last applied so a tick is only height pokes. applyLook clears the
    // cache, so look-axis changes recolor too.
    last_mode: ?Mode = null,
    last_anim: ?ProcessingAnim = null,

    /// Build the panel + glass capsule + all layers, hidden. Main thread,
    /// before the run loop. Returns false when headless or glass is missing.
    pub fn init(self: *Pill, look: Look) bool {
        const screen = mainScreen();
        if (screen == null) return false;
        if (cls("NSGlassEffectView") == null) {
            std.debug.print("NSGlassEffectView class not found — needs macOS 26\n", .{});
            return false;
        }

        const panel = makePanel(
            .{ .x = 0, .y = 0, .w = look.pill_w, .h = look.pill_h },
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
        );
        self.panel = panel;

        // The focus-avoidance recipe, verbatim from src/hud.zig (proven by #20).
        // Non-opaque + clear background is also exactly what glass needs (#40 §3).
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
        msgBool(panel, "setHasShadow:", look.shadow);

        // The capsule: one NSGlassEffectView filling the panel (#40 §7 — a
        // single shape needs no NSGlassEffectContainerView).
        const bounds = Rect{ .x = 0, .y = 0, .w = look.pill_w, .h = look.pill_h };
        const glass = initWithFrame("NSGlassEffectView", bounds);
        self.glass = glass;

        // Bar/dot layers ride a plain NSView set as the glass contentView —
        // the sanctioned placement; z-order above the material is guaranteed.
        const content = initWithFrame("NSView", bounds);
        msgBool(content, "setWantsLayer:", true);
        self.content = content;
        const layer = msg(content, "layer");
        self.layer = layer;

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

        msg1v(glass, "setContentView:", content);
        msg1v(msg(panel, "contentView"), "addSubview:", glass);

        self.applyLook(look);
        return true;
    }

    /// Re-frame the panel (bottom-centre), the glass, and the bar row for a
    /// Look; apply the glass axes. Main thread. Cheap enough per switch.
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

        // Checkpoint (#40 §1.1): glass ties its geometry to contentView via
        // Auto Layout — set BOTH frames and watch that they track on resize.
        const bounds = Rect{ .x = 0, .y = 0, .w = look.pill_w, .h = look.pill_h };
        msgRect(self.glass, "setFrame:", bounds);
        msgRect(self.content, "setFrame:", bounds);

        msgLong(self.glass, "setStyle:", @intFromEnum(look.style));
        msgDouble(self.glass, "setCornerRadius:", cornerRadius(look));
        msgBool(self.panel, "setHasShadow:", look.shadow);
        msgv(self.panel, "invalidateShadow");

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
        self.last_mode = null; // force a recolor + visibility pass next render
    }

    /// One level sample (0..1) = one new bar at the right edge. Main thread.
    pub fn pushLevel(self: *Pill, v: f32) void {
        std.mem.copyForwards(f32, self.levels[0 .. max_bars - 1], self.levels[1..]);
        self.levels[max_bars - 1] = v;
    }

    /// Reflect a mode into the layers. Called every pump tick from the main
    /// thread; `t` (seconds) drives the processing animation.
    pub fn render(self: *Pill, mode: Mode, anim: ProcessingAnim, t: f64) void {
        msgv(cls("CATransaction"), "begin");
        msgBool(cls("CATransaction"), "setDisableActions:", true); // #25: implicit anims stay OFF
        defer msgv(cls("CATransaction"), "commit");

        if (mode == .hidden) {
            if (self.shown) {
                msgv(self.panel, "orderOut:");
                self.shown = false;
                self.levels = @splat(0); // next Utterance starts from a flat line
            }
            return;
        }

        self.recolorIfNeeded(mode, anim);

        const look = self.look;
        const max_h = look.pill_h * 0.72;
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
            .processing => switch (anim) {
                // Three bouncing dots (bars hidden by recolorIfNeeded).
                .dots_accent, .dots_neutral => {
                    for (self.dots, 0..) |dot, j| {
                        const fj: f64 = @floatFromInt(j);
                        const bounce = 11.0 * @sin(t * 5.0 + fj * 0.8);
                        const dots_w = 3 * dot_size + 2 * dot_gap;
                        msgRect(dot, "setFrame:", .{
                            .x = (look.pill_w - dots_w) / 2.0 + fj * (dot_size + dot_gap),
                            .y = (look.pill_h - dot_size) / 2.0 + bounce,
                            .w = dot_size,
                            .h = dot_size,
                        });
                    }
                },
                // Glass-native: the waveform freezes where the release caught
                // it and the MATERIAL breathes — tintColor swings toward accent.
                .glass_pulse => {
                    for (0..self.nbars) |i| {
                        const lv: f64 = @floatCast(self.levels[max_bars - self.nbars + i]);
                        self.setBarHeight(i, x0, min_bar_h + lv * (max_h - min_bar_h));
                    }
                    const a = 0.18 + 0.16 * @sin(t * 3.0);
                    msg1v(self.glass, "setTintColor:", withAlpha(systemColor("controlAccentColor"), a));
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

    /// Colors + which layer family is visible change per (mode, anim) and per
    /// look switch, not per tick. System colors are re-resolved fresh on every
    /// pass — accent changes land at the next transition/show (#40 §5).
    fn recolorIfNeeded(self: *Pill, mode: Mode, anim: ProcessingAnim) void {
        if (self.last_mode == mode and self.last_anim == anim) return;
        self.last_mode = mode;
        self.last_anim = anim;

        const bar_color = switch (self.look.bars) {
            .accent => systemColor("controlAccentColor"),
            .label => systemColor("labelColor"),
            .white => msg(cls("NSColor"), "whiteColor"),
        };
        const dot_color = switch (anim) {
            .dots_accent => systemColor("controlAccentColor"),
            .dots_neutral => systemColor("secondaryLabelColor"),
            .glass_pulse => systemColor("controlAccentColor"), // unused — dots hidden
        };

        // Static tint per the Look axis; glass_pulse re-modulates it per tick
        // while processing and this pass restores it on the way back.
        const tint: id = switch (self.look.tint) {
            .none => null,
            .accent_soft => withAlpha(systemColor("controlAccentColor"), 0.25),
            .accent_strong => withAlpha(systemColor("controlAccentColor"), 0.45),
        };
        msg1v(self.glass, "setTintColor:", tint);

        const dots_mode = (mode == .processing and anim != .glass_pulse);
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
