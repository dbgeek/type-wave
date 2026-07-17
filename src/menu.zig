//! menu.zig — the menu-bar status item (wayfinder #34; recipe graduated from
//! prototypes/menu-bar, #31). The daemon's face: a dictation icon near the clock whose
//! two tiers show healthy vs. needs-attention, and a menu that edits every `config.zon`
//! setting live (checkmark radio submenus writing the canonical file through
//! config.writeField), manages the API key (NSAlert + secure field → Keychain), and
//! offers Pause dictation / Open config file / Quit.
//!
//! Division of labour (the #32 live-apply design):
//!   - **This module is the settings writer.** A menu action builds a complete fresh
//!     `Settings`, swaps it into the daemon's `config.Store` (readers pick it up at
//!     next use), and patches `config.zon` — all on the main thread, the sole writer.
//!   - **The daemon reacts through the `Host` seam** — mark the Transcription Session
//!     params-dirty, flip the overlay HUD, store the key, pause, quit. menu.zig knows
//!     AppKit and the Store; it never touches the Session or the Coordinator directly.
//!   - **No file watcher:** `menuWillOpen:` re-reads `config.zon`, diffs, and swaps, so
//!     the checkmarks never lie and menu writes never clobber hand-edits (the write
//!     path also re-reads the file at write time). Hand-edits bind on the next menu
//!     open or restart, whichever comes first.
//!
//! Action dispatch is the #31-proven runtime-minted class: `TWMenuTarget : NSObject`
//! with C-ABI Zig fns as its methods (`objc_allocateClassPair` + `class_addMethod`).
//! A ~2 s CFRunLoopTimer ("chrome pump") re-derives the icon tier + status line from
//! the daemon's health so the icon dims/heals without the menu being opened.
//!
//! All of it runs on the main thread under `[NSApp run]` (appkit.zig). Headless (no
//! display): `init` returns false and the daemon skips the status item entirely.

const std = @import("std");
const appkit = @import("appkit.zig");
const config = @import("config.zig");
const readiness = @import("readiness.zig");
const status_item = @import("status_item.zig");
const backend = @import("transcription_backend.zig");
const tapmod = @import("tap.zig");
const insertmod = @import("insert.zig");
const keychain = @import("keychain.zig");
const feedback = @import("feedback.zig");

// ---- ObjC runtime primitives (same pattern as hud.zig / the #31 spike) -------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
extern "c" fn objc_getClass(name: [*:0]const u8) id;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called directly — cast per call site
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn objc_allocateClassPair(superclass: id, name: [*:0]const u8, extra: usize) id;
extern "c" fn objc_registerClassPair(cls_: id) void;
extern "c" fn class_addMethod(cls_: id, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

inline fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}
inline fn msg(self: id, op: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op));
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
inline fn msgIdxId(self: id, op: [*:0]const u8, n: c_long) id {
    const f: *const fn (id, SEL, c_long) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(self, sel_registerName(op), n);
}
inline fn nsstr(s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSString"), sel_registerName("stringWithUTF8String:"), s);
}
inline fn utf8(nsstring: id) [*:0]const u8 {
    const f: *const fn (id, SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc_msgSend);
    return f(nsstring, sel_registerName("UTF8String"));
}
/// [NSImage imageWithSystemSymbolName:accessibilityDescription:] — nil if the SF Symbol
/// name is unknown on this macOS; the caller falls back to a text title.
inline fn sfSymbol(name: [*:0]const u8) id {
    const f: *const fn (id, SEL, id, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSImage"), sel_registerName("imageWithSystemSymbolName:accessibilityDescription:"), nsstr(name), null);
}
/// [NSImageSymbolConfiguration configurationWithPointSize:weight:scale:]
inline fn symbolConfig(point_size: f64, weight: f64, scale: c_long) id {
    const f: *const fn (id, SEL, f64, f64, c_long) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls("NSImageSymbolConfiguration"), sel_registerName("configurationWithPointSize:weight:scale:"), point_size, weight, scale);
}
inline fn statusItemVariable(bar: id) id {
    const f: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(bar, sel_registerName("statusItemWithLength:"), -1.0); // NSVariableStatusItemLength
}
inline fn makeItem(title: [*:0]const u8, action: SEL) id {
    const allocd = msg(cls("NSMenuItem"), "alloc");
    const f: *const fn (id, SEL, id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithTitle:action:keyEquivalent:"), nsstr(title), action, nsstr(""));
}
inline fn newMenu() id {
    return msg(msg(cls("NSMenu"), "alloc"), "init");
}
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
inline fn secureField(rect: NSRect) id {
    const allocd = msg(cls("NSSecureTextField"), "alloc");
    const f: *const fn (id, SEL, NSRect) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithFrame:"), rect);
}
inline fn mainScreen() id {
    return msg(cls("NSScreen"), "mainScreen");
}

// ---- CFRunLoopTimer (the chrome pump) — same externs as hud.zig ---------------
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

/// Health re-derivation cadence. 2 s keeps the icon honest (the supervisor's own poll is
/// 3 s) while staying invisible in a profiler; TCC preflights at this rate are what the
/// supervisor already does.
const chrome_interval_s: f64 = 2.0;

const NSControlStateOn: c_long = 1;
const NSControlStateOff: c_long = 0;
const NSAlertFirstButtonReturn: c_long = 1000;

// =====================================================================================
// The daemon-facing seams.
// =====================================================================================

/// What the status line / icon tier reflect, in priority order. `paused` overlays all
/// of them (a paused daemon reads needs-attention even when otherwise healthy).
pub const Status = readiness.Status;
pub const Health = readiness.Health;
pub const ModelAction = enum {
    install,
    update,
    resume_operation,
    discard,
    verify,
    repair,
    remove,
    retry_runtime,
    cancel_operation,
    diagnostics,
    forget_hugging_face_token,
};
const ModelActionDefinition = struct { title: [*:0]const u8, action: ModelAction };
const model_action_definitions = [_]ModelActionDefinition{
    .{ .title = "Install\xe2\x80\xa6", .action = .install },
    .{ .title = "Update\xe2\x80\xa6", .action = .update },
    .{ .title = "Resume Model Operation", .action = .resume_operation },
    .{ .title = "Discard partial data\xe2\x80\xa6", .action = .discard },
    .{ .title = "Verify", .action = .verify },
    .{ .title = "Repair\xe2\x80\xa6", .action = .repair },
    .{ .title = "Remove\xe2\x80\xa6", .action = .remove },
    .{ .title = "Retry local runtime", .action = .retry_runtime },
    .{ .title = "Cancel Model Operation", .action = .cancel_operation },
    .{ .title = "Open diagnostics", .action = .diagnostics },
    .{ .title = "Forget Hugging Face token\xe2\x80\xa6", .action = .forget_hugging_face_token },
};

/// The daemon's side of the menu (wired in daemon.zig). All callbacks run on the main
/// thread, from a menu action or the chrome pump.
pub const Host = struct {
    ctx: *anyopaque,
    /// Current independent state axes for the compact hierarchy.
    status: *const fn (ctx: *anyopaque) status_item.Snapshot,
    /// A complete Settings Snapshot with a new authoritative backend was published.
    selectBackend: *const fn (ctx: *anyopaque, selected: @import("transcription_backend.zig").Backend) void,
    /// A session-shaped setting changed (menu write or hand-edit found on open) —
    /// mark the Transcription Session dirty so it cycles when idle.
    markSessionDirty: *const fn (ctx: *anyopaque) void,
    /// The Overlay toggle changed — lazy-build / enable / disable the HUD.
    setOverlay: *const fn (ctx: *anyopaque, on: bool) void,
    setPaused: *const fn (ctx: *anyopaque, paused: bool) void,
    /// Store the API key (Keychain). Returns whether the store succeeded.
    storeApiKey: *const fn (ctx: *anyopaque, key: []const u8) bool,
    storeHuggingFaceToken: *const fn (ctx: *anyopaque, token: []const u8) bool,
    modelAction: *const fn (ctx: *anyopaque, action: ModelAction) void,
    /// Menu Quit — begin the clean shutdown (ends in appkit.stop()).
    quit: *const fn (ctx: *anyopaque) void,
};

// =====================================================================================
// The six radio groups — the config.zon settings the menu edits. model/language/delay
// carry the #31-decided curated presets (exotic values stay hand-editable — a snapshot
// value matching no preset simply shows no checkmark in that group); the rest are the
// closed enums.
// =====================================================================================

const Opt = struct {
    label: [*:0]const u8,
    zon: []const u8, // the value text written into config.zon
};
const GroupDef = struct {
    title: [*:0]const u8,
    field: []const u8, // the config.zon field name
    session_shaped: bool,
    openai_only: bool = false,
    opts: []const Opt,
};

const groups = [_]GroupDef{
    .{ .title = "Transcription Backend", .field = "transcription_backend", .session_shaped = false, .opts = &.{
        .{ .label = "OpenAI", .zon = ".openai" },
        .{ .label = "Local — KB Whisper Small", .zon = ".local_kb_whisper" },
    } },
    .{ .title = "Talk Key", .field = "talk_key", .session_shaped = false, .opts = &.{
        .{ .label = "Right Option", .zon = ".right_option" },
        .{ .label = "Left Option", .zon = ".left_option" },
        .{ .label = "Globe (fn)", .zon = ".globe" },
    } },
    .{ .title = "Model", .field = "model", .session_shaped = true, .openai_only = true, .opts = &.{
        .{ .label = "gpt-realtime-whisper", .zon = "\"gpt-realtime-whisper\"" },
    } },
    .{ .title = "Language", .field = "language", .session_shaped = true, .opts = &.{
        .{ .label = "en", .zon = "\"en\"" },
        .{ .label = "sv", .zon = "\"sv\"" },
        .{ .label = "auto-detect", .zon = "\"\"" },
    } },
    .{ .title = "Delay", .field = "delay", .session_shaped = true, .openai_only = true, .opts = &.{
        .{ .label = "minimal", .zon = "\"minimal\"" },
        .{ .label = "low", .zon = "\"low\"" },
        .{ .label = "medium", .zon = "\"medium\"" },
        .{ .label = "high", .zon = "\"high\"" },
    } },
    .{ .title = "Noise reduction", .field = "noise_reduction", .session_shaped = true, .openai_only = true, .opts = &.{
        .{ .label = "near field", .zon = ".near_field" },
        .{ .label = "far field", .zon = ".far_field" },
        .{ .label = "off", .zon = ".off" },
    } },
    .{ .title = "Insertion", .field = "insertion", .session_shaped = false, .opts = &.{
        .{ .label = "paste", .zon = ".paste" },
        .{ .label = "keystroke", .zon = ".keystroke" },
    } },
};

const talk_keys = [_]tapmod.TalkKey{ .right_option, .left_option, .globe };
const backends = [_]backend.Backend{ .openai, .local_kb_whisper };
const languages = [_][]const u8{ "en", "sv", "" }; // "" = auto-detect (session omits the field)
// "minimal" earned its slot via the issue #36 benchmark: ~30-50ms faster to Final
// Transcript than "low" but measurably worse WER on quiet speech, so "low" stays the
// default and "minimal" is the one-click latency escape hatch ("xhigh" stays
// hand-edit-only). See docs/research/delay-tier-benchmark.md.
const delays = [_][]const u8{ "minimal", "low", "medium", "high" };
const noises = [_]config.Settings.NoiseReduction{ .near_field, .far_field, .off };
const insertions = [_]insertmod.Method{ .paste, .keystroke };

/// Set group `gi`'s option `oi` on a Settings under construction.
fn applyOption(s: *config.Settings, gi: usize, oi: usize) void {
    switch (gi) {
        0 => s.transcription_backend = backends[oi],
        1 => s.talk_key = talk_keys[oi],
        2 => s.model = "gpt-realtime-whisper",
        3 => s.language = languages[oi],
        4 => s.delay = delays[oi],
        5 => s.noise_reduction = noises[oi],
        6 => s.insertion = insertions[oi],
        else => unreachable,
    }
}

/// Which option of group `gi` the snapshot holds — null when a hand-edited value
/// matches no curated preset (that group then shows no checkmark).
fn currentOption(s: *const config.Settings, gi: usize) ?usize {
    switch (gi) {
        0 => for (backends, 0..) |b, i| {
            if (s.transcription_backend == b) return i;
        },
        1 => for (talk_keys, 0..) |k, i| {
            if (s.talk_key == k) return i;
        },
        2 => if (std.mem.eql(u8, s.model, "gpt-realtime-whisper")) return 0,
        3 => for (languages, 0..) |l, i| {
            if (std.mem.eql(u8, s.language, l)) return i;
        },
        4 => for (delays, 0..) |d, i| {
            if (std.mem.eql(u8, s.delay, d)) return i;
        },
        5 => for (noises, 0..) |n, i| {
            if (s.noise_reduction == n) return i;
        },
        6 => for (insertions, 0..) |m, i| {
            if (s.insertion == m) return i;
        },
        else => unreachable,
    }
    return null;
}

fn statusText(p: status_item.Presentation, selected: backend.Backend) [*:0]const u8 {
    return switch (p.headline) {
        .paused => "type-wave — Paused",
        .ready => "type-wave — OpenAI ready",
        .ready_offline => "type-wave — Ready offline",
        .preparing => if (selected == .openai) "type-wave — Reconnecting\xe2\x80\xa6" else "type-wave — Preparing local backend\xe2\x80\xa6",
        .selected_backend_prerequisite_missing => if (selected == .openai) "type-wave — No OpenAI API key" else "type-wave — No local Model Installation",
        .backend_failure => if (selected == .openai) "type-wave — OpenAI unavailable" else "type-wave — Local backend unavailable",
        .microphone_needed => "type-wave — Microphone needed",
        .input_monitoring_needed => "type-wave — Input Monitoring needed",
        .accessibility_needed => "type-wave — Accessibility needed",
    };
}

fn primaryText(action: status_item.PrimaryAction, operation: status_item.Operation) [*:0]const u8 {
    return switch (action) {
        .none => "",
        .set_openai_api_key => "Set OpenAI API key\xe2\x80\xa6",
        .install_local_model => "Install KB Whisper Small\xe2\x80\xa6",
        .update_local_model => "KB Whisper update available\xe2\x80\xa6",
        .resume_model_operation => "Resume Model Operation",
        .retry_model_operation => "Retry Model Operation",
        .repair_local_model => "Repair local model\xe2\x80\xa6",
        .retry_local_runtime => "Retry local runtime",
        .operation_progress => switch (operation) {
            .installing => "Installing KB Whisper Small\xe2\x80\xa6",
            .updating => "Staging KB Whisper update\xe2\x80\xa6",
            .verifying => "Verifying Model Installation\xe2\x80\xa6",
            .smoke_testing => "Smoke-testing Model Installation\xe2\x80\xa6",
            .waiting_for_inference => "Waiting for local inference to drain\xe2\x80\xa6",
            .activating => "Activating Model Installation\xe2\x80\xa6",
            .removing => "Removing Model Installation\xe2\x80\xa6",
            .discarding => "Discarding staged model data\xe2\x80\xa6",
            .forgetting_credential => "Forgetting Hugging Face token\xe2\x80\xa6",
            else => "Model Operation in progress\xe2\x80\xa6",
        },
    };
}

fn modelActionVisible(action: ModelAction, snapshot: status_item.Snapshot, operation_active: bool) bool {
    return switch (action) {
        .install => snapshot.installation == .absent and !operation_active,
        .update => snapshot.installation == .update_available and !operation_active,
        .resume_operation, .discard => snapshot.operation == .paused,
        .verify, .remove => snapshot.installation != .absent and !operation_active,
        .repair => snapshot.installation == .corrupt and !operation_active,
        .retry_runtime => snapshot.local_runtime_failure and !operation_active,
        .cancel_operation => operation_active,
        .diagnostics, .forget_hugging_face_token => true,
    };
}

// =====================================================================================
// The Menu. One instance for the process lifetime; the C-ABI action handlers reach it
// through the module-level pointer (they receive only ObjC's self/_cmd/sender).
// =====================================================================================

var g_menu: ?*Menu = null;

pub const Menu = struct {
    io: std.Io = undefined,
    alloc: std.mem.Allocator = undefined,
    store: *config.Store = undefined,
    host: Host = undefined,

    /// False until `init` succeeds; false forever on a headless start. The daemon then
    /// runs without a status item (and blocks on plain CFRunLoopRun, not [NSApp run]).
    active: bool = false,

    // ---- AppKit handles (main-thread only) ----
    target: id = null, // the runtime-minted TWMenuTarget instance
    button: id = null, // the status-item button (carries the icon)
    status_line: id = null, // the disabled first item
    primary_item: id = null,
    privacy_item: id = null,
    network_item: id = null,
    set_api_key_item: id = null,
    pause_item: id = null, // title flips Pause/Resume
    overlay_item: id = null, // checkbox mirror of settings.overlay
    submenu: [groups.len]id = @splat(null),
    group_parent: [groups.len]id = @splat(null),
    local_model_parent: id = null,
    local_model_status: id = null,
    local_operation_status: id = null,
    model_actions: [std.meta.fieldNames(ModelAction).len]id = @splat(null),

    last_snapshot: ?status_item.Snapshot = null,
    timer_ctx: CFRunLoopTimerContext = .{},

    /// Build the status item + menu. Main thread, before the run loop starts. Returns
    /// false when there is no display (headless) — everything then stays a no-op.
    pub fn init(self: *Menu, io: std.Io, alloc: std.mem.Allocator, store: *config.Store, host: Host) bool {
        _ = appkit.app();
        if (mainScreen() == null) return false;
        appkit.ensureLaunched();

        self.io = io;
        self.alloc = alloc;
        self.store = store;
        self.host = host;
        g_menu = self;

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        self.target = makeTarget();

        const bar = msg(cls("NSStatusBar"), "systemStatusBar");
        const item = statusItemVariable(bar);
        // statusItemWithLength: returns an autoreleased item the status bar holds; keep
        // our own ref for the process lifetime.
        _ = msg(item, "retain");
        self.button = msg(item, "button");

        const menu = newMenu();
        self.status_line = self.addDisabled(menu, "type-wave");
        addSeparator(menu);
        const snap = self.store.current();
        self.addRadioGroup(menu, 0, snap);
        self.primary_item = self.addAction(menu, "", "onPrimary:");
        self.privacy_item = self.addDisabled(menu, "Audio stays on this Mac");
        self.network_item = self.addDisabled(menu, "Network used only for this model operation");
        addSeparator(menu);
        for (1..groups.len) |gi| self.addRadioGroup(menu, gi, snap);
        self.addLocalModel(menu);
        self.overlay_item = self.addAction(menu, "Overlay HUD", "onOverlay:");
        msgLong(self.overlay_item, "setState:", if (snap.overlay) NSControlStateOn else NSControlStateOff);
        addSeparator(menu);
        self.set_api_key_item = self.addAction(menu, "Set OpenAI API Key\xe2\x80\xa6", "onSetApiKey:");
        self.pause_item = self.addAction(menu, "Pause dictation", "onPause:");
        _ = self.addAction(menu, "Open config file", "onOpenConfig:");
        addSeparator(menu);
        _ = self.addAction(menu, "Quit type-wave", "onQuit:");

        // menuWillOpen: → the refresh-on-open re-read/diff/swap (#32's no-watcher answer).
        msg1v(menu, "setDelegate:", self.target);
        msg1v(item, "setMenu:", menu);

        self.active = true;
        self.refreshChrome(); // paint the initial icon + status line

        // The chrome pump: keep the icon tier honest while the menu is closed.
        self.timer_ctx = .{ .info = self };
        const timer = CFRunLoopTimerCreate(
            null,
            CFAbsoluteTimeGetCurrent() + chrome_interval_s,
            chrome_interval_s,
            0,
            0,
            chromeTick,
            &self.timer_ctx,
        );
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
        return true;
    }

    // ---- build helpers -------------------------------------------------------------

    fn addDisabled(self: *Menu, menu: id, title: [*:0]const u8) id {
        _ = self;
        const it = makeItem(title, null);
        msgBool(it, "setEnabled:", false);
        msg1v(menu, "addItem:", it);
        return it;
    }

    fn addAction(self: *Menu, menu: id, title: [*:0]const u8, action: [*:0]const u8) id {
        const it = makeItem(title, sel_registerName(action));
        msg1v(it, "setTarget:", self.target);
        msg1v(menu, "addItem:", it);
        return it;
    }

    fn addRadioGroup(self: *Menu, menu: id, gi: usize, snap: *const config.Settings) void {
        const g = &groups[gi];
        const sub = newMenu();
        const cur = currentOption(snap, gi);
        for (g.opts, 0..) |opt, oi| {
            const it = makeItem(opt.label, sel_registerName("onRadio:"));
            msg1v(it, "setTarget:", self.target);
            msgLong(it, "setTag:", @intCast(gi * 100 + oi));
            msgLong(it, "setState:", if (cur == oi) NSControlStateOn else NSControlStateOff);
            msg1v(sub, "addItem:", it);
        }
        const parent = makeItem(g.title, null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.submenu[gi] = sub;
        self.group_parent[gi] = parent;
    }

    fn addLocalModel(self: *Menu, menu: id) void {
        const sub = newMenu();
        self.local_model_status = self.addDisabled(sub, "KB Whisper Small — not installed");
        self.local_operation_status = self.addDisabled(sub, "Model Operation — idle");
        addSeparator(sub);
        for (model_action_definitions) |definition| {
            const item = self.addAction(sub, definition.title, "onModelAction:");
            msgLong(item, "setTag:", @intFromEnum(definition.action));
            self.model_actions[@intFromEnum(definition.action)] = item;
        }
        _ = self.addAction(sub, "Set or Replace Hugging Face token\xe2\x80\xa6", "onSetHuggingFaceToken:");
        const parent = makeItem("Local Model", null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.local_model_parent = parent;
    }

    // ---- UI sync -------------------------------------------------------------------

    /// Re-checkmark group `gi` from the current snapshot.
    fn syncGroup(self: *Menu, gi: usize) void {
        const cur = currentOption(self.store.current(), gi);
        const sub = self.submenu[gi];
        const n = msgLongR(sub, "numberOfItems");
        var i: c_long = 0;
        while (i < n) : (i += 1) {
            const it = msgIdxId(sub, "itemAtIndex:", i);
            const on = cur != null and i == @as(c_long, @intCast(cur.?));
            msgLong(it, "setState:", if (on) NSControlStateOn else NSControlStateOff);
        }
    }

    /// Push the independent state axes into the compact hierarchy. Cheap when nothing
    /// changed; AppKit is touched only from the main thread.
    fn refreshChrome(self: *Menu) void {
        const snapshot = self.host.status(self.host.ctx);
        if (self.last_snapshot) |last| {
            if (std.meta.eql(last, snapshot)) return;
        }
        self.last_snapshot = snapshot;
        const h = snapshot.health;
        const presentation = status_item.derive(snapshot);
        const needs_attention = h.needsAttention() or presentation.headline == .backend_failure;

        var img = sfSymbol("waveform.badge.mic");
        if (img != null) {
            const cfg = symbolConfig(17.0, 0.0, 2); // 17 pt, regular weight, medium scale
            img = msg1(img, "imageWithSymbolConfiguration:", cfg);
            msgBool(img, "setTemplate:", true); // adopt the menu bar's monochrome light/dark
            msg1v(self.button, "setImage:", img);
            msg1v(self.button, "setTitle:", nsstr(""));
        } else {
            // No SF Symbols on this macOS — a text glyph keeps the item clickable.
            msg1v(self.button, "setTitle:", nsstr(if (needs_attention) "tw!" else "tw"));
        }
        msgDouble(self.button, "setAlphaValue:", if (needs_attention) 0.35 else 1.0);
        msg1v(self.status_line, "setTitle:", nsstr(statusText(presentation, snapshot.selected_backend)));
        msg1v(self.pause_item, "setTitle:", nsstr(if (h.paused) "Resume dictation" else "Pause dictation"));

        for (groups, 0..) |group, gi|
            if (group.openai_only) msgBool(self.group_parent[gi], "setHidden:", !presentation.show_openai_controls);
        msgBool(self.set_api_key_item, "setHidden:", !presentation.show_openai_controls);

        var progress_buffer: [160]u8 = undefined;
        const primary_title: [*:0]const u8 = if (presentation.primary_action == .operation_progress and snapshot.operation_bytes != null) title: {
            const printed = std.fmt.bufPrintSentinel(&progress_buffer, "{s} — {d}/{d} bytes", .{
                std.mem.span(primaryText(presentation.primary_action, snapshot.operation)),
                snapshot.operation_bytes.?.completed,
                snapshot.operation_bytes.?.total,
            }, 0) catch break :title primaryText(presentation.primary_action, snapshot.operation);
            break :title printed.ptr;
        } else primaryText(presentation.primary_action, snapshot.operation);
        msg1v(self.primary_item, "setTitle:", nsstr(primary_title));
        msgBool(self.primary_item, "setHidden:", presentation.primary_action == .none);
        msgBool(self.primary_item, "setEnabled:", presentation.primary_action != .operation_progress);
        msgBool(self.privacy_item, "setHidden:", !presentation.audio_stays_on_mac);
        msgBool(self.network_item, "setHidden:", !presentation.model_operation_uses_network);

        var identity_buffer: [256]u8 = undefined;
        const installation_title: [*:0]const u8 = if (snapshot.installation_identity) |identity| title: {
            const printed = std.fmt.bufPrintSentinel(&identity_buffer, "KB Whisper Small — {d} bytes — sha256 {s} — {s}", .{
                identity.size,
                &std.fmt.bytesToHex(identity.sha256, .lower),
                if (snapshot.installation == .update_available) "update available" else "installed",
            }, 0) catch break :title "KB Whisper Small — installed";
            break :title printed.ptr;
        } else switch (snapshot.installation) {
            .absent => "KB Whisper Small — not installed",
            .ready => "KB Whisper Small — installed",
            .update_available => "KB Whisper Small — update available",
            .corrupt => "KB Whisper Small — corrupt",
        };
        msg1v(self.local_model_status, "setTitle:", nsstr(installation_title));
        var operation_buffer: [160]u8 = undefined;
        const operation_title: [*:0]const u8 = if (snapshot.operation_bytes) |bytes| title: {
            const printed = std.fmt.bufPrintSentinel(&operation_buffer, "Model Operation — {s} — {d}/{d} bytes", .{ @tagName(snapshot.operation), bytes.completed, bytes.total }, 0) catch break :title "Model Operation";
            break :title printed.ptr;
        } else title: {
            const printed = std.fmt.bufPrintSentinel(&operation_buffer, "Model Operation — {s}", .{@tagName(snapshot.operation)}, 0) catch break :title "Model Operation";
            break :title printed.ptr;
        };
        msg1v(self.local_operation_status, "setTitle:", nsstr(operation_title));
        const operation_active = switch (snapshot.operation) {
            .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing, .discarding, .forgetting_credential => true,
            else => false,
        };
        for (model_action_definitions) |definition| {
            const item = self.model_actions[@intFromEnum(definition.action)];
            msgBool(item, "setHidden:", !modelActionVisible(definition.action, snapshot, operation_active));
        }
    }

    // ---- the settings write path (menu action → snapshot swap → config.zon) ---------

    /// Publish `next` as the live snapshot and persist `field = value` to config.zon.
    fn commitSettings(self: *Menu, next: config.Settings, field: []const u8, value: []const u8, session_shaped: bool) void {
        const heap = self.alloc.create(config.Settings) catch return;
        heap.* = next; // leaks by design — see config.Store
        self.store.swap(heap);
        _ = config.writeField(self.io, self.alloc, field, value, next);
        self.host.selectBackend(self.host.ctx, next.transcription_backend);
        if (session_shaped) self.host.markSessionDirty(self.host.ctx);
    }
};

fn addSeparator(menu: id) void {
    msg1v(menu, "addItem:", msg(cls("NSMenuItem"), "separatorItem"));
}

/// True when a stop was dispatched to the main thread. The daemon's quit watcher calls
/// this from its own thread on SIGINT/SIGTERM; performSelectorOnMainThread both schedules
/// and wakes the main run loop, and `twStop:` then unwinds [NSApp run] via appkit.stop().
/// False when the menu never came up (headless) — the caller falls back to CFRunLoopStop.
pub fn requestStop() bool {
    const m = g_menu orelse return false;
    if (!m.active or m.target == null) return false;
    const f: *const fn (id, SEL, SEL, id, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(m.target, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"), sel_registerName("twStop:"), null, false);
    return true;
}

// =====================================================================================
// Menu-action handlers — the C-ABI functions hung off TWMenuTarget (#31's proven seam).
// All run on the main thread. Each takes (self, _cmd, sender:NSMenuItem).
// =====================================================================================

fn onRadio(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const tag = msgLongR(sender, "tag");
    const gi: usize = @intCast(@divTrunc(tag, 100));
    const oi: usize = @intCast(@rem(tag, 100));
    const g = &groups[gi];

    var next = m.store.current().*;
    applyOption(&next, gi, oi);
    m.commitSettings(next, g.field, g.opts[oi].zon, g.session_shaped);
    m.syncGroup(gi);
    feedback.log("  menu: {s} → {s}{s}\n", .{
        g.title,                                                                 g.opts[oi].label,
        if (g.session_shaped) " (binds at the next idle session cycle)" else "",
    });
}

fn onOverlay(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    var next = m.store.current().*;
    next.overlay = !next.overlay;
    m.commitSettings(next, "overlay", if (next.overlay) "true" else "false", false);
    msgLong(m.overlay_item, "setState:", if (next.overlay) NSControlStateOn else NSControlStateOff);
    m.host.setOverlay(m.host.ctx, next.overlay);
    feedback.log("  menu: Overlay HUD → {s}\n", .{if (next.overlay) "on" else "off"});
}

fn onPause(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const h = m.host.status(m.host.ctx).health;
    m.host.setPaused(m.host.ctx, !h.paused);
    feedback.log("  menu: dictation {s}\n", .{if (!h.paused) "paused" else "resumed"});
    m.refreshChrome();
}

fn onPrimary(sender_self: id, command: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const snapshot = m.host.status(m.host.ctx);
    switch (status_item.derive(snapshot).primary_action) {
        .none, .operation_progress => {},
        .set_openai_api_key => onSetApiKey(sender_self, command, sender),
        .install_local_model => m.host.modelAction(m.host.ctx, .install),
        .update_local_model => m.host.modelAction(m.host.ctx, .update),
        .resume_model_operation => m.host.modelAction(m.host.ctx, .resume_operation),
        .retry_model_operation => m.host.modelAction(m.host.ctx, .resume_operation),
        .repair_local_model => if (confirmModelAction(.repair)) m.host.modelAction(m.host.ctx, .repair),
        .retry_local_runtime => m.host.modelAction(m.host.ctx, .retry_runtime),
    }
    m.last_snapshot = null;
    m.refreshChrome();
}

fn onModelAction(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const raw = msgLongR(sender, "tag");
    const action = std.enums.fromInt(ModelAction, raw) orelse return;
    if (!confirmModelAction(action)) return;
    m.host.modelAction(m.host.ctx, action);
    m.last_snapshot = null;
    m.refreshChrome();
}

fn confirmModelAction(action: ModelAction) bool {
    const copy: ?struct { title: [*:0]const u8, detail: [*:0]const u8, button: [*:0]const u8 } = switch (action) {
        .remove => .{
            .title = "Remove the Local Model?",
            .detail = "An active Utterance may finish before the helper unloads. Local remains selected with no OpenAI fallback. The Model Installation and staged data are removed; the Hugging Face token is preserved.",
            .button = "Remove",
        },
        .repair => .{
            .title = "Repair the Local Model?",
            .detail = "Valid local data is preserved. If authenticated network access is needed, it is used only for this Model Operation; Capture audio is never uploaded.",
            .button = "Repair",
        },
        .discard => .{
            .title = "Discard Partial Model Data?",
            .detail = "Only resumable staged data is discarded. A working Model Installation remains unchanged.",
            .button = "Discard",
        },
        .forget_hugging_face_token => .{
            .title = "Forget the Hugging Face Token?",
            .detail = "Any authenticated transfer is stopped first. Resumable staged data and the working Model Installation are preserved.",
            .button = "Forget Token",
        },
        else => null,
    };
    const content = copy orelse return true;
    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr(content.title));
    msg1v(alert, "setInformativeText:", nsstr(content.detail));
    _ = msg1(alert, "addButtonWithTitle:", nsstr(content.button));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Cancel"));
    return msgLongR(alert, "runModal") == NSAlertFirstButtonReturn;
}

fn onOpenConfig(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    var buf: [4096]u8 = undefined;
    const path = config.ensureConfigFile(m.io, m.alloc, m.store.current().*, buf[0 .. buf.len - 1]) orelse {
        feedback.log("  menu: could not create/locate config.zon\n", .{});
        return;
    };
    buf[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(path.ptr);
    const ws = msg(cls("NSWorkspace"), "sharedWorkspace");
    const opened: *const fn (id, SEL, id) callconv(.c) bool = @ptrCast(&objc_msgSend);
    if (!opened(ws, sel_registerName("openFile:"), nsstr(z)))
        feedback.log("  menu: NSWorkspace could not open {s}\n", .{path});
}

/// The one dialog: NSAlert + NSSecureTextField accessory (#31-proven, focus included).
fn onSetApiKey(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // An accessory app is not active, so the modal would open unfocused and swallow no
    // keystrokes — activate first (#31).
    msgBool(appkit.app(), "activateIgnoringOtherApps:", true);

    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr("Set OpenAI API Key"));
    msg1v(alert, "setInformativeText:", nsstr("Stored in the login keychain (service " ++ keychain.service ++ "). The daemon picks it up within a few seconds."));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Set"));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Cancel"));
    const field = secureField(.{ .x = 0, .y = 0, .w = 280, .h = 24 });
    msg1v(alert, "setAccessoryView:", field);
    msg1v(msg(alert, "window"), "setInitialFirstResponder:", field);

    if (msgLongR(alert, "runModal") != NSAlertFirstButtonReturn) return;
    const val = std.mem.trim(u8, std.mem.span(utf8(msg(field, "stringValue"))), " \t\r\n");
    if (val.len == 0) return;

    if (!m.host.storeApiKey(m.host.ctx, val)) {
        const fail = msg(msg(cls("NSAlert"), "alloc"), "init");
        msg1v(fail, "setMessageText:", nsstr("Could not store the key"));
        msg1v(fail, "setInformativeText:", nsstr("The keychain write failed — see ~/Library/Logs/type-wave.log."));
        _ = msg1(fail, "addButtonWithTitle:", nsstr("OK"));
        _ = msgLongR(fail, "runModal");
    }
}

fn onSetHuggingFaceToken(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    msgBool(appkit.app(), "activateIgnoringOtherApps:", true);

    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr("Set Hugging Face Token"));
    msg1v(alert, "setInformativeText:", nsstr("Stored separately in the login Keychain. Used only for an explicit Model Operation; Capture audio is never uploaded."));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Set"));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Cancel"));
    const field = secureField(.{ .x = 0, .y = 0, .w = 280, .h = 24 });
    msg1v(alert, "setAccessoryView:", field);
    msg1v(msg(alert, "window"), "setInitialFirstResponder:", field);
    if (msgLongR(alert, "runModal") != NSAlertFirstButtonReturn) return;
    const token = std.mem.trim(u8, std.mem.span(utf8(msg(field, "stringValue"))), " \t\r\n");
    if (token.len == 0) return;
    if (!m.host.storeHuggingFaceToken(m.host.ctx, token)) {
        const fail = msg(msg(cls("NSAlert"), "alloc"), "init");
        msg1v(fail, "setMessageText:", nsstr("Could not store the token"));
        msg1v(fail, "setInformativeText:", nsstr("The Keychain write failed — see ~/Library/Logs/type-wave.log."));
        _ = msg1(fail, "addButtonWithTitle:", nsstr("OK"));
        _ = msgLongR(fail, "runModal");
    }
}

fn onQuit(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    feedback.log("  menu: Quit — shutting down cleanly\n", .{});
    m.host.quit(m.host.ctx);
}

/// menuWillOpen: — the #32 refresh-on-open: re-read config.zon, diff against the live
/// snapshot, swap on change (hand-edits bind here), then re-sync every checkmark, the
/// status line, and the pause title so the menu never lies.
fn onMenuWillOpen(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const fresh = config.loadSettingsOnly(m.io, m.alloc);
    const cur = m.store.current();
    const d = config.diffSettings(cur, &fresh);
    if (d.any) {
        const heap = m.alloc.create(config.Settings) catch return;
        heap.* = fresh;
        m.store.swap(heap);
        feedback.log("  menu: picked up hand-edited config.zon\n", .{});
        if (d.backend_selection) m.host.selectBackend(m.host.ctx, fresh.transcription_backend);
        if (d.session_shaped) m.host.markSessionDirty(m.host.ctx);
        if (d.overlay) m.host.setOverlay(m.host.ctx, fresh.overlay);
    }
    for (0..groups.len) |gi| m.syncGroup(gi);
    msgLong(m.overlay_item, "setState:", if (m.store.current().overlay) NSControlStateOn else NSControlStateOff);
    m.last_snapshot = null; // force refresh after settings or external model-state changes
    m.refreshChrome();
}

/// twStop: — runs on the main thread via requestStop(); unwinds [NSApp run].
fn onStop(_: id, _: SEL, _: id) callconv(.c) void {
    appkit.stop();
}

/// Mint `TWMenuTarget : NSObject` and hang every action + the menu delegate method off
/// it (#31's proven runtime-class recipe). Returns the target instance.
fn makeTarget() id {
    const target_cls = objc_allocateClassPair(cls("NSObject"), "TWMenuTarget", 0);
    const v_at = "v@:@"; // void return; self, _cmd, one id (the sender)
    _ = class_addMethod(target_cls, sel_registerName("onRadio:"), @ptrCast(&onRadio), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onPrimary:"), @ptrCast(&onPrimary), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onModelAction:"), @ptrCast(&onModelAction), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOverlay:"), @ptrCast(&onOverlay), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onPause:"), @ptrCast(&onPause), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOpenConfig:"), @ptrCast(&onOpenConfig), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onSetApiKey:"), @ptrCast(&onSetApiKey), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onSetHuggingFaceToken:"), @ptrCast(&onSetHuggingFaceToken), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onQuit:"), @ptrCast(&onQuit), v_at);
    _ = class_addMethod(target_cls, sel_registerName("menuWillOpen:"), @ptrCast(&onMenuWillOpen), v_at);
    _ = class_addMethod(target_cls, sel_registerName("twStop:"), @ptrCast(&onStop), v_at);
    objc_registerClassPair(target_cls);
    return msg(msg(target_cls, "alloc"), "init");
}

/// CFRunLoopTimer callout — the chrome pump tick (main thread).
fn chromeTick(_: CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *Menu = @ptrCast(@alignCast(info.?));
    self.refreshChrome();
}
