//! glass.zig — the Liquid Glass capsule HUD, PURELY through the ObjC runtime
//! C API from Zig (wayfinder #41 + #44, map #39). Throwaway prototype: wraps
//! the proven CALayer-per-bar waveform (#25) in an `NSGlassEffectView` capsule
//! (macOS 26), drops the custom red/green for system accent + semantic
//! colors, and makes every look axis live-switchable so the human can react.
//!
//! #44 adds the MOTION axes: how the capsule appears/disappears around the
//! Utterance lifecycle (pop / fade / materialize) and how recording flips to
//! processing (cut / crossfade / morph / swell). Transitions ride explicit
//! NSAnimationContext groupings and nested actions-enabled CATransactions, so
//! Core Animation interpolates in the render server — the 20 Hz pump only
//! *starts* them (and finishes deferred hides), it never steps frames.
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

// ---- animation helpers (#44): explicit groupings, immune to the pump's
// per-tick setDisableActions — window/view animator changes are explicit
// animations, and the nested transaction re-enables implicit actions for the
// raw bar/dot layers we own.
fn easeOut() id {
    const f: *const fn (id, SEL, f32, f32, f32, f32) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("CAMediaTimingFunction"), sel_registerName("functionWithControlPoints::::"), 0.17, 0.7, 0.3, 1.0);
}

/// NSAnimationContext grouping for window/view animator properties
/// (panel alphaValue, glass/content frames). Pair with animEnd().
fn animBegin(dur: f64) void {
    msgv(cls("CATransaction"), "begin");
    msgBool(cls("CATransaction"), "setDisableActions:", false);
    msgv(cls("NSAnimationContext"), "beginGrouping");
    const ctx = msg(cls("NSAnimationContext"), "currentContext");
    msgDouble(ctx, "setDuration:", dur);
    msgBool(ctx, "setAllowsImplicitAnimation:", true);
    msg1v(ctx, "setTimingFunction:", easeOut());
}
fn animEnd() void {
    msgv(cls("NSAnimationContext"), "endGrouping");
    msgv(cls("CATransaction"), "commit");
}

/// Nested CATransaction with implicit actions ON — property pokes on our raw
/// CALayers (opacity, frame) animate over `dur`. Pair with layerAnimEnd().
fn layerAnimBegin(dur: f64) void {
    msgv(cls("CATransaction"), "begin");
    msgBool(cls("CATransaction"), "setDisableActions:", false);
    msgDouble(cls("CATransaction"), "setAnimationDuration:", dur);
    msg1v(cls("CATransaction"), "setAnimationTimingFunction:", easeOut());
}
fn layerAnimEnd() void {
    msgv(cls("CATransaction"), "commit");
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

// ---- the motion axes (#44) -----------------------------------------------------

/// How the capsule appears/disappears around the Utterance lifecycle.
pub const ShowAnim = enum {
    pop, // today's hard cut: orderFront / orderOut, no motion
    fade, // window alpha 0<->1
    materialize, // glass-native: alpha fade + the capsule condenses from ~90% scale
};

/// How recording (bars) hands over to processing (dots). glass_pulse keeps
/// its bars, so these only apply to the dots processing anims.
pub const SwitchAnim = enum {
    cut, // today's hard swap
    crossfade, // bars fade out while dots fade in
    morph, // bars gather onto the three dot positions while fading
    swell, // crossfade + a one-shot accent tint swell that decays
};

pub const Motion = struct {
    show: ShowAnim = .pop,
    switch_anim: SwitchAnim = .cut,
    speed: f64 = 1.0, // multiplies every duration — slow-mo for HITL eyeballing
};

const show_dur: f64 = 0.20;
const hide_dur: f64 = 0.16;
const cross_dur: f64 = 0.22;
const morph_dur: f64 = 0.30;
const swell_dur: f64 = 0.45;
const swell_extra: f64 = 0.30; // tint alpha bump at the moment of release
const materialize_inset: f64 = 0.05; // frame inset fraction per axis (~90% scale)

pub const Look = struct {
    // Defaults are #41's locked HITL verdict: Regular glass, strong accent
    // tint, accent bars, capsule radius, shadow on, 420x60 fine bars.
    pill_w: f64 = 420,
    pill_h: f64 = 60,
    bar_w: f64 = 3,
    bar_gap: f64 = 2,
    style: GlassStyle = .regular,
    bars: BarScheme = .accent,
    tint: Tint = .accent_strong,
    radius: Radius = .capsule,
    shadow: bool = true,
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

fn fullBounds(look: Look) Rect {
    return .{ .x = 0, .y = 0, .w = look.pill_w, .h = look.pill_h };
}

/// The materialize start/end frame: centered, inset a fraction per axis.
fn insetBounds(look: Look) Rect {
    const dx = look.pill_w * materialize_inset;
    const dy = look.pill_h * materialize_inset;
    return .{ .x = dx, .y = dy, .w = look.pill_w - 2 * dx, .h = look.pill_h - 2 * dy };
}

fn baseTintAlpha(tint: Tint) f64 {
    return switch (tint) {
        .none => 0.0,
        .accent_soft => 0.25,
        .accent_strong => 0.45,
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

    // Transition state (#44). prev_mode detects mode edges; hide_at defers
    // the orderOut until the hide animation has played (the pump finishes
    // it); swell_until drives the one-shot tint swell decay.
    prev_mode: Mode = .hidden,
    hide_at: ?f64 = null,
    swell_until: f64 = 0,

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
    /// thread; `t` (seconds) drives the processing animation and finishes
    /// deferred hides; `motion` picks the #44 transition candidates.
    pub fn render(self: *Pill, mode: Mode, anim: ProcessingAnim, motion: Motion, t: f64) void {
        msgv(cls("CATransaction"), "begin");
        msgBool(cls("CATransaction"), "setDisableActions:", true); // #25: implicit anims stay OFF
        defer msgv(cls("CATransaction"), "commit");

        const from = self.prev_mode;
        const entered = (mode != from);
        self.prev_mode = mode;

        if (mode == .hidden) {
            if (self.shown and self.hide_at == null) {
                self.beginHide(motion, t);
            } else if (self.hide_at) |deadline| {
                if (t >= deadline) self.finishHide();
            }
            return;
        }

        // Re-shown mid-hide (a quick re-press): cancel the fade, snap back.
        if (self.hide_at != null) {
            self.hide_at = null;
            msgDouble(self.panel, "setAlphaValue:", 1.0);
            msgRect(self.glass, "setFrame:", fullBounds(self.look));
            msgRect(self.content, "setFrame:", fullBounds(self.look));
        }

        const recolored = self.recolorIfNeeded(mode, anim);
        if (recolored or entered) self.applyModeVisibility(mode, anim, from, entered, motion, t);

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
                // Three bouncing dots (bars handed over by applyModeVisibility).
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
                    self.swellTick(t, motion);
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

        if (!self.shown) self.beginShow(motion);
    }

    /// Order the panel front with the chosen show transition. Content for
    /// this tick is already rendered, so nothing stale flashes.
    fn beginShow(self: *Pill, motion: Motion) void {
        switch (motion.show) {
            .pop => {},
            .fade => msgDouble(self.panel, "setAlphaValue:", 0.0),
            .materialize => {
                msgDouble(self.panel, "setAlphaValue:", 0.0);
                msgRect(self.glass, "setFrame:", insetBounds(self.look));
                msgRect(self.content, "setFrame:", insetBounds(self.look));
            },
        }
        msgv(self.panel, "orderFrontRegardless"); // never makeKey — #20's recipe
        if (motion.show != .pop) {
            animBegin(show_dur * motion.speed);
            defer animEnd();
            msgDouble(msg(self.panel, "animator"), "setAlphaValue:", 1.0);
            if (motion.show == .materialize) {
                msgRect(msg(self.glass, "animator"), "setFrame:", fullBounds(self.look));
                msgRect(msg(self.content, "animator"), "setFrame:", fullBounds(self.look));
            }
        }
        self.shown = true;
    }

    /// Start the hide transition; the pump calls finishHide once the
    /// animation has played (hide_at). Pop hides immediately, like today.
    fn beginHide(self: *Pill, motion: Motion, t: f64) void {
        if (motion.show == .pop) {
            self.finishHide();
            return;
        }
        const dur = hide_dur * motion.speed;
        animBegin(dur);
        msgDouble(msg(self.panel, "animator"), "setAlphaValue:", 0.0);
        if (motion.show == .materialize) {
            msgRect(msg(self.glass, "animator"), "setFrame:", insetBounds(self.look));
            msgRect(msg(self.content, "animator"), "setFrame:", insetBounds(self.look));
        }
        animEnd();
        self.hide_at = t + dur;
    }

    /// The instant part of hiding: order out and reset every animated
    /// property so the next show starts from a clean slate.
    fn finishHide(self: *Pill) void {
        msgv(self.panel, "orderOut:");
        msgDouble(self.panel, "setAlphaValue:", 1.0);
        msgRect(self.glass, "setFrame:", fullBounds(self.look));
        msgRect(self.content, "setFrame:", fullBounds(self.look));
        self.shown = false;
        self.hide_at = null;
        self.swell_until = 0;
        self.levels = @splat(0); // next Utterance starts from a flat line
    }

    /// The swell handover: at release the tint jumps toward accent and
    /// decays back to the Look's static tint. Stepped per tick — tintColor
    /// is a view property, not a layer one, so CA can't interpolate it.
    fn swellTick(self: *Pill, t: f64, motion: Motion) void {
        if (self.swell_until == 0) return;
        if (t < self.swell_until) {
            const remain = (self.swell_until - t) / (swell_dur * motion.speed);
            const a = @min(baseTintAlpha(self.look.tint) + swell_extra * remain, 0.85);
            msg1v(self.glass, "setTintColor:", withAlpha(systemColor("controlAccentColor"), a));
        } else {
            self.swell_until = 0;
            self.applyStaticTint();
        }
    }

    /// Which layer family shows, and how the recording→processing handover
    /// animates (#44). Runs on mode/anim/look edges only, inside the pump's
    /// disabled-actions transaction — animated paths nest their own.
    fn applyModeVisibility(self: *Pill, mode: Mode, anim: ProcessingAnim, from: Mode, entered: bool, motion: Motion, t: f64) void {
        switch (mode) {
            .hidden => unreachable,
            .recording => {
                for (self.bars, 0..) |bar, i| {
                    msgFloat(bar, "setOpacity:", 1.0);
                    msgBool(bar, "setHidden:", i >= self.nbars);
                }
                for (self.dots) |dot| msgBool(dot, "setHidden:", true);
                self.swell_until = 0;
                self.applyStaticTint();
            },
            .processing => {
                if (anim == .glass_pulse) {
                    // The material does the talking — bars stay, frozen.
                    for (self.bars, 0..) |bar, i| {
                        msgFloat(bar, "setOpacity:", 1.0);
                        msgBool(bar, "setHidden:", i >= self.nbars);
                    }
                    for (self.dots) |dot| msgBool(dot, "setHidden:", true);
                    return;
                }
                const animated = entered and from == .recording and motion.switch_anim != .cut;
                if (!animated) {
                    for (self.bars) |bar| msgBool(bar, "setHidden:", true);
                    for (self.dots) |dot| {
                        msgFloat(dot, "setOpacity:", 1.0);
                        msgBool(dot, "setHidden:", false);
                    }
                    return;
                }
                // Dots start transparent, in place (instant — actions are off
                // in the enclosing pump transaction).
                for (self.dots) |dot| {
                    msgFloat(dot, "setOpacity:", 0.0);
                    msgBool(dot, "setHidden:", false);
                }
                const dur = (if (motion.switch_anim == .morph) morph_dur else cross_dur) * motion.speed;
                layerAnimBegin(dur);
                for (self.bars, 0..) |bar, i| {
                    if (i >= self.nbars) continue;
                    msgFloat(bar, "setOpacity:", 0.0);
                    if (motion.switch_anim == .morph) {
                        // Gather: the bar collapses onto the dot it's nearest
                        // to. Frames self-heal on the next recording tick —
                        // setBarHeight rewrites the full frame.
                        const j = (i * 3) / self.nbars;
                        const fj: f64 = @floatFromInt(j);
                        const dots_w = 3 * dot_size + 2 * dot_gap;
                        const dot_x = (self.look.pill_w - dots_w) / 2.0 + fj * (dot_size + dot_gap);
                        msgRect(bar, "setFrame:", .{
                            .x = dot_x + (dot_size - self.look.bar_w) / 2.0,
                            .y = (self.look.pill_h - min_bar_h) / 2.0,
                            .w = self.look.bar_w,
                            .h = min_bar_h,
                        });
                    }
                }
                for (self.dots) |dot| msgFloat(dot, "setOpacity:", 1.0);
                layerAnimEnd();
                if (motion.switch_anim == .swell) self.swell_until = t + swell_dur * motion.speed;
            },
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

    /// Colors change per (mode, anim) and per look switch, not per tick.
    /// System colors are re-resolved fresh on every pass — accent changes
    /// land at the next transition/show (#40 §5). Returns true when it ran,
    /// so the caller reapplies visibility too (visibility itself moved to
    /// applyModeVisibility for the #44 transitions).
    fn recolorIfNeeded(self: *Pill, mode: Mode, anim: ProcessingAnim) bool {
        if (self.last_mode == mode and self.last_anim == anim) return false;
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
        for (self.bars) |bar| msg1v(bar, "setBackgroundColor:", cgColor(bar_color));
        for (self.dots) |dot| msg1v(dot, "setBackgroundColor:", cgColor(dot_color));

        // Static tint per the Look axis; glass_pulse re-modulates it per tick
        // while processing and the swell decays over it — both restore here.
        self.applyStaticTint();
        return true;
    }

    fn applyStaticTint(self: *Pill) void {
        const tint: id = if (self.look.tint == .none)
            null
        else
            withAlpha(systemColor("controlAccentColor"), baseTintAlpha(self.look.tint));
        msg1v(self.glass, "setTintColor:", tint);
    }
};
