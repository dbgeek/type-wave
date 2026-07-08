//! hud.zig — the live-partials overlay HUD, driven PURELY through the ObjC runtime
//! C API (objc_getClass / sel_registerName / objc_msgSend) from Zig. No Swift, no
//! ObjC shim .m files. Graduated from prototypes/overlay-hud (wayfinder #20), which
//! proved the mechanism (Q1) and the focus-avoidance recipe (Q2), into the real
//! daemon (wayfinder #22).
//!
//! The msgSend pattern (cast &objc_msgSend to a typed fn-pointer per call site) is
//! the exact one proven for NSPasteboard in src/insert.zig, extended to NSPanel /
//! NSTextField / NSColor / NSScreen / CALayer.
//!
//! # How it composes with the daemon
//!
//!   - **All AppKit calls stay on the main thread.** The daemon's main thread runs
//!     `CFRunLoopRun` (src/tap.zig) servicing the Talk Key tap; the HUD adds a
//!     `CFRunLoopTimer` render pump to that same loop (no `[NSApp run]` — proven by
//!     #20). `init` + `startRenderPump` + every `render` tick run there.
//!   - **Producers publish from any thread.** `publish(state, text)` copies the
//!     latest (state, text) into a mutex-guarded buffer and marks it dirty; the read-
//!     loop thread (Partial/Final Transcripts, session.zig) and the run-loop thread
//!     (Talk Key press/release, daemon.zig) both call it. The render pump snapshots
//!     the buffer and reflects it into the panel — the read-loop→main-thread handoff
//!     the prototype simulated, now fed by the real transcript stream.
//!   - **Headless degrades cleanly.** `init` returns `false` when there is no display
//!     (`[NSScreen mainScreen]` is nil — e.g. a bare-SSH run); the daemon then leaves
//!     the HUD inactive and every method is a no-op, falling back to sound-only
//!     feedback (#18) without failing startup.
//!
//! ABI note: Apple Silicon (arm64) only. NSRect is a homogeneous aggregate of four
//! CGFloat(=f64), so it rides in v0–v3 and plain objc_msgSend handles both passing and
//! returning it (arm64 has no objc_msgSend_stret). type-wave is macOS-only on this Mac.

const std = @import("std");

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
// [self op:a]  (id arg) -> id
inline fn msg1(self: id, op: [*:0]const u8, a: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), a);
}
// [self op:a]  (id arg) -> void
inline fn msg1v(self: id, op: [*:0]const u8, a: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), a);
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

// ---- NSApplication activation (accessory: no Dock icon, never force-activate) ----
inline fn setActivationPolicy(app: id, policy: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(app, sel_registerName("setActivationPolicy:"), policy);
}
const NSApplicationActivationPolicyAccessory: c_long = 2;

// ---- Cocoa geometry ---------------------------------------------------------
/// NSRect == {origin{x,y}, size{w,h}}; flat here, identical layout. Four f64 = an HFA,
/// so it is passed/returned in SIMD regs by the arm64 C ABI (Zig lowers this for us).
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

/// [NSString stringWithUTF8String:s]
inline fn nsString(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSString"), sel_registerName("stringWithUTF8String:"), s);
}
/// [NSColor colorWithSRGBRed:green:blue:alpha:]
inline fn rgba(r: f64, g: f64, b: f64, a: f64) id {
    const f: *const fn (id, SEL, f64, f64, f64, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSColor"), sel_registerName("colorWithSRGBRed:green:blue:alpha:"), r, g, b, a);
}
/// CGColorRef from an NSColor — CALayer.backgroundColor wants the CG flavour.
inline fn cgColor(nscolor: id) id {
    return msg(nscolor, "CGColor");
}
/// [NSFont boldSystemFontOfSize:size]
inline fn boldSystemFont(size: f64) id {
    const f: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSFont"), sel_registerName("boldSystemFontOfSize:"), size);
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
/// [screen frame] — NSRect returned by value (HFA, v0–v3).
inline fn screenFrame(screen: id) NSRect {
    const f: *const fn (id, SEL) callconv(.c) NSRect = @ptrCast(&objc_msgSend);
    return f(screen, sel_registerName("frame"));
}
/// [view setFrame:rect]
inline fn setFrame(view: id, rect: NSRect) void {
    const f: *const fn (id, SEL, NSRect) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(view, sel_registerName("setFrame:"), rect);
}

// ---- window/style constants (AppKit headers) --------------------------------
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskNonactivatingPanel: c_ulong = 1 << 7; // the key flag: never becomes active
const NSBackingStoreBuffered: c_ulong = 2;
const NSStatusWindowLevel: c_long = 25; // floats above ordinary windows
const NSTextAlignmentCenter: c_long = 1;
const NSLineBreakByTruncatingHead: c_ulong = 3; // overflow shows the tail (latest words)
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

/// How often the render pump reflects published state into the panel. 20 Hz — smooth
/// enough for streaming partials, cheap on an idle (nothing-dirty) tick.
const render_interval_s: f64 = 0.05;

/// What the pill is doing — drives its colour and whether it is shown at all. The daemon
/// (wayfinder #22) maps its Utterance lifecycle onto these: `recording` on Talk Key press
/// and for every streaming Partial Transcript, `final` for the green Final-Transcript flash
/// (held on screen while Insertion runs), `hidden` once the Utterance resolves (inserted,
/// abandoned, empty, or timed out).
pub const State = enum { hidden, recording, final };

/// The floating pill. AppKit objects are owned by the view/window hierarchy once wired up;
/// this struct caches the handles the render pump pokes plus the mutex-guarded buffer the
/// producers publish into. A single instance lives for the daemon's process lifetime.
pub const Hud = struct {
    // ---- AppKit handles (main-thread only) ----
    panel: id = null,
    layer: id = null, // the contentView's CALayer — recoloured per State
    label: id = null, // the NSTextField showing the streaming text

    /// False until `init` succeeds; false forever on a headless start. Every public
    /// method no-ops while false, so the daemon can call them unconditionally.
    active: bool = false,

    // ---- producer → render handoff (any thread writes, main thread reads) ----
    mu: os_unfair_lock = .{},
    pending_state: State = .hidden,
    buf: [1024]u8 = undefined, // an Utterance is one hold-to-talk span; a UTF-8-safe tail past this
    len: usize = 0,
    dirty: bool = true, // start dirty so the first tick establishes the hidden baseline

    // ---- render-thread-only: what is currently on screen ----
    shown: bool = false,

    /// Backs the CFRunLoopTimer's context (it borrows `&self.timer_ctx`); lives as long
    /// as the Hud, i.e. the process. Set in `startRenderPump`.
    timer_ctx: CFRunLoopTimerContext = .{},

    /// Build the panel and bring AppKit up as an accessory app. Returns `false` when there
    /// is no display (headless) — the daemon then stays sound-only. MUST run on the main
    /// thread, before the run loop starts. Idempotent guard: a second call is a no-op.
    pub fn init(self: *Hud) bool {
        if (self.active) return true;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Shared, accessory-policy app: present UI, own no Dock icon, never force-activate.
        // Order matters — set the policy before finishLaunching so no Dock icon ever flashes.
        const app = msg(cls("NSApplication"), "sharedApplication");
        setActivationPolicy(app, NSApplicationActivationPolicyAccessory);

        // No display ⇒ no HUD. Bail before finishLaunching / any window work so a headless
        // run degrades to sound-only instead of failing (wayfinder #22).
        const screen = mainScreen();
        if (screen == null) return false;

        // finishLaunching wires up AppKit enough to draw WITHOUT [NSApp run] taking the loop
        // — the daemon's CFRunLoopRun (tap.zig) drives it (proven by #20).
        msgv(app, "finishLaunching");

        // Bottom-centre of the main screen — the Wispr-Flow pill position.
        const sf = screenFrame(screen);
        const w: f64 = 420;
        const h: f64 = 60;
        const rect = NSRect{ .x = sf.x + (sf.w - w) / 2.0, .y = sf.y + 140, .w = w, .h = h };

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

        // Transparent window so only the rounded layer shows.
        msgBool(panel, "setOpaque:", false);
        msg1v(panel, "setBackgroundColor:", msg(cls("NSColor"), "clearColor"));
        msgBool(panel, "setHasShadow:", true);

        // Rounded translucent pill = the contentView's layer.
        const content = msg(panel, "contentView");
        msgBool(content, "setWantsLayer:", true);
        const layer = msg(content, "layer");
        self.layer = layer;
        msgDouble(layer, "setCornerRadius:", h / 2.0);

        // Centred, bold, white, single-line label. Truncating-head so a long Utterance
        // shows its tail — the most recent words — rather than clipping them off-screen.
        const label = msg1(cls("NSTextField"), "labelWithString:", nsString(" "));
        self.label = label;
        msg1v(label, "setFont:", boldSystemFont(20));
        msg1v(label, "setTextColor:", msg(cls("NSColor"), "whiteColor"));
        msgLong(label, "setAlignment:", NSTextAlignmentCenter);
        msgBool(label, "setUsesSingleLineMode:", true);
        msgULong(label, "setLineBreakMode:", NSLineBreakByTruncatingHead);
        setFrame(label, NSRect{ .x = 24, .y = (h - 28) / 2.0, .w = w - 48, .h = 28 });
        msg1v(content, "addSubview:", label);

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

    /// Publish the latest (state, text). Thread-safe, no AppKit — safe to call from the
    /// read-loop thread (partials/final, session.zig) and the run-loop thread (press/
    /// release, daemon.zig). A no-op when the HUD is inactive.
    pub fn publish(self: *Hud, state: State, text: []const u8) void {
        if (!self.active) return;
        const tail = utf8SafeTail(text, self.buf.len);
        os_unfair_lock_lock(&self.mu);
        defer os_unfair_lock_unlock(&self.mu);
        self.pending_state = state;
        @memcpy(self.buf[0..tail.len], tail);
        self.len = tail.len;
        self.dirty = true;
    }

    /// Reflect the published state into the panel. Main thread only (the render pump). An
    /// autorelease pool keeps the per-tick NSString/NSColor churn from piling up.
    fn render(self: *Hud) void {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Snapshot under the lock, then release it before any AppKit — never message ObjC
        // while holding the spinlock (it would stall the read-loop producer).
        var local: [1024]u8 = undefined;
        os_unfair_lock_lock(&self.mu);
        if (!self.dirty) {
            os_unfair_lock_unlock(&self.mu);
            return;
        }
        const st = self.pending_state;
        const n = self.len;
        @memcpy(local[0..n], self.buf[0..n]);
        self.dirty = false;
        os_unfair_lock_unlock(&self.mu);

        switch (st) {
            .hidden => if (self.shown) {
                msgv(self.panel, "orderOut:");
                self.shown = false;
            },
            .recording, .final => {
                var zbuf: [1025]u8 = undefined;
                @memcpy(zbuf[0..n], local[0..n]);
                zbuf[n] = 0; // NUL-terminate for stringWithUTF8String:
                self.setText(st, zbuf[0..n :0].ptr);
                if (!self.shown) {
                    msgv(self.panel, "orderFrontRegardless");
                    self.shown = true;
                }
            },
        }
    }

    /// Recolour by State and set the (NUL-terminated) text. Main thread only.
    fn setText(self: *Hud, state: State, utf8: [*:0]const u8) void {
        const color = switch (state) {
            .hidden => rgba(0.12, 0.12, 0.14, 0.92), // unreachable via render, kept total
            .recording => rgba(0.78, 0.16, 0.18, 0.95), // recording red
            .final => rgba(0.11, 0.44, 0.22, 0.95), // committed green
        };
        msg1v(self.layer, "setBackgroundColor:", cgColor(color));
        msg1v(self.label, "setStringValue:", nsString(utf8));
    }
};

/// The last `max` bytes of `text`, advanced forward to the next UTF-8 boundary so the
/// slice never begins mid-codepoint (which would corrupt the NSString). Returns `text`
/// whole when it already fits. Showing the tail keeps the most recent words on screen as
/// a long Utterance streams.
fn utf8SafeTail(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var start = text.len - max;
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1; // skip continuation bytes
    return text[start..];
}

/// CFRunLoopTimer callout — trampolines to `render` on the main thread.
fn renderTick(_: CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *Hud = @ptrCast(@alignCast(info.?));
    self.render();
}

test "utf8SafeTail keeps whole text when it fits" {
    try std.testing.expectEqualStrings("hello", utf8SafeTail("hello", 16));
}

test "utf8SafeTail never starts mid-codepoint" {
    // "áé" is 4 bytes (0xC3 0xA1 0xC3 0xA9); a 3-byte tail would start on a continuation
    // byte, so it must advance to the next boundary (the 'é' = last 2 bytes).
    const tail = utf8SafeTail("áé", 3);
    try std.testing.expectEqualStrings("é", tail);
}
