//! hud.zig — the silent waveform pill, driven PURELY through the ObjC runtime
//! C API (objc_getClass / sel_registerName / objc_msgSend) from Zig. No Swift, no
//! ObjC shim .m files. The panel + focus-avoidance recipe graduated from
//! prototypes/overlay-hud (wayfinder #20/#22); the waveform mechanism — a fixed row
//! of plain CALayers whose frames the render pump pokes each tick — graduated from
//! prototypes/waveform-hud (wayfinder #25, into the daemon by #27); the bare-marks
//! v3 look — labelColor bars / secondaryLabelColor dots in a 300×22 sliver, no
//! glass, no accent — from prototypes/liquid-glass-hud (ADR 0002, #41/#44); and the
//! native motion — fade show/hide, bars→dots crossfade, all at the locked 0.7×
//! timings — from the same prototype (#44/#47, landed by #51): a pure `Sequencer`
//! decides each tick's transition, `render` executes it via explicit
//! NSAnimationContext / actions-enabled CATransaction groupings. The HUD
//! shows **no text, ever**: while recording it scrolls live mic volume as bars; after
//! the Talk Key release three neutral dots bounce until the Insertion resolves.
//!
//! The msgSend pattern (cast &objc_msgSend to a typed fn-pointer per call site) is
//! the exact one proven for NSPasteboard in src/insert.zig, extended to NSPanel /
//! NSColor / NSScreen / CALayer / CATransaction.
//!
//! # How it composes with the daemon
//!
//!   - **All AppKit calls stay on the main thread.** The daemon's main thread runs
//!     `CFRunLoopRun` (src/tap.zig) servicing the Talk Key tap; the HUD adds a
//!     `CFRunLoopTimer` render pump to that same loop (no `[NSApp run]` — proven by
//!     #20, and 20 Hz proven smooth for the scroll by #25). `init` +
//!     `startRenderPump` + every `render` tick run there.
//!   - **Producers publish from any thread.** `publish(state)` sets the lifecycle
//!     state; `pushLevel(rms)` queues one raw linear RMS sample per 50 ms Capture
//!     buffer from the audio queue's thread. Both are mutex-guarded, no AppKit.
//!     The render pump drains the queue and pokes the layers — a queue, not a
//!     latest-value slot, so the scroll advances exactly one bar per buffer
//!     regardless of pump jitter (#26).
//!   - **Headless degrades cleanly.** `init` returns `false` when there is no display
//!     (`[NSScreen mainScreen]` is nil — e.g. a bare-SSH run); the daemon then leaves
//!     the HUD inactive and every method is a no-op, falling back to sound-only
//!     feedback (#18) without failing startup.
//!
//! ABI note: Apple Silicon (arm64) only. NSRect is a homogeneous aggregate of four
//! CGFloat(=f64), so it rides in v0–v3 and plain objc_msgSend handles both passing and
//! returning it (arm64 has no objc_msgSend_stret). type-wave is macOS-only on this Mac.

const std = @import("std");
const appkit = @import("appkit.zig");

// ---- ObjC runtime primitives (same as insert.zig) ---------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

// os_unfair_lock: zero-initializable macOS spinlock (libSystem). Self-contained — no
// std.Io handle needed on the render/publish path (std.Thread.Mutex is gone on this
// Zig nightly and std.Io.Mutex needs an Io instance). Same guard the prototype used.
const os_unfair_lock = extern struct { _opaque: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *os_unfair_lock) void;
extern "c" fn os_unfair_lock_unlock(lock: *os_unfair_lock) void;

// ---- typed objc_msgSend shims, one per argument shape we need ----------------
// [self op]  -> id
inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
// [self op]  -> void
inline fn msgv(self: id, op: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op));
}
// [self op:a]  (id arg) -> void
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
}
// [self op:a]  (id arg) -> id
inline fn msg1(self: id, op: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), a);
}
// [self op:flag]  (BOOL) -> void
inline fn msgBool(self: id, op: [*:0]const u8, b: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), b);
}
// [self op:n]  (NSInteger) -> void
inline fn msgLong(self: id, op: [*:0]const u8, n: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), n);
}
// [self op:n]  (NSUInteger) -> void
inline fn msgULong(self: id, op: [*:0]const u8, n: c_ulong) void {
    const f: *const fn (id, SEL, c_ulong) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), n);
}
// [self op:x]  (CGFloat) -> void
inline fn msgDouble(self: id, op: [*:0]const u8, x: f64) void {
    const f: *const fn (id, SEL, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}
// [self op:x]  (C float) -> void — CALayer.opacity is a plain float, not CGFloat.
inline fn msgFloat(self: id, op: [*:0]const u8, x: f32) void {
    const f: *const fn (id, SEL, f32) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}
// [self op:rect]  (NSRect/CGRect) -> void
inline fn msgRect(self: id, op: [*:0]const u8, r: NSRect) void {
    const f: *const fn (id, SEL, NSRect) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), r);
}

// ---- Cocoa geometry ---------------------------------------------------------
/// NSRect == {origin{x,y}, size{w,h}}; flat here, identical layout. Four f64 = an HFA,
/// so it is passed/returned in SIMD regs by the arm64 C ABI (Zig lowers this for us).
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

/// A semantic NSColor (`labelColor`, `secondaryLabelColor`, …) pinned to sRGB.
/// Dynamic system colors must be converted to a component color space before
/// CGColor use, and the conversion resolves against the *current* appearance —
/// so re-resolving per recolor pass is what makes the marks track light/dark
/// with no notification wiring (ADR 0002).
inline fn systemColor(name: [*:0]const u8) id {
    const dynamic = msg(cls("NSColor"), name);
    return msg1(dynamic, "colorUsingColorSpace:", msg(cls("NSColorSpace"), "sRGBColorSpace"));
}
/// CGColorRef from an NSColor — CALayer.backgroundColor wants the CG flavour.
inline fn cgColor(nscolor: id) id {
    return msg(nscolor, "CGColor");
}
/// [[NSPanel alloc] initWithContentRect:styleMask:backing:defer:]
inline fn makePanel(rect: NSRect, style: c_ulong, backing: c_ulong) id {
    const allocd = msg(cls("NSPanel"), "alloc");
    const f: *const fn (id, SEL, NSRect, c_ulong, c_ulong, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithContentRect:styleMask:backing:defer:"), rect, style, backing, false);
}
/// [NSScreen mainScreen] — nil when there is no display (the headless signal).
inline fn mainScreen() id {
    return msg(cls("NSScreen"), "mainScreen");
}

// ---- animation helpers (#44/#47, graduated as-is): explicit groupings, immune
// to the pump's per-tick setDisableActions — window animator changes are
// explicit animations, and the nested transaction re-enables implicit actions
// for the raw bar/dot layers we own. CA interpolates in the render server.
fn easeOut() id {
    const f: *const fn (id, SEL, f32, f32, f32, f32) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("CAMediaTimingFunction"), sel_registerName("functionWithControlPoints::::"), 0.17, 0.7, 0.3, 1.0);
}

/// NSAnimationContext grouping for window animator properties (panel
/// alphaValue). Pair with animEnd().
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
/// CALayers (opacity) animate over `dur`. Pair with layerAnimEnd().
fn layerAnimBegin(dur: f64) void {
    msgv(cls("CATransaction"), "begin");
    msgBool(cls("CATransaction"), "setDisableActions:", false);
    msgDouble(cls("CATransaction"), "setAnimationDuration:", dur);
    msg1v(cls("CATransaction"), "setAnimationTimingFunction:", easeOut());
}
fn layerAnimEnd() void {
    msgv(cls("CATransaction"), "commit");
}
/// [screen frame] — NSRect returned by value (HFA, v0–v3).
inline fn screenFrame(screen: id) NSRect {
    const f: *const fn (id, SEL) callconv(.c) NSRect = @ptrCast(&objc_msgSend);
    return f(screen, sel_registerName("frame"));
}

// ---- window/style constants (AppKit headers) --------------------------------
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskNonactivatingPanel: c_ulong = 1 << 7; // the key flag: never becomes active
const NSBackingStoreBuffered: c_ulong = 2;
const NSStatusWindowLevel: c_long = 25; // floats above ordinary windows
// Collection behavior: show on every Space, over full-screen apps, and don't move it.
const NSWindowCollectionBehaviorCanJoinAllSpaces: c_ulong = 1 << 0;
const NSWindowCollectionBehaviorStationary: c_ulong = 1 << 4;
const NSWindowCollectionBehaviorFullScreenAuxiliary: c_ulong = 1 << 8;

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
extern var kCFRunLoopCommonModes: ?*anyopaque;

/// How often the render pump pokes the layers. 20 Hz — proven smooth for the scroll
/// with implicit animations off (#25), cheap on an idle (hidden) tick.
const render_interval_s: f64 = 0.05;

// ---- the look (HUD v3 bare marks — ADR 0002, HITL-locked in #41/#44; fixed, no
// config knob). Constants proven in prototypes/liquid-glass-hud. ------------------
const pill_w: f64 = 300;
const pill_h: f64 = 22;
const bar_w: f64 = 6;
const bar_gap: f64 = 4;
const pad_x: f64 = 20; // inner margin before the first / after the last bar
const min_bar_h: f64 = 3; // silence reads as a flat dotted line, not nothing
const max_bar_h: f64 = pill_h * 0.72; // headroom so a full bar never kisses the edge

// Dots scale with the pill so the 22 pt sliver doesn't clip them: full 12 pt dots
// with the 11 pt bounce would need ~34 pt of height. Same formulas the prototype
// proved; the −1 keeps a 1 pt margin under the bounce peak.
const dot_size: f64 = @min(12.0, pill_h * 0.4);
const dot_gap: f64 = dot_size * (10.0 / 12.0);
const dot_bounce: f64 = @min(11.0, (pill_h - dot_size) / 2.0 - 1.0);
const dots_row_w: f64 = 3 * dot_size + 2 * dot_gap; // the three-dot row, centred in the pill

/// How many bars fit the pill. Also how much history it shows: at one level per
/// 50 ms Capture buffer, n_bars/20 seconds scroll across it (26 bars ≈ 1.3 s).
const n_bars: usize = @intFromFloat(@floor((pill_w - 2 * pad_x + bar_gap) / (bar_w + bar_gap)));

/// What the pill is doing — drives which layer family is visible. The daemon maps its
/// Utterance lifecycle onto these: `recording` on Talk Key press (scrolling waveform),
/// `processing` on release (bouncing dots, held over the whole Insertion), `hidden`
/// once the Utterance resolves (inserted, abandoned, empty, or timed out).
pub const State = enum { hidden, recording, processing };

// ---- native motion (#44/#47, graduated): the locked 0.7× timings ------------
// Show ≈0.14 s fade-in on press, bars→dots crossfade ≈0.15 s on release,
// hide ≈0.11 s fade-out on every resolution.
const motion_speed: f64 = 0.7; // the HITL-locked speed dial (#44), baked in
const show_dur: f64 = 0.20 * motion_speed;
const hide_dur: f64 = 0.16 * motion_speed;
const cross_dur: f64 = 0.22 * motion_speed;

/// The PURE decision half of the pill's motion (the #47 prototype shape,
/// graduated): fed (published state, now) once per pump tick, it decides which
/// transition starts this tick; the AppKit executor in `render` performs it.
/// It owns the window lifecycle (shown / hide-fade deadline), so the executor
/// carries no motion state of its own. Unit-tested below by feeding
/// (state, clock) sequences and asserting decisions.
pub const Sequencer = struct {
    /// Edge detection: published state != prev_mode starts a transition.
    prev_mode: State = .hidden,
    /// Panel ordered in — true from the show-fade start until the deferred order-out.
    shown: bool = false,
    /// Hide-fade deadline; the pump orders out once now >= deadline.
    hide_at: ?f64 = null,

    /// What happens to the panel window this tick.
    pub const WindowFx = enum {
        none,
        show_fade, // alpha 0 → order front → fade to 1 (≈0.14 s)
        hide_fade, // fade to 0 (≈0.11 s); the order-out waits for the deadline
        order_out, // the hide fade has played — take the panel out, exactly once
        cancel_hide, // re-shown mid-hide-fade: snap alpha back to 1, panel never left
    };
    /// Which layer-family flip this tick performs.
    pub const MarksFx = enum {
        keep, // steady state — no visibility pokes
        bars, // cut to the waveform (a fresh Utterance)
        dots, // cut to the dots (no recording bars to fade from)
        crossfade, // release handover: bars fade out while dots fade in (≈0.15 s)
    };
    pub const Decision = struct {
        window: WindowFx = .none,
        marks: MarksFx = .keep,
    };

    pub fn step(self: *Sequencer, published: State, now: f64) Decision {
        const from = self.prev_mode;
        self.prev_mode = published;

        if (published == .hidden) {
            if (self.shown and self.hide_at == null) {
                self.hide_at = now + hide_dur;
                return .{ .window = .hide_fade };
            }
            if (self.hide_at) |deadline| {
                if (now >= deadline) {
                    self.hide_at = null;
                    self.shown = false;
                    return .{ .window = .order_out };
                }
            }
            return .{};
        }

        var window: WindowFx = .none;
        if (self.hide_at != null) {
            // A press landed while the hide fade was playing: cancel it — the
            // panel never left, so a snap-back, not a new show fade.
            self.hide_at = null;
            window = .cancel_hide;
        } else if (!self.shown) {
            self.shown = true;
            window = .show_fade;
        }
        const marks: MarksFx = if (published == from) .keep else switch (published) {
            .hidden => unreachable,
            .recording => .bars,
            .processing => if (from == .recording) .crossfade else .dots,
        };
        return .{ .window = window, .marks = marks };
    }
};

// ---- level → bar mapping (the seam carries raw linear RMS; mapping is render-side) ----
// dBFS with a floor: −60 dB → flat, −10 dB → full bar, linear in dB. Linear amplitude
// would make whispers invisible; in dB a whisper (~−48..−34 dBFS) lands at 0.25–0.5 of
// the pill — visibly alive (#25/#26). These two constants are the dogfood-retune knob.
const floor_db: f32 = -60.0;
const ceil_db: f32 = -10.0;

/// Raw linear RMS (0..1 of full scale) → bar height fraction (0..1). Pure — the one
/// place loudness becomes pixels, unit-tested below.
fn levelToNorm(rms: f32) f32 {
    const db = 20.0 * @log10(@max(rms, 0.00001));
    return std.math.clamp((db - floor_db) / (ceil_db - floor_db), 0.0, 1.0);
}

/// Capacity of the producer→render level queue. The pump drains 20×/s and Capture
/// produces 20/s, so this only buffers pump jitter; overflow drops the newest sample.
const level_queue_cap = 64;

/// The floating waveform pill. AppKit objects are owned by the view/window hierarchy once
/// wired up; this struct caches the layer handles the render pump pokes plus the mutex-
/// guarded (state, level-queue) the producers publish into. A single instance lives for
/// the daemon's process lifetime.
pub const Hud = struct {
    // ---- AppKit handles (main-thread only) ----
    panel: id = null,
    bars: [n_bars]id = @splat(null), // the waveform — heights poked per tick
    dots: [3]id = @splat(null), // the processing animation

    /// False until `init` succeeds; false forever on a headless start. Every public
    /// method no-ops while false, so the daemon can call them unconditionally.
    active: bool = false,

    // ---- producer → render handoff (any thread writes, main thread reads) ----
    mu: os_unfair_lock = .{},
    /// The live Overlay toggle (wayfinder #32/#34): a built HUD that has been switched
    /// off from the menu keeps all its machinery — no teardown path is ever exercised —
    /// but ignores lifecycle publishes, so it never shows; re-enable is instant. Guarded
    /// by `mu` like the state it gates.
    enabled: bool = true,
    pending_state: State = .hidden,
    q: [level_queue_cap]f32 = @splat(0), // raw linear RMS, one sample per Capture buffer
    qlen: usize = 0,

    // ---- render-thread-only ----
    /// The motion's decision half (#51): edge detection, window lifecycle, hide-fade
    /// deadline. `render` executes whatever it decides each tick.
    seq: Sequencer = .{},
    /// Scroll buffer of NORMALIZED heights: levels[n_bars-1] is the newest (rightmost)
    /// bar. Bars themselves never move — heights march left, one slot per sample.
    levels: [n_bars]f32 = @splat(0),

    /// Backs the CFRunLoopTimer's context (it borrows `&self.timer_ctx`); lives as long
    /// as the Hud, i.e. the process. Set in `startRenderPump`.
    timer_ctx: CFRunLoopTimerContext = .{},

    /// Build the panel + all layers (hidden) and bring AppKit up as an accessory app.
    /// Returns `false` when there is no display (headless) — the daemon then stays
    /// sound-only. MUST run on the main thread, before the run loop starts. Idempotent
    /// guard: a second call is a no-op.
    pub fn init(self: *Hud) bool {
        if (self.active) return true;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Shared, accessory-policy app (appkit.zig — also used by the menu-bar status
        // item, #34). Order matters — the policy is set before finishLaunching so no
        // Dock icon ever flashes.
        _ = appkit.app();

        // No display ⇒ no HUD. Bail before finishLaunching / any window work so a headless
        // run degrades to sound-only instead of failing (wayfinder #22).
        const screen = mainScreen();
        if (screen == null) return false;

        // finishLaunching wires up AppKit enough to draw whether the loop is the headless
        // CFRunLoopRun (proven by #20) or [NSApp run] under the status item (#31/#34).
        appkit.ensureLaunched();

        // Bottom-centre of the main screen — the Wispr-Flow pill position.
        const sf = screenFrame(screen);
        const rect = NSRect{ .x = sf.x + (sf.w - pill_w) / 2.0, .y = sf.y + 140, .w = pill_w, .h = pill_h };

        const panel = makePanel(
            rect,
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
        );
        self.panel = panel;

        // --- the properties that keep it off the Focused Target (Q2, proven by #20) ---
        msgLong(panel, "setLevel:", NSStatusWindowLevel); // always on top
        msgBool(panel, "setIgnoresMouseEvents:", true); // clicks pass straight through
        msgBool(panel, "setFloatingPanel:", true); // NSPanel: don't hide on deactivate
        msgBool(panel, "setBecomesKeyOnlyIfNeeded:", true); // NSPanel: never steal key unasked
        msgULong(
            panel,
            "setCollectionBehavior:",
            NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorStationary |
                NSWindowCollectionBehaviorFullScreenAuxiliary,
        );

        // Fully transparent window — no pill background, and no shadow: a window shadow
        // around an invisible pill draws a ghost outline (#25). Only the bars/dots show.
        msgBool(panel, "setOpaque:", false);
        msg1v(panel, "setBackgroundColor:", msg(cls("NSColor"), "clearColor"));
        msgBool(panel, "setHasShadow:", false);

        const content = msg(panel, "contentView");
        msgBool(content, "setWantsLayer:", true);
        const layer = msg(content, "layer");

        // The whole mechanism (#25): a fixed row of plain CALayers. [CALayer layer]
        // returns autoreleased; addSublayer: retains, so the hierarchy owns them after
        // this. Geometry is fixed here; colors are semantic (labelColor bars,
        // secondaryLabelColor dots — ADR 0002) and land in applyMarkColors, which
        // re-resolves them on every visible tick so they track light/dark appearance.
        const row_w = @as(f64, @floatFromInt(n_bars)) * (bar_w + bar_gap) - bar_gap;
        const x0 = (pill_w - row_w) / 2.0;
        for (&self.bars, 0..) |*bar, i| {
            bar.* = msg(cls("CALayer"), "layer");
            msgBool(bar.*, "setHidden:", true);
            msgDouble(bar.*, "setCornerRadius:", bar_w / 2.0);
            msgRect(bar.*, "setFrame:", barFrame(i, min_bar_h, x0));
            msg1v(layer, "addSublayer:", bar.*);
        }
        for (&self.dots, 0..) |*dot, j| {
            dot.* = msg(cls("CALayer"), "layer");
            msgBool(dot.*, "setHidden:", true);
            msgDouble(dot.*, "setCornerRadius:", dot_size / 2.0);
            const fj: f64 = @floatFromInt(j);
            msgRect(dot.*, "setFrame:", .{
                .x = (pill_w - dots_row_w) / 2.0 + fj * (dot_size + dot_gap),
                .y = (pill_h - dot_size) / 2.0,
                .w = dot_size,
                .h = dot_size,
            });
            msg1v(layer, "addSublayer:", dot.*);
        }

        // Built hidden — the daemon orders it in on the first Talk Key press.
        self.active = true;
        return true;
    }

    /// Add the render pump to the CURRENT run loop (the daemon's main thread, before its
    /// CFRunLoopRun). No-op if the HUD isn't active. The timer fires on the main thread, so
    /// its `renderTick` is the only place AppKit is touched after `init`.
    pub fn startRenderPump(self: *Hud) void {
        if (!self.active) return;
        self.timer_ctx = .{ .info = self };
        const timer = CFRunLoopTimerCreate(
            null,
            CFAbsoluteTimeGetCurrent() + render_interval_s,
            render_interval_s,
            0,
            0,
            renderTick,
            &self.timer_ctx,
        );
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    }

    /// Publish a lifecycle state. Thread-safe, no AppKit — called from the run-loop thread
    /// (Talk Key press/release) and wherever the Utterance resolves. A state change clears
    /// the level queue so a stale sample never bleeds into the next Utterance. A no-op when
    /// the HUD is inactive.
    pub fn publish(self: *Hud, state: State) void {
        if (!self.active) return;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        if (!self.enabled and state != .hidden) return; // switched off from the menu
        if (state != self.pending_state) self.qlen = 0;
        self.pending_state = state;
    }

    /// The menu's live Overlay toggle. Disable hides the pill immediately (the render
    /// pump keeps ticking — a hidden tick is just the lock and a state check); enable
    /// lets the next Utterance show it again. No-op while inactive (headless).
    pub fn setEnabled(self: *Hud, on: bool) void {
        if (!self.active) return;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        self.enabled = on;
        if (!on) {
            self.pending_state = .hidden;
            self.qlen = 0;
        }
    }

    /// Whether the pill is carrying feedback right now — built AND enabled. The Feedback
    /// Surface consults this per verb, so a disabled overlay falls back to sound cues
    /// exactly like an overlay=false start.
    pub fn isOn(self: *Hud) bool {
        if (!self.active) return false;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        return self.enabled;
    }

    /// Take the pill down. Called at the end of an Utterance (inserted, abandoned, empty,
    /// timed out). Since the Utterance lifecycle is fully serialized (ADR-0001) — no new
    /// `.recording` pill can exist until the current Insertion resolves — this is an
    /// unconditional hide. No-op when inactive.
    pub fn hide(self: *Hud) void {
        self.publish(.hidden);
    }

    /// Queue one raw linear RMS sample (0..1 of full scale) — one Capture buffer's
    /// loudness, i.e. one new bar. Called from the audio queue's thread; no AppKit.
    /// Dropped unless the published state is `.recording`, so a straggler buffer
    /// flushed by `capture.stop` can't repaint a processing/hidden pill.
    pub fn pushLevel(self: *Hud, rms: f32) void {
        if (!self.active) return;
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        if (self.pending_state != .recording) return;
        if (self.qlen < self.q.len) {
            self.q[self.qlen] = rms;
            self.qlen += 1;
        }
    }

    /// Reflect the published state into the layers. Main thread only (the render pump).
    /// An autorelease pool keeps the per-tick ObjC churn from piling up.
    fn render(self: *Hud) void {
        // Snapshot + drain under the lock, then release it before any AppKit — never
        // message ObjC while holding the spinlock (it would stall the audio producer).
        var drained: [level_queue_cap]f32 = undefined;
        os_unfair_lock_lock(&self.mu);
        const st = self.pending_state;
        const n = self.qlen;
        @memcpy(drained[0..n], self.q[0..n]);
        self.qlen = 0;
        os_unfair_lock_unlock(&self.mu);

        // What moves this tick — the sequencer decides, the code below executes.
        const decision = self.seq.step(st, CFAbsoluteTimeGetCurrent());

        if (st == .hidden) {
            // Only window motion happens while hidden; the marks are never touched,
            // so a hide from processing freezes the dots and fades out around them.
            switch (decision.window) {
                .hide_fade => {
                    const pool = objc_autoreleasePoolPush();
                    defer objc_autoreleasePoolPop(pool);
                    animBegin(hide_dur);
                    defer animEnd();
                    msgDouble(msg(self.panel, "animator"), "setAlphaValue:", 0.0);
                },
                .order_out => {
                    const pool = objc_autoreleasePoolPush();
                    defer objc_autoreleasePoolPop(pool);
                    msgv(self.panel, "orderOut:");
                    // Reset the animated alpha so the next show starts clean.
                    msgDouble(self.panel, "setAlphaValue:", 1.0);
                },
                // The sequencer never decides these for a hidden state; .none is
                // the idle tick (nothing on screen, or mid-fade — CA is playing it).
                .none, .show_fade, .cancel_hide => {},
            }
            return;
        }

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Batch every layer poke into one transaction with implicit animations off —
        // at 20 Hz, CA's 0.25 s implicit fades would smear the scroll (#25). The
        // transition paths nest their own actions-enabled groupings inside it.
        msgv(cls("CATransaction"), "begin");
        msgBool(cls("CATransaction"), "setDisableActions:", true);
        defer msgv(cls("CATransaction"), "commit");

        if (decision.window == .cancel_hide) {
            // A press mid-hide-fade: snap the pill back before anything repaints.
            // The direct set (not an animator group) is the prototype-proven cancel
            // — it retargets the in-flight 0.11 s fade rather than racing it (#47).
            msgDouble(self.panel, "setAlphaValue:", 1.0);
        }

        self.applyMarkColors();
        self.applyMarks(decision.marks);

        const row_w = @as(f64, @floatFromInt(n_bars)) * (bar_w + bar_gap) - bar_gap;
        const x0 = (pill_w - row_w) / 2.0;
        switch (st) {
            .hidden => unreachable,
            .recording => {
                // One drained sample = the scroll advances one bar. The dB mapping is
                // applied here, as levels come off the queue (#26).
                for (drained[0..n]) |rms| {
                    std.mem.copyForwards(f32, self.levels[0 .. n_bars - 1], self.levels[1..]);
                    self.levels[n_bars - 1] = levelToNorm(rms);
                }
                for (self.levels, 0..) |lv, i| {
                    const h = min_bar_h + @as(f64, @floatCast(lv)) * (max_bar_h - min_bar_h);
                    msgRect(self.bars[i], "setFrame:", barFrame(i, h, x0));
                }
            },
            .processing => {
                // Three bouncing neutral dots, phase-offset — held until the Insertion
                // resolves and the daemon publishes .hidden.
                const t = CFAbsoluteTimeGetCurrent();
                for (self.dots, 0..) |dot, j| {
                    const fj: f64 = @floatFromInt(j);
                    msgRect(dot, "setFrame:", .{
                        .x = (pill_w - dots_row_w) / 2.0 + fj * (dot_size + dot_gap),
                        .y = (pill_h - dot_size) / 2.0 + dot_bounce * @sin(t * 5.0 + fj * 0.8),
                        .w = dot_size,
                        .h = dot_size,
                    });
                }
            },
        }

        if (decision.window == .show_fade) {
            // This tick's content is already rendered, so nothing stale flashes.
            msgDouble(self.panel, "setAlphaValue:", 0.0);
            msgv(self.panel, "orderFrontRegardless"); // never makeKey — #20's recipe
            animBegin(show_dur);
            defer animEnd();
            msgDouble(msg(self.panel, "animator"), "setAlphaValue:", 1.0);
        }
    }

    /// Re-resolve the semantic mark colors and repaint every layer: labelColor bars,
    /// secondaryLabelColor dots (ADR 0002). Runs every visible tick — recoloring ON
    /// REPAINT is the whole appearance-tracking mechanism, so a light/dark switch
    /// lands within one tick even mid-recording or during a long processing hold,
    /// with no notification wiring. Cheap: two color resolutions and 29 autoreleased
    /// setBackgroundColor: pokes inside the tick's already-batched transaction.
    fn applyMarkColors(self: *Hud) void {
        const bar_color = cgColor(systemColor("labelColor"));
        const dot_color = cgColor(systemColor("secondaryLabelColor"));
        for (self.bars) |bar| msg1v(bar, "setBackgroundColor:", bar_color);
        for (self.dots) |dot| msg1v(dot, "setBackgroundColor:", dot_color);
    }

    /// Perform the sequencer's layer-family decision. Cuts run inside the pump's
    /// disabled-actions transaction (instant); the crossfade nests an actions-enabled
    /// transaction so CA interpolates the opacities in the render server. Steady-state
    /// ticks (`keep`) skip every visibility poke.
    fn applyMarks(self: *Hud, fx: Sequencer.MarksFx) void {
        switch (fx) {
            .keep => {},
            .bars => {
                self.levels = @splat(0); // a fresh Utterance starts from a flat line
                for (self.bars) |bar| {
                    msgFloat(bar, "setOpacity:", 1.0); // undo a played crossfade
                    msgBool(bar, "setHidden:", false);
                }
                for (self.dots) |dot| msgBool(dot, "setHidden:", true);
            },
            .dots => {
                for (self.bars) |bar| msgBool(bar, "setHidden:", true);
                for (self.dots) |dot| {
                    msgFloat(dot, "setOpacity:", 1.0);
                    msgBool(dot, "setHidden:", false);
                }
            },
            .crossfade => {
                // Dots start transparent, in place — instant, actions are off in
                // the enclosing pump transaction — then both families animate.
                for (self.dots) |dot| {
                    msgFloat(dot, "setOpacity:", 0.0);
                    msgBool(dot, "setHidden:", false);
                }
                layerAnimBegin(cross_dur);
                defer layerAnimEnd();
                for (self.bars) |bar| msgFloat(bar, "setOpacity:", 0.0);
                for (self.dots) |dot| msgFloat(dot, "setOpacity:", 1.0);
            },
        }
    }
};

/// The frame of bar `i` at height `h`, vertically centred. Bars never move in x/w —
/// only their height (and the y that keeps them centred) is poked per tick.
fn barFrame(i: usize, h: f64, x0: f64) NSRect {
    const fi: f64 = @floatFromInt(i);
    return .{
        .x = x0 + fi * (bar_w + bar_gap),
        .y = (pill_h - h) / 2.0,
        .w = bar_w,
        .h = h,
    };
}

/// CFRunLoopTimer callout — trampolines to `render` on the main thread.
fn renderTick(_: CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *Hud = @ptrCast(@alignCast(info.?));
    self.render();
}

test "bare-marks geometry: 26 bars derive from the 300 pt pill" {
    // 6 pt bars / 4 pt gaps in 300−2×20 usable points → exactly 26 bars (ADR 0002).
    try std.testing.expectEqual(@as(usize, 26), n_bars);
}

test "bare-marks geometry: dots never clip the 22 pt pill" {
    // A dot's lowest bottom edge and highest top edge over a full bounce cycle
    // both stay inside the pill.
    const bottom = (pill_h - dot_size) / 2.0 - dot_bounce;
    const top = (pill_h - dot_size) / 2.0 + dot_bounce + dot_size;
    try std.testing.expect(bottom >= 0.0);
    try std.testing.expect(top <= pill_h);
    // The three-dot row fits the pill width.
    try std.testing.expect(dots_row_w <= pill_w);
}

test "levelToNorm: floor and below read flat" {
    // −60 dBFS is rms 10^(−60/20) = 0.001; at and below it the bar is flat.
    try std.testing.expectEqual(@as(f32, 0.0), levelToNorm(0.001));
    try std.testing.expectEqual(@as(f32, 0.0), levelToNorm(0.0001));
    try std.testing.expectEqual(@as(f32, 0.0), levelToNorm(0.0)); // log10 guard: no NaN/-inf
}

test "levelToNorm: ceiling and above read full" {
    // −10 dBFS is rms 10^(−10/20) ≈ 0.3162; at and above it the bar is full.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), levelToNorm(0.3163), 0.001);
    try std.testing.expectEqual(@as(f32, 1.0), levelToNorm(1.0));
}

test "levelToNorm: linear in dB between floor and ceiling" {
    // −35 dBFS (rms ≈ 0.01778) is the midpoint of −60..−10 → half height.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), levelToNorm(0.017783), 0.001);
    // A whisper around −44 dBFS lands visibly off the floor (~0.32) — the product goal.
    try std.testing.expectApproxEqAbs(@as(f32, 0.32), levelToNorm(0.00631), 0.01);
}

// ---- the transition sequencer's decision matrix (issue #51) -----------------
// Prior art: the Coordinator's numbered lifecycle matrix. Each test feeds a
// (published state, clock) sequence into a fresh Sequencer and asserts the
// decisions — the AppKit executor is not involved.

test "motion 1: press from idle starts the show fade with bars" {
    var seq = Sequencer{};
    // Idle hidden ticks decide nothing — the panel was never shown.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 100.0));
    // Talk Key press → the pill fades in around a fresh waveform.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .show_fade, .marks = .bars },
        seq.step(.recording, 100.05),
    );
}

test "motion 2: release crossfades the bars into the dots" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    // Steady recording ticks decide nothing — the scroll is just height pokes.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.recording, 100.05));
    // Talk Key release → the handover animates; the window is untouched.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .none, .marks = .crossfade },
        seq.step(.processing, 100.10),
    );
    // Held over the Insertion: nothing more to decide.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.processing, 100.15));
}

test "motion 3: resolution starts the hide fade, order-out deferred to its deadline" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    _ = seq.step(.processing, 100.05);
    // The Utterance resolves → the fade starts; the marks stay untouched, so a
    // hide from processing freezes the dots and fades out around them.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .hide_fade, .marks = .keep },
        seq.step(.hidden, 100.10),
    );
    try std.testing.expectEqual(@as(?f64, 100.10 + hide_dur), seq.hide_at);
}

test "motion 4: order-out fires exactly once, only past the deadline" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    _ = seq.step(.processing, 100.05);
    _ = seq.step(.hidden, 100.10); // hide fade starts; deadline 100.10 + hide_dur
    // Mid-fade ticks decide nothing — the pill never disappears before the
    // fade completes.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 100.15));
    // First tick at/past the deadline orders out…
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .order_out, .marks = .keep },
        seq.step(.hidden, 100.10 + hide_dur),
    );
    // …and only that tick: hidden is idle again from here on.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 100.30));
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.hidden, 200.0));
}

test "motion 5: a press during the hide fade cancels it and records normally" {
    var seq = Sequencer{};
    _ = seq.step(.recording, 100.0);
    _ = seq.step(.processing, 100.05);
    _ = seq.step(.hidden, 100.10); // hide fade starts
    // A quick re-press mid-fade: the panel never left, so no show fade — the
    // pill snaps back and the new Utterance's waveform cuts in.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .cancel_hide, .marks = .bars },
        seq.step(.recording, 100.14),
    );
    try std.testing.expectEqual(@as(?f64, null), seq.hide_at);
    // The stale deadline must not fire into the new Utterance.
    try std.testing.expectEqual(Sequencer.Decision{}, seq.step(.recording, 100.30));
    // And the cancelled hide leaves a full cycle intact: the next resolution
    // fades out and orders out as usual.
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .hide_fade, .marks = .keep },
        seq.step(.hidden, 100.40),
    );
    try std.testing.expectEqual(
        Sequencer.Decision{ .window = .order_out, .marks = .keep },
        seq.step(.hidden, 100.40 + hide_dur),
    );
}
