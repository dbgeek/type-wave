//! hud.zig — the live-partials overlay HUD, driven PURELY through the ObjC runtime
//! C API (objc_getClass / sel_registerName / objc_msgSend) from Zig. No Swift, no
//! ObjC shim .m files — this is the spike that opens the map's deferred "AppKit via
//! the ObjC runtime's C interface" front (wayfinder #20).
//!
//! The msgSend pattern (cast &objc_msgSend to a typed fn-pointer per call site) is
//! the exact one already proven for NSPasteboard in
//! prototypes/insertion-spike/src/insert.zig — here extended from NSString/NSPasteboard
//! to NSPanel / NSTextField / NSColor / NSScreen / CALayer.
//!
//! ABI note: Apple Silicon (arm64) only. NSRect is a homogeneous aggregate of four
//! CGFloat(=f64), so it rides in v0–v3 and plain objc_msgSend handles both passing and
//! returning it (arm64 has no objc_msgSend_stret). type-wave is macOS-only on this Mac,
//! so that's the only target that matters.

const std = @import("std");

// ---- ObjC runtime primitives (same as insert.zig) ---------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

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
/// [[NSScreen mainScreen] frame] — NSRect returned by value (HFA, v0–v3).
inline fn mainScreenFrame() NSRect {
    const screen = msg(cls("NSScreen"), "mainScreen");
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
// Collection behavior: show on every Space, over full-screen apps, and don't move it.
const NSWindowCollectionBehaviorCanJoinAllSpaces: c_ulong = 1 << 0;
const NSWindowCollectionBehaviorStationary: c_ulong = 1 << 4;
const NSWindowCollectionBehaviorFullScreenAuxiliary: c_ulong = 1 << 8;

/// What the pill is doing — drives its colour so the state is visible at a glance.
/// Mirrors session.State's relevant cases (a real Partial Transcript exists only while
/// recording; the Final Transcript is the green flash before Insertion).
pub const State = enum { idle, recording, final };

/// The floating pill. All AppKit objects are owned by the view/window hierarchy once
/// wired up, so this struct only caches the handles the render pump pokes each tick.
pub const Hud = struct {
    panel: id = null,
    layer: id = null, // the contentView's CALayer — recoloured per State
    label: id = null, // the NSTextField showing the streaming text

    pub fn init(self: *Hud) void {
        // Bottom-centre of the main screen — the Wispr-Flow pill position.
        const sf = mainScreenFrame();
        const w: f64 = 420;
        const h: f64 = 60;
        const rect = NSRect{
            .x = sf.x + (sf.w - w) / 2.0,
            .y = sf.y + 140,
            .w = w,
            .h = h,
        };

        const panel = makePanel(
            rect,
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
        );
        self.panel = panel;

        // --- the four properties that keep it off the Focused Target (Q2) ---
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

        // Centred, bold, white label (a non-editable NSTextField).
        const label = msg1(cls("NSTextField"), "labelWithString:", nsString(" "));
        self.label = label;
        msg1v(label, "setFont:", boldSystemFont(20));
        msg1v(label, "setTextColor:", msg(cls("NSColor"), "whiteColor"));
        msgLong(label, "setAlignment:", NSTextAlignmentCenter);
        setFrame(label, NSRect{ .x = 24, .y = (h - 28) / 2.0, .w = w - 48, .h = 28 });
        msg1v(content, "addSubview:", label);

        // Show WITHOUT activating: orderFrontRegardless, never makeKeyAndOrderFront.
        msgv(panel, "orderFrontRegardless");

        self.setText(.idle, "hold to talk");
    }

    /// Update the pill: recolour by State and set the (NUL-terminated) text. Must be
    /// called on the main thread — the render pump (a CFRunLoopTimer) does exactly that.
    pub fn setText(self: *Hud, state: State, utf8: [*:0]const u8) void {
        const color = switch (state) {
            .idle => rgba(0.12, 0.12, 0.14, 0.92), // charcoal
            .recording => rgba(0.78, 0.16, 0.18, 0.95), // recording red
            .final => rgba(0.11, 0.44, 0.22, 0.95), // committed green
        };
        msg1v(self.layer, "setBackgroundColor:", cgColor(color));
        msg1v(self.label, "setStringValue:", nsString(utf8));
    }
};
