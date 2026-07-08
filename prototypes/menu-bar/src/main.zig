//! menu-bar spike (wayfinder #31, map #29) — THROWAWAY.
//!
//! The question: does an `NSStatusItem` (menu-bar status item) work beside the daemon's
//! bare `CFRunLoopRun` main loop with only `finishLaunching` + accessory activation policy
//! (the exact bring-up `src/hud.zig` already proves), or does it need `[NSApp run]`? And do
//! its menu ACTIONS fire — which needs a target object, i.e. a class created at runtime via
//! `objc_allocateClassPair` + `class_addMethod`, the one ObjC-runtime facility the waveform
//! spike (#25) explicitly did NOT need. Plus the fidelity pieces to react to: checkmark
//! submenus, curated-preset submenus, the two-tier (healthy / needs-attention) icon, the
//! disabled status line, and the Set API Key… secure-field dialog.
//!
//! Everything is menu-driven — clicking the menu-bar icon IS the interaction. Each action
//! prints the full settings snapshot to the terminal (prototype rule: surface the state).
//!
//! Apple Silicon (arm64) only, same ABI notes as src/hud.zig. No Swift, no .m shims.

const std = @import("std");

// ---- ObjC runtime primitives (same as src/hud.zig) --------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

// ---- the NEW facility this spike is here to prove: define a class at runtime -----
// A menu item dispatches its action to a target object; we have no ObjC classes of our
// own, so we mint one (`TWMenuTarget : NSObject`) and hang C-ABI functions off it as
// methods. This is what the waveform spike never needed.
extern "c" fn objc_allocateClassPair(superclass: id, name: [*:0]const u8, extra: usize) id;
extern "c" fn objc_registerClassPair(cls_: id) void;
extern "c" fn class_addMethod(cls_: id, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

// ---- typed objc_msgSend shims, one per argument shape we need ----------------
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
inline fn msgLongR(self: id, op: [*:0]const u8) c_long {
    const f: *const fn (id, SEL) callconv(.c) c_long = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
}
inline fn msgDouble(self: id, op: [*:0]const u8, x: f64) void {
    const f: *const fn (id, SEL, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName(op), x);
}

// [self op:n]  (NSInteger index) -> id  (itemAtIndex:)
inline fn msgIdxId(self: id, op: [*:0]const u8, n: c_long) id {
    const f: *const fn (id, SEL, c_long) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), n);
}

// ---- NSApplication activation (accessory: no Dock icon) — as in src/hud.zig ----
inline fn setActivationPolicy(app: id, policy: c_long) void {
    const f: *const fn (id, SEL, c_long) callconv(.c) bool = @ptrCast(&objc_msgSend);
    _ = f(app, sel_registerName("setActivationPolicy:"), policy);
}
const NSApplicationActivationPolicyAccessory: c_long = 2;

// ---- geometry (NSRect: four f64, HFA, rides v0–v3 on arm64) ------------------
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

// ---- string / image / status-item helpers -----------------------------------
inline fn nsstr(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSString"), sel_registerName("stringWithUTF8String:"), s);
}
inline fn utf8(nsstring: id) [*:0]const u8 {
    const f: *const fn (id, SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc_msgSend);
    return f(nsstring, sel_registerName("UTF8String"));
}
/// [NSImage imageWithSystemSymbolName:accessibilityDescription:] — nil if the SF Symbol
/// name is unknown on this macOS; caller falls back to a text title.
inline fn sfSymbol(name: [*:0]const u8) id {
    const f: *const fn (id, SEL, id, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSImage"), sel_registerName("imageWithSystemSymbolName:accessibilityDescription:"), nsstr(name), null);
}
/// [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength]
inline fn statusItemVariable(bar: id) id {
    const f: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(bar, sel_registerName("statusItemWithLength:"), -1.0);
}
/// [[NSMenuItem alloc] initWithTitle:action:keyEquivalent:]
inline fn makeItem(title: [*:0]const u8, action: SEL) id {
    const allocd = msg(cls("NSMenuItem"), "alloc");
    const f: *const fn (id, SEL, id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithTitle:action:keyEquivalent:"), nsstr(title), action, nsstr(""));
}
inline fn newMenu() id {
    return msg(msg(cls("NSMenu"), "alloc"), "init");
}
inline fn secureField(rect: NSRect) id {
    const allocd = msg(cls("NSSecureTextField"), "alloc");
    const f: *const fn (id, SEL, NSRect) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithFrame:"), rect);
}

extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRunLoopStop(rl: ?*anyopaque) void;
extern "c" fn CFRunLoopGetMain() ?*anyopaque;

const NSControlStateOn: c_long = 1;
const NSControlStateOff: c_long = 0;
const NSAlertFirstButtonReturn: c_long = 1000;

// =====================================================================================
// The prototype's mutable state — one process-lifetime App.
// =====================================================================================

/// A radio-style setting group: a submenu whose items are mutually-exclusive choices,
/// exactly one checkmarked. `cur` is the chosen option index.
const Group = struct {
    label: [*:0]const u8, // the parent menu-item title
    opts: []const [*:0]const u8, // choice labels (the curated presets / enum vocabulary)
    cur: usize,
};

// The six radio groups — the config.zon settings the menu edits (src/config.zig / the
// tap.TalkKey, insert.Method, Settings.NoiseReduction vocab). model/language/delay are the
// "curated preset" strings the map calls for; the rest are closed enums.
const GI_TALK = 0;
const GI_MODEL = 1;
const GI_LANG = 2;
const GI_DELAY = 3;
const GI_NOISE = 4;
const GI_INSERT = 5;

var groups = [_]Group{
    .{ .label = "Talk Key", .opts = &.{ "Right Option", "Left Option", "Globe (fn)" }, .cur = 0 },
    // Curated presets decided in the #31 HITL round; exotic values stay hand-editable in config.zon.
    .{ .label = "Model", .opts = &.{"gpt-realtime-whisper"}, .cur = 0 },
    .{ .label = "Language", .opts = &.{ "en", "sv", "auto-detect" }, .cur = 0 },
    .{ .label = "Delay", .opts = &.{ "low", "medium", "high" }, .cur = 0 },
    .{ .label = "Noise reduction", .opts = &.{ "near field", "far field", "off" }, .cur = 0 },
    .{ .label = "Insertion", .opts = &.{ "paste", "keystroke" }, .cur = 0 },
};
var g_submenu: [groups.len]id = @splat(null);

/// The health/status the icon + status line reflect. `ready`/`reconnecting` are healthy;
/// `no_key`/`perm_missing` are needs-attention (dimmed icon). Paused overlays all of them.
const Status = enum { ready, reconnecting, no_key, perm_missing };
var g_status: Status = .ready;
var g_paused: bool = false;
var g_overlay: bool = true;

// AppKit handles we poke after build.
var g_button: id = null; // the status-item button (carries the icon)
var g_status_item_line: id = null; // the disabled status line at the top of the menu
var g_pause_item: id = null; // toggles its title Pause/Resume
var g_overlay_item: id = null; // checkbox
var g_target: id = null; // the runtime-minted TWMenuTarget instance (menu-action target)

fn statusText() [*:0]const u8 {
    if (g_paused) return "type-wave — Paused";
    return switch (g_status) {
        .ready => "type-wave — Ready",
        .reconnecting => "type-wave — Reconnecting\xe2\x80\xa6",
        .no_key => "type-wave — No API key",
        .perm_missing => "type-wave — Input Monitoring needed",
    };
}

fn needsAttention() bool {
    return g_paused or g_status == .no_key or g_status == .perm_missing;
}

/// Push the current (status, paused) into the icon: two-tier via SF-Symbol swap + alpha
/// dim, and refresh the disabled status-line text.
fn refreshChrome() void {
    const symbol: [*:0]const u8 = if (needsAttention()) "waveform.slash" else "waveform";
    const img = sfSymbol(symbol);
    if (img != null) {
        msgBool(img, "setTemplate:", true); // adopt the menu bar's monochrome light/dark
        msg1v(g_button, "setImage:", img);
        msg1v(g_button, "setTitle:", nsstr("")); // image wins; clear any text fallback
    } else {
        // No SF Symbols on this macOS — fall back to a text glyph so the item is still clickable.
        msg1v(g_button, "setTitle:", nsstr(if (needsAttention()) "tw!" else "tw"));
    }
    msgDouble(g_button, "setAlphaValue:", if (needsAttention()) 0.35 else 1.0);
    if (g_status_item_line != null) msg1v(g_status_item_line, "setTitle:", nsstr(statusText()));
}

fn printSnapshot(comptime what: []const u8) void {
    std.debug.print(
        \\
        \\── {s} ─────────────────────────────
        \\  status       : {s}
        \\  icon tier    : {s}
        \\  Talk Key     : {s}
        \\  Model        : {s}
        \\  Language     : {s}
        \\  Delay        : {s}
        \\  Noise reduct.: {s}
        \\  Insertion    : {s}
        \\  Overlay HUD  : {s}
        \\
    , .{
        what,
        std.mem.span(statusText()),
        if (needsAttention()) "DIMMED (needs attention)" else "normal (healthy)",
        std.mem.span(groups[GI_TALK].opts[groups[GI_TALK].cur]),
        std.mem.span(groups[GI_MODEL].opts[groups[GI_MODEL].cur]),
        std.mem.span(groups[GI_LANG].opts[groups[GI_LANG].cur]),
        std.mem.span(groups[GI_DELAY].opts[groups[GI_DELAY].cur]),
        std.mem.span(groups[GI_NOISE].opts[groups[GI_NOISE].cur]),
        std.mem.span(groups[GI_INSERT].opts[groups[GI_INSERT].cur]),
        if (g_overlay) "on" else "off",
    });
}

// =====================================================================================
// Menu-action handlers — the C-ABI functions hung off TWMenuTarget at runtime.
// Each takes (self, _cmd, sender:NSMenuItem). This is the seam the spike proves works.
// =====================================================================================

fn onRadio(_: id, _: SEL, sender: id) callconv(.c) void {
    const tag = msgLongR(sender, "tag");
    const gi: usize = @intCast(@divTrunc(tag, 100));
    const oi: usize = @intCast(@rem(tag, 100));
    groups[gi].cur = oi;
    // Re-sync the whole group's checkmarks: exactly one on.
    const sub = g_submenu[gi];
    const n = msgLongR(sub, "numberOfItems");
    var i: c_long = 0;
    while (i < n) : (i += 1) {
        const it = msgIdxId(sub, "itemAtIndex:", i);
        msgLong(it, "setState:", if (i == @as(c_long, @intCast(oi))) NSControlStateOn else NSControlStateOff);
    }
    printSnapshot("setting changed");
}

fn onOverlay(_: id, _: SEL, _: id) callconv(.c) void {
    g_overlay = !g_overlay;
    msgLong(g_overlay_item, "setState:", if (g_overlay) NSControlStateOn else NSControlStateOff);
    printSnapshot("overlay toggled");
}

fn onPause(_: id, _: SEL, _: id) callconv(.c) void {
    g_paused = !g_paused;
    msg1v(g_pause_item, "setTitle:", nsstr(if (g_paused) "Resume dictation" else "Pause dictation"));
    refreshChrome();
    printSnapshot("pause toggled");
}

/// DEBUG helper (not a shipping menu item): cycle the health status so both icon tiers and
/// every status-line string can be seen without wiring the real supervisor.
fn onCycleStatus(_: id, _: SEL, _: id) callconv(.c) void {
    g_status = switch (g_status) {
        .ready => .reconnecting,
        .reconnecting => .no_key,
        .no_key => .perm_missing,
        .perm_missing => .ready,
    };
    refreshChrome();
    printSnapshot("status cycled");
}

fn onOpenConfig(_: id, _: SEL, _: id) callconv(.c) void {
    std.debug.print("\n[Open config file] would open ~/.config/type-wave/config.zon\n", .{});
}

/// The one dialog: an NSAlert carrying an NSSecureTextField accessory. Proves a modal
/// (its own nested run loop) coexists with the status item beside CFRunLoopRun.
fn onSetApiKey(_: id, _: SEL, _: id) callconv(.c) void {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // An accessory (LSUIElement-style) app is not active, so a modal window would open
    // unfocused and swallow no keystrokes. Activate first so the secure field gets focus.
    const app = msg(cls("NSApplication"), "sharedApplication");
    msgBool(app, "activateIgnoringOtherApps:", true);

    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr("Set OpenAI API Key"));
    msg1v(alert, "setInformativeText:", nsstr("Stored in the macOS Keychain (service me.ba78.type-wave)."));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Set"));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Cancel"));

    const field = secureField(.{ .x = 0, .y = 0, .w = 260, .h = 24 });
    msg1v(alert, "setAccessoryView:", field);

    const response = msgLongR(alert, "runModal");
    if (response == NSAlertFirstButtonReturn) {
        const val = std.mem.span(utf8(msg(field, "stringValue")));
        std.debug.print("\n[Set API Key] captured a key of length {d} (would write to Keychain)\n", .{val.len});
    } else {
        std.debug.print("\n[Set API Key] cancelled\n", .{});
    }
}

fn onQuit(_: id, _: SEL, _: id) callconv(.c) void {
    std.debug.print("\n[Quit] terminating.\n", .{});
    // [NSApp run] doesn't unwind on CFRunLoopStop; terminate: is the clean GUI exit.
    // (The daemon's real Quit semantics vs. the LaunchAgent KeepAlive are ticket #34.)
    const app = msg(cls("NSApplication"), "sharedApplication");
    msg1v(app, "terminate:", null);
}

// =====================================================================================
// Build.
// =====================================================================================

/// Mint `TWMenuTarget : NSObject` and register every action selector on it. Returns an
/// instance to use as the menu items' target. This is the facility the waveform spike
/// (#25) never needed — the whole reason this is a separate spike.
fn makeTarget() id {
    const target_cls = objc_allocateClassPair(cls("NSObject"), "TWMenuTarget", 0);
    const v_at = "v@:@"; // void return; self, _cmd (SEL), one id (the sender)
    _ = class_addMethod(target_cls, sel_registerName("onRadio:"), @ptrCast(&onRadio), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOverlay:"), @ptrCast(&onOverlay), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onPause:"), @ptrCast(&onPause), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onCycleStatus:"), @ptrCast(&onCycleStatus), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOpenConfig:"), @ptrCast(&onOpenConfig), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onSetApiKey:"), @ptrCast(&onSetApiKey), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onQuit:"), @ptrCast(&onQuit), v_at);
    objc_registerClassPair(target_cls);
    return msg(msg(target_cls, "alloc"), "init");
}

/// Append a disabled item (no action, not enabled) — used for the status line.
fn addDisabled(menu: id, title: [*:0]const u8) id {
    const it = makeItem(title, null);
    msgBool(it, "setEnabled:", false);
    msg1v(menu, "addItem:", it);
    return it;
}

fn addSeparator(menu: id) void {
    msg1v(menu, "addItem:", msg(cls("NSMenuItem"), "separatorItem"));
}

/// Append `action`-wired item to `menu`, targeting g_target. Returns the item.
fn addAction(menu: id, title: [*:0]const u8, action: [*:0]const u8) id {
    const it = makeItem(title, sel_registerName(action));
    msg1v(it, "setTarget:", g_target);
    msg1v(menu, "addItem:", it);
    return it;
}

/// Build one radio group `gi` as a submenu of `menu`.
fn addRadioGroup(menu: id, gi: usize) void {
    const g = &groups[gi];
    const sub = newMenu();
    for (g.opts, 0..) |label, oi| {
        const it = makeItem(label, sel_registerName("onRadio:"));
        msg1v(it, "setTarget:", g_target);
        msgLong(it, "setTag:", @intCast(gi * 100 + oi));
        msgLong(it, "setState:", if (oi == g.cur) NSControlStateOn else NSControlStateOff);
        msg1v(sub, "addItem:", it);
    }
    const parent = makeItem(g.label, null);
    msg1v(parent, "setSubmenu:", sub);
    msg1v(menu, "addItem:", parent);
    g_submenu[gi] = sub;
}

pub fn main() void {
    std.debug.print(
        \\type-wave menu-bar spike (wayfinder #31) — look at the menu bar near the clock.
        \\Click the waveform icon to open the menu; every action prints the settings snapshot
        \\here. "DEBUG: cycle status" flips the icon between healthy and dimmed and walks the
        \\status-line strings. Quit from the menu (or Ctrl-C).
        \\
    , .{});

    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Exact bring-up src/hud.zig proves: shared accessory app + finishLaunching, NO [NSApp run].
    const app = msg(cls("NSApplication"), "sharedApplication");
    setActivationPolicy(app, NSApplicationActivationPolicyAccessory);
    msgv(app, "finishLaunching");

    g_target = makeTarget();

    // The status item + its icon.
    const bar = msg(cls("NSStatusBar"), "systemStatusBar");
    const item = statusItemVariable(bar);
    // Retain: statusItemWithLength: returns an autoreleased item that the status bar holds,
    // but we keep our own ref for the process lifetime.
    _ = msg(item, "retain");
    g_button = msg(item, "button");

    // The menu (map #29 "Menu contents" order).
    const menu = newMenu();
    g_status_item_line = addDisabled(menu, statusText());
    addSeparator(menu);
    addRadioGroup(menu, GI_TALK);
    addRadioGroup(menu, GI_MODEL);
    addRadioGroup(menu, GI_LANG);
    addRadioGroup(menu, GI_DELAY);
    addRadioGroup(menu, GI_NOISE);
    addRadioGroup(menu, GI_INSERT);
    g_overlay_item = addAction(menu, "Overlay HUD", "onOverlay:");
    msgLong(g_overlay_item, "setState:", if (g_overlay) NSControlStateOn else NSControlStateOff);
    addSeparator(menu);
    _ = addAction(menu, "Set API Key\xe2\x80\xa6", "onSetApiKey:");
    g_pause_item = addAction(menu, "Pause dictation", "onPause:");
    _ = addAction(menu, "Open config file", "onOpenConfig:");
    addSeparator(menu);
    _ = addAction(menu, "DEBUG: cycle status", "onCycleStatus:");
    addSeparator(menu);
    _ = addAction(menu, "Quit", "onQuit:");

    msg1v(item, "setMenu:", menu);

    refreshChrome(); // paint the initial (healthy) icon

    // FINDING: a bare CFRunLoopRun() (what the daemon blocks on today, src/tap.zig) spins the
    // run loop but never runs AppKit's nextEvent→sendEvent: dispatch — so status-item clicks
    // are never routed and the menu never pops. [NSApp run] runs that dispatch AND the same
    // main run loop, so the CGEventTap source + HUD CFRunLoopTimer still fire under it.
    msgv(app, "run");
    std.debug.print("run loop returned — bye.\n", .{});
}
