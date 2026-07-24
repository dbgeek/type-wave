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
const vocab = @import("vocab.zig");
const recent_insertions = @import("recent_insertions.zig");

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
/// `[[Cls alloc] initWithFrame:rect]` — the API-key field and the vocabulary editor's
/// NSScrollView + NSTextView accessory (the multi-line step up, spec §3) share this.
inline fn allocInitFrame(class_name: [*:0]const u8, rect: NSRect) id {
    const allocd = msg(cls(class_name), "alloc");
    const f: *const fn (id, SEL, NSRect) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(allocd, sel_registerName("initWithFrame:"), rect);
}
inline fn secureField(rect: NSRect) id {
    return allocInitFrame("NSSecureTextField", rect);
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
const NSStatusWindowLevel: c_long = 25; // floats above ordinary windows (matches hud.zig)
const NSEventModifierFlagOption: c_long = 1 << 19; // ⌥ — the reveal chord's key-equivalent mask

/// Ephemeral per-entry reveal state for the Recent Insertions submenu (spec §4): which entries
/// the user has ⌥-clicked (or picked "Reveal text" for) to show inline. Keyed by the entry's
/// capture `timestamp` — stable across menu reopens and safe under ring shift (an evicted
/// entry's stamp simply stops matching), unlike the newest-first index, which slides as new
/// Insertions arrive. Holds **no transcript text** — reveal only flips a flag; the bytes are
/// fetched on demand via `Host.historyText`. At most `capacity` entries can be live at once.
const RevealSet = struct {
    stamps: [recent_insertions.capacity]i64 = @splat(0),
    len: usize = 0,

    fn contains(self: *const RevealSet, ts: i64) bool {
        for (self.stamps[0..self.len]) |s| {
            if (s == ts) return true;
        }
        return false;
    }

    /// Add `ts` if absent, remove it if present — the ⌥-click toggle. A full set (all
    /// `capacity` slots taken) silently ignores a new add; every real ring has ≤ capacity
    /// distinct stamps, so this only guards the degenerate case.
    fn toggle(self: *RevealSet, ts: i64) void {
        for (self.stamps[0..self.len], 0..) |s, i| {
            if (s == ts) {
                self.stamps[i] = self.stamps[self.len - 1]; // swap-remove; order is irrelevant
                self.len -= 1;
                return;
            }
        }
        if (self.len < self.stamps.len) {
            self.stamps[self.len] = ts;
            self.len += 1;
        }
    }
};

// =====================================================================================
// The daemon-facing seams.
// =====================================================================================

/// What the status line / icon tier reflect, in priority order. `paused` overlays all
/// of them (a paused daemon reads needs-attention even when otherwise healthy).
pub const Status = readiness.Status;
pub const Health = readiness.Health;
pub const ModelAction = status_item.ModelAction;
const ModelActionDefinition = struct { title: [*:0]const u8, action: ModelAction };
const model_action_definitions = [_]ModelActionDefinition{
    .{ .title = "Install\xe2\x80\xa6", .action = .install },
    .{ .title = "Update\xe2\x80\xa6", .action = .update },
    .{ .title = "Resume Model Operation", .action = .resume_operation },
    .{ .title = "Retry Model Operation", .action = .retry_operation },
    .{ .title = "Discard partial data\xe2\x80\xa6", .action = .discard },
    .{ .title = "Verify", .action = .verify },
    .{ .title = "Repair\xe2\x80\xa6", .action = .repair },
    .{ .title = "Remove\xe2\x80\xa6", .action = .remove },
    .{ .title = "Retry local runtime", .action = .retry_runtime },
    .{ .title = "Cancel Model Operation", .action = .cancel_operation },
    .{ .title = "Open diagnostics", .action = .diagnostics },
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
    modelAction: *const fn (ctx: *anyopaque, action: ModelAction) void,
    /// On-demand text fetch for one Recent Insertions entry (spec §4.1 / §5): copy the record
    /// with capture `stamp`'s `inserted` bytes into `out` under the ring's leaf lock, returning
    /// the byte count (0 if it was evicted). The reveal path reads the receipt's `inserted`
    /// bytes straight from the authoritative daemon-owned ring — never from the text-free
    /// `Snapshot` — so none of them ride the pure pipeline. Keyed by the stable `stamp`, the
    /// same identity the reveal state uses, so a concurrent Insertion can't misalign text.
    historyText: *const fn (ctx: *anyopaque, stamp: i64, out: []u8) usize,
    /// Copy one Recent Insertions entry to the clipboard (spec §5.2): resolve the record with
    /// capture `stamp` against the authoritative ring, strip the single trailing Insertion
    /// space, and put the result on the pasteboard as a permanent, normal (non-transient)
    /// entry. Runs on the insert-worker serialization so it drains any pending deferred restore
    /// first; a stamp that was evicted since the projection is a no-op. Keyed by the same stable
    /// `stamp` as `historyText`, so a concurrent Insertion can't misalign the copied text.
    copy: *const fn (ctx: *anyopaque, stamp: i64) void,
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
        .{ .label = "Local — Whisper Large v3 Turbo", .zon = ".local" },
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
const backends = [_]backend.Backend{ .openai, .local };
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

/// Disclosure line 2 beneath the Backtrack toggle. On the Local backend with Backtrack
/// on it sharpens to the "enabled but not applying" status — the toggle stays checked so
/// it can be pre-enabled for the switch to OpenAI (docs/backtrack-spec.md §Settings & UX);
/// otherwise it states the cloud/network reality, shown identically whether on or off.
fn backtrackLine2(s: *const config.Settings) [*:0]const u8 {
    if (s.transcription_backend == .local and s.backtrack)
        return "Not applying \xe2\x80\x94 needs the OpenAI backend";
    return "Needs internet; unavailable on the Local backend";
}

fn primaryText(action: status_item.PrimaryAction, operation: status_item.Operation) [*:0]const u8 {
    return switch (action) {
        .none => "",
        .set_openai_api_key => "Set OpenAI API key\xe2\x80\xa6",
        .install_local_model => "Install Whisper Large v3 Turbo\xe2\x80\xa6",
        .update_local_model => "Local model update available\xe2\x80\xa6",
        .resume_model_operation => "Resume Model Operation",
        .retry_model_operation => "Retry Model Operation",
        .repair_local_model => "Repair local model\xe2\x80\xa6",
        .retry_local_runtime => "Retry local runtime",
        .operation_progress => switch (operation) {
            .installing => "Installing Whisper Large v3 Turbo\xe2\x80\xa6",
            .updating => "Staging local model update\xe2\x80\xa6",
            .verifying => "Verifying Model Installation\xe2\x80\xa6",
            .smoke_testing => "Smoke-testing Model Installation\xe2\x80\xa6",
            .waiting_for_inference => "Waiting for local inference to drain\xe2\x80\xa6",
            .activating => "Activating Model Installation\xe2\x80\xa6",
            .removing => "Removing Model Installation\xe2\x80\xa6",
            .discarding => "Discarding staged model data\xe2\x80\xa6",
            else => "Model Operation in progress\xe2\x80\xa6",
        },
    };
}

// =====================================================================================
// Vocabulary editing (spec §3/§4) — the pure halves, kept off AppKit so they unit-test
// without a display. `onVocabulary` below is the thin ObjC glue that drives them.
// =====================================================================================

// " — local only" and "…" as UTF-8 bytes (the file's convention for the em dash / ellipsis).
const local_only_suffix = " \xe2\x80\x94 local only";
const dialog_ellipsis = "\xe2\x80\xa6";

/// The Vocabulary menu-item title from the live term count and the active backend. Local:
/// `Vocabulary (off)` / `Vocabulary (3 terms)…`. OpenAI: the same with a ` — local only`
/// suffix that replaces the disclosure ellipsis — the list is editable but inert there
/// until you switch to Local (spec §4). Static fallback on the (unreachable) format overflow.
fn vocabularyTitle(buf: []u8, count: usize, selected: backend.Backend) [:0]const u8 {
    if (count == 0)
        return std.fmt.bufPrintSentinel(buf, "Vocabulary (off){s}", .{
            if (selected == .openai) local_only_suffix else "",
        }, 0) catch "Vocabulary";
    const unit = if (count == 1) "term" else "terms";
    if (selected == .openai)
        return std.fmt.bufPrintSentinel(buf, "Vocabulary ({d} {s}){s}", .{ count, unit, local_only_suffix }, 0) catch "Vocabulary";
    return std.fmt.bufPrintSentinel(buf, "Vocabulary ({d} {s}){s}", .{ count, unit, dialog_ellipsis }, 0) catch "Vocabulary";
}

/// Split the editor's text into the entered vocabulary list (spec §3): one term per line,
/// each trimmed of surrounding whitespace, blank lines dropped. Terms are duped into `gpa`
/// so they outlive the dialog's autorelease pool once pinned in the leaked Settings
/// snapshot; the structural 100-char / 128-item clamp is `config.clampVocabulary`, applied
/// next. Caller owns the outer slice (the inner strings leak by design, config.Store's
/// model). Null on OOM.
fn parseVocabularyLines(gpa: std.mem.Allocator, text: []const u8) ?[]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const owned = gpa.dupe(u8, trimmed) catch return null;
        list.append(gpa, owned) catch return null;
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// The editor's pre-filled text — the current (already clamped) list joined one term per
/// line, so load-clamped items are visibly absent on the next open (surface-by-round-trip,
/// spec §3). Empty list → empty string (the placeholder case). Caller owns it; null on OOM.
fn prefillText(gpa: std.mem.Allocator, list: []const []const u8) ?[:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (list, 0..) |item, i| {
        if (i != 0) out.append(gpa, '\n') catch return null;
        out.appendSlice(gpa, item) catch return null;
    }
    return out.toOwnedSliceSentinel(gpa, 0) catch null;
}

/// The follow-up informational alert body when Save's structural clamp dropped items
/// (spec §3) — names the count and the caps so the user sees why terms vanished.
fn droppedItemsMessage(buf: []u8, dropped: usize) [:0]const u8 {
    const unit = if (dropped == 1) "term" else "terms";
    return std.fmt.bufPrintSentinel(buf, "Dropped {d} {s} over the limit (100 characters per term, 128 terms max). The rest were saved.", .{ dropped, unit }, 0) catch "Some terms over the limit were dropped.";
}

/// The dialog's informativeText (spec §3/§6): the always-present "one term per line"
/// guidance plus the read-at-use behaviour, and — when the current list is near/over the
/// conservative Whisper token budget (§2) — a soft, non-blocking truncation hint carrying
/// the estimate. Advisory only; Save never blocks on it.
fn vocabularyInfoText(buf: []u8, list: []const []const u8) [:0]const u8 {
    const base = "One term per line, most important first. Biases the Local (Whisper) backend at your next dictation; ignored on OpenAI.";
    return switch (vocab.budget(list)) {
        .ok => std.fmt.bufPrintSentinel(buf, "{s}", .{base}, 0) catch base,
        .near => std.fmt.bufPrintSentinel(buf, "{s} Getting long (~{d} tokens) — nearing the local Whisper limit.", .{ base, vocab.estimateTokens(list) }, 0) catch base,
        .over => std.fmt.bufPrintSentinel(buf, "{s} Long list (~{d} tokens) — the tail may be truncated for local Whisper.", .{ base, vocab.estimateTokens(list) }, 0) catch base,
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
    vocabulary_item: id = null, // title reflects the live term count + backend (spec §3/§4)
    backtrack_item: id = null, // checkbox mirror of settings.backtrack
    backtrack_cloud_item: id = null, // disclosure line 1 (static; on and off)
    backtrack_backend_item: id = null, // disclosure line 2 (swaps on Local + on)
    submenu: [groups.len]id = @splat(null),
    group_parent: [groups.len]id = @splat(null),
    local_model_parent: id = null,
    local_model_status: id = null,
    local_model_source: id = null,
    local_model_artifact: id = null,
    local_model_runtime: id = null,
    local_model_installer: id = null,
    local_operation_status: id = null,
    local_failure_status: id = null,
    model_actions: [std.meta.fieldNames(ModelAction).len]id = @splat(null),

    // ---- Recent Insertions (spec §4): fixed items, retitled/toggled per open ----
    history_parent: id = null, // the top-level "Recent Insertions ▸" item
    history_submenu: id = null, // its submenu; holds the fixed entry rows
    history_entries: [recent_insertions.capacity]id = @splat(null), // one masked-label row each
    history_alt_entries: [recent_insertions.capacity]id = @splat(null), // the ⌥-alternate twin per row (fires reveal)
    history_reveal_items: [recent_insertions.capacity]id = @splat(null), // the in-submenu "Reveal text" item per row
    reveal: RevealSet = .{}, // which entries the user has toggled to show inline (spec §4)

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
        // Backtrack sits directly beneath the Backend radio group it depends on, with two
        // always-visible disclosure lines (docs/backtrack-spec.md §Settings & UX). Unlike
        // the openai_only groups it is never hidden — hiding would erase an opted-in
        // preference — so on the Local backend it stays checked/enabled and line 2 sharpens.
        self.backtrack_item = self.addAction(menu, "Backtrack (rewrite self-corrections)", "onBacktrack:");
        self.backtrack_cloud_item = self.addDisabled(menu, "Uses OpenAI cloud \xe2\x80\x94 transcript text leaves your Mac");
        self.backtrack_backend_item = self.addDisabled(menu, ""); // wording filled by syncBacktrack
        self.syncBacktrack(); // set the toggle state + line-2 wording from the snapshot
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
        self.vocabulary_item = self.addAction(menu, "Vocabulary (off)", "onVocabulary:");
        self.syncVocabulary(); // title from the current list count + backend
        _ = self.addAction(menu, "Open config file", "onOpenConfig:");
        addSeparator(menu);
        self.addRecentInsertions(menu);
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
        self.local_model_status = self.addDisabled(sub, "Whisper Large v3 Turbo — not installed");
        self.local_model_source = self.addDisabled(sub, "");
        self.local_model_artifact = self.addDisabled(sub, "");
        self.local_model_runtime = self.addDisabled(sub, "");
        self.local_model_installer = self.addDisabled(sub, "");
        self.local_operation_status = self.addDisabled(sub, "Model Operation — idle");
        self.local_failure_status = self.addDisabled(sub, "");
        addSeparator(sub);
        for (model_action_definitions) |definition| {
            const item = self.addAction(sub, definition.title, "onModelAction:");
            msgLong(item, "setTag:", @intFromEnum(definition.action));
            self.model_actions[@intFromEnum(definition.action)] = item;
        }
        const parent = makeItem("Local Model", null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.local_model_parent = parent;
    }

    /// The **Recent Insertions ▸** submenu (spec §4). Built once with a fixed pool of
    /// `capacity` entry rows — each row is itself a submenu carrying placeholder **Copy** and
    /// **Re-insert here** items (behaviour lands in a later ticket; they stay disabled for
    /// now). Rows are retitled and shown/hidden per open by `rebuildHistory`, mirroring the
    /// codebase's "build once, toggle" idiom (no per-open allocation, no leak). Autoenable is
    /// turned off so an enabled row can carry a submenu of disabled placeholders and still
    /// open.
    fn addRecentInsertions(self: *Menu, menu: id) void {
        const sub = newMenu();
        msgBool(sub, "setAutoenablesItems:", false);
        for (0..recent_insertions.capacity) |i| {
            const row = makeItem("", null);
            const row_sub = newMenu();
            msgBool(row_sub, "setAutoenablesItems:", false);
            // Copy (spec §5.2): fires the shared `onHistoryCopy:` selector, tagged with this
            // row's fixed newest-first index — the daemon resolves it to the entry's stamp,
            // copies the trimmed `inserted` on the insert worker. Re-insert stays a disabled
            // placeholder until its own ticket wires it.
            const copy_it = makeItem("Copy", sel_registerName("onHistoryCopy:"));
            msg1v(copy_it, "setTarget:", self.target);
            msgLong(copy_it, "setTag:", @intCast(i));
            msg1v(row_sub, "addItem:", copy_it);
            const reinsert_it = makeItem("Re-insert here", null);
            msgBool(reinsert_it, "setEnabled:", false); // placeholder — wired in a later ticket
            msg1v(row_sub, "addItem:", reinsert_it);
            // "Reveal text" — the discoverable equivalent of the ⌥-click reveal (spec §4). Its
            // title flips to "Hide text" while revealed; both fire the shared `onHistoryEntry:`
            // toggle, tagged with this row's fixed newest-first index.
            const reveal_it = makeItem("Reveal text", sel_registerName("onHistoryEntry:"));
            msg1v(reveal_it, "setTarget:", self.target);
            msgLong(reveal_it, "setTag:", @intCast(i));
            msg1v(row_sub, "addItem:", reveal_it);
            self.history_reveal_items[i] = reveal_it;

            msg1v(row, "setSubmenu:", row_sub);
            msgBool(row, "setHidden:", true);
            msg1v(sub, "addItem:", row);
            self.history_entries[i] = row;

            // The Option-alternate twin, added immediately after its row with a matching (empty)
            // key equivalent and the ⌥ modifier mask: AppKit hides it at rest and swaps it in
            // for the row only while ⌥ is held, so a ⌥-click fires `onHistoryEntry:` (toggling
            // just this entry) instead of opening the row's submenu (spec §4). It carries no
            // submenu of its own precisely so the click dispatches the action.
            const alt = makeItem("", sel_registerName("onHistoryEntry:"));
            msg1v(alt, "setTarget:", self.target);
            msgLong(alt, "setTag:", @intCast(i));
            msgBool(alt, "setAlternate:", true);
            msgLong(alt, "setKeyEquivalentModifierMask:", NSEventModifierFlagOption);
            msgBool(alt, "setHidden:", true);
            msg1v(sub, "addItem:", alt);
            self.history_alt_entries[i] = alt;
        }
        const parent = makeItem("Recent Insertions", null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.history_parent = parent;
        self.history_submenu = sub;
        self.rebuildHistory(); // start life reading "No recent insertions"
    }

    /// Repopulate the Recent Insertions rows from the pure `Presentation.history` (spec §4.1):
    /// masked, newest-first, dot colour + failed/degraded tag already decided by `derive`.
    /// Called at `menuWillOpen` so relative times stay fresh — the only impure input,
    /// `feedback.nowMs()`, is read here, never in the value-compared `Snapshot`. Reuses the
    /// `Snapshot` `refreshChrome` just cached (both run on open) rather than re-reading
    /// `host.status`, which does model_store I/O; the `orelse` fetch covers the init-time
    /// resting build before the first `refreshChrome`.
    fn rebuildHistory(self: *Menu) void {
        if (self.history_parent == null) return;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const view = status_item.derive(self.last_snapshot orelse self.host.status(self.host.ctx)).history;
        if (view.count == 0) {
            // Empty ring: the parent itself reads disabled "No recent insertions" (spec §4).
            msg1v(self.history_parent, "setTitle:", nsstr("No recent insertions"));
            msgBool(self.history_parent, "setEnabled:", false);
            msg1v(self.history_parent, "setSubmenu:", null); // drop the arrow while empty
            for (self.history_entries) |row| msgBool(row, "setHidden:", true);
            for (self.history_alt_entries) |alt| msgBool(alt, "setHidden:", true);
            return;
        }
        msg1v(self.history_parent, "setTitle:", nsstr("Recent Insertions"));
        msgBool(self.history_parent, "setEnabled:", true);
        msg1v(self.history_parent, "setSubmenu:", self.history_submenu);

        const now = feedback.nowMs();
        var label_buf: [1024]u8 = undefined; // room for a revealed snippet + a long app name + metadata
        for (self.history_entries, 0..) |row, i| {
            if (i >= view.count) {
                msgBool(row, "setHidden:", true);
                msgBool(self.history_alt_entries[i], "setHidden:", true);
                continue;
            }
            const entry = view.entries[i];
            const revealed = self.reveal.contains(entry.timestamp);
            const label = if (revealed) label: {
                // On-demand text fetch (spec §4.1 / §5): the `inserted` bytes are read from the
                // authoritative ring under its leaf lock — never from the projected Snapshot —
                // keyed by the entry's stable timestamp so text can't misalign with its row.
                var text_buf: [recent_insertions.max_bytes]u8 = undefined;
                const n = self.host.historyText(self.host.ctx, entry.timestamp, &text_buf);
                break :label status_item.historyRevealedLabel(&label_buf, entry, text_buf[0..n], now);
            } else status_item.historyLabel(&label_buf, entry, now);

            msg1v(row, "setTitle:", nsstr(label.ptr));
            msgBool(row, "setHidden:", false);
            // Keep the ⌥-alternate's title in lockstep so the row doesn't jump on ⌥-hold.
            msg1v(self.history_alt_entries[i], "setTitle:", nsstr(label.ptr));
            msgBool(self.history_alt_entries[i], "setHidden:", false);
            // The in-submenu affordance mirrors the toggle state.
            msg1v(self.history_reveal_items[i], "setTitle:", nsstr(if (revealed) "Hide text" else "Reveal text"));
        }
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

    /// Re-checkmark the Backtrack toggle and set disclosure line 2 from the current
    /// snapshot. Called on menu open, on toggle, and when the backend selection changes
    /// (line 2 tracks the backend). The toggle is never disabled or hidden.
    fn syncBacktrack(self: *Menu) void {
        const snap = self.store.current();
        msgLong(self.backtrack_item, "setState:", if (snap.backtrack) NSControlStateOn else NSControlStateOff);
        msg1v(self.backtrack_backend_item, "setTitle:", nsstr(backtrackLine2(snap)));
    }

    /// Re-title the Vocabulary item from the current snapshot's term count and backend
    /// (spec §3/§4). Called on init, on Save, on a backend switch, and on menu open (to
    /// pick up a hand-edited list) — the same cadence as `syncBacktrack`.
    fn syncVocabulary(self: *Menu) void {
        const snap = self.store.current();
        var buf: [96]u8 = undefined;
        const title = vocabularyTitle(&buf, snap.vocabulary.len, snap.transcription_backend);
        msg1v(self.vocabulary_item, "setTitle:", nsstr(title.ptr));
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
        const dimmed = presentation.icon_tier == .dimmed;

        var img = sfSymbol("waveform.badge.mic");
        if (img != null) {
            const cfg = symbolConfig(17.0, 0.0, 2); // 17 pt, regular weight, medium scale
            img = msg1(img, "imageWithSymbolConfiguration:", cfg);
            msgBool(img, "setTemplate:", true); // adopt the menu bar's monochrome light/dark
            msg1v(self.button, "setImage:", img);
            msg1v(self.button, "setTitle:", nsstr(""));
        } else {
            // No SF Symbols on this macOS — a text glyph keeps the item clickable.
            msg1v(self.button, "setTitle:", nsstr(if (dimmed) "tw!" else "tw"));
        }
        msgDouble(self.button, "setAlphaValue:", if (dimmed) 0.35 else 1.0);
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

        const installation_title: [*:0]const u8 = switch (snapshot.installation) {
            .absent => "Whisper Large v3 Turbo — not installed",
            .ready => "Whisper Large v3 Turbo — installed",
            .update_available => "Whisper Large v3 Turbo — update available",
            .corrupt => "Whisper Large v3 Turbo — corrupt",
        };
        msg1v(self.local_model_status, "setTitle:", nsstr(installation_title));
        var source_buffer: [384]u8 = undefined;
        var artifact_buffer: [384]u8 = undefined;
        var runtime_buffer: [384]u8 = undefined;
        var installer_buffer: [192]u8 = undefined;
        if (snapshot.installation_identity) |identity| {
            const source = std.fmt.bufPrintSentinel(&source_buffer, "Repository — {s}@{s} — installation {s}", .{
                identity.repository.value(),
                identity.revision.value(),
                if (identity.installation_id) |installation_id| installation_id.value() else "legacy",
            }, 0) catch "Repository identity unavailable";
            const artifact = std.fmt.bufPrintSentinel(&artifact_buffer, "Artifact — {s} — {d} bytes — sha256 {s}", .{
                identity.artifact.value(),
                identity.artifact_size,
                &std.fmt.bytesToHex(identity.artifact_sha256, .lower),
            }, 0) catch "Artifact identity unavailable";
            const runtime = std.fmt.bufPrintSentinel(&runtime_buffer, "Runtime — {s} — sha256 {s}", .{
                identity.runtime.value(),
                &std.fmt.bytesToHex(identity.runtime_sha256, .lower),
            }, 0) catch "Runtime identity unavailable";
            const installer = std.fmt.bufPrintSentinel(&installer_buffer, "Installed by — {s}", .{identity.installed_by.value()}, 0) catch "Installer identity unavailable";
            msg1v(self.local_model_source, "setTitle:", nsstr(source.ptr));
            msg1v(self.local_model_artifact, "setTitle:", nsstr(artifact.ptr));
            msg1v(self.local_model_runtime, "setTitle:", nsstr(runtime.ptr));
            msg1v(self.local_model_installer, "setTitle:", nsstr(installer.ptr));
        }
        for ([_]id{ self.local_model_source, self.local_model_artifact, self.local_model_runtime, self.local_model_installer }) |item|
            msgBool(item, "setHidden:", snapshot.installation_identity == null);
        var operation_buffer: [160]u8 = undefined;
        const operation_title: [*:0]const u8 = if (snapshot.operation_bytes) |bytes| title: {
            const printed = std.fmt.bufPrintSentinel(&operation_buffer, "Model Operation — {s} — {d}/{d} bytes", .{ @tagName(snapshot.operation), bytes.completed, bytes.total }, 0) catch break :title "Model Operation";
            break :title printed.ptr;
        } else title: {
            const printed = std.fmt.bufPrintSentinel(&operation_buffer, "Model Operation — {s}", .{@tagName(snapshot.operation)}, 0) catch break :title "Model Operation";
            break :title printed.ptr;
        };
        msg1v(self.local_operation_status, "setTitle:", nsstr(operation_title));

        var failure_buffer: [512]u8 = undefined;
        const recovery: []const u8 = switch (presentation.model_failure) {
            .none => "",
            .installation_corrupt => "Repair or Remove",
            .runtime_unavailable => "Retry or Open diagnostics",
            .operation_failed => "Retry or Open diagnostics",
            .operation_cancelled => "Retry if still needed",
        };
        const failure_title: [*:0]const u8 = if (snapshot.failure_detail) |detail| title: {
            const printed = std.fmt.bufPrintSentinel(&failure_buffer, "Failure — {s} — {s}", .{ detail.value(), recovery }, 0) catch break :title "Failure — Open diagnostics";
            break :title printed.ptr;
        } else switch (presentation.model_failure) {
            .none => "",
            .installation_corrupt => "Failure — Model Installation corrupt; Repair or Remove",
            .runtime_unavailable => "Failure — Local runtime unavailable; Retry or Open diagnostics",
            .operation_failed => "Failure — Model Operation failed; Retry or Open diagnostics",
            .operation_cancelled => "Model Operation cancelled; Retry if still needed",
        };
        msg1v(self.local_failure_status, "setTitle:", nsstr(failure_title));
        msgBool(self.local_failure_status, "setHidden:", presentation.model_failure == .none);

        for (model_action_definitions) |definition| {
            const item = self.model_actions[@intFromEnum(definition.action)];
            msgBool(item, "setHidden:", !presentation.allowsModelAction(definition.action));
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
    if (gi == 0) {
        m.syncBacktrack(); // backend switch re-words Backtrack disclosure line 2
        m.syncVocabulary(); // …and flips the Vocabulary item's `— local only` suffix (§4)
    }
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

fn onBacktrack(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    var next = m.store.current().*;
    next.backtrack = !next.backtrack;
    // Read-at-use / pinned at Talk Key press — no Host callback, no session cycle.
    m.commitSettings(next, "backtrack", if (next.backtrack) "true" else "false", false);
    m.syncBacktrack(); // toggle checkmark + line-2 wording (sharpens on Local + on)
    feedback.log("  menu: Backtrack → {s}\n", .{if (next.backtrack) "on" else "off"});
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
        .install_local_model => if (confirmModelAction(.install)) m.host.modelAction(m.host.ctx, .install),
        .update_local_model => if (confirmModelAction(.update)) m.host.modelAction(m.host.ctx, .update),
        .resume_model_operation => m.host.modelAction(m.host.ctx, .resume_operation),
        .retry_model_operation => m.host.modelAction(m.host.ctx, .retry_operation),
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

/// Reveal toggle for one Recent Insertions entry (spec §4): the shared selector behind both
/// the ⌥-click alternate row and the in-submenu "Reveal text" item, dispatched with the row's
/// newest-first index in the item `tag` (mirroring `onModelAction` + `setTag:`). It resolves
/// the index to the entry's stable `timestamp` off the current view, flips its reveal flag, and
/// re-renders so the next open shows (or re-masks) that one row's text — no transcript byte is
/// touched here; `rebuildHistory` fetches it on demand only for a revealed row.
fn onHistoryEntry(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const raw = msgLongR(sender, "tag");
    if (raw < 0) return;
    const i: usize = @intCast(raw);
    const view = status_item.derive(m.last_snapshot orelse m.host.status(m.host.ctx)).history;
    if (i >= view.count) return;
    m.reveal.toggle(view.entries[i].timestamp);
    m.rebuildHistory();
}

/// Copy one Recent Insertions entry to the clipboard (spec §5.2): the per-entry Copy item's
/// selector, dispatched with the row's newest-first index in the item `tag` (mirroring
/// `onHistoryEntry:`). It resolves the index to the entry's stable `timestamp` off the current
/// view and hands it to `host.copy`; the daemon fetches + trims the text and does the pasteboard
/// write on the insert worker. No transcript byte is touched here — the menu only dispatches.
fn onHistoryCopy(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const raw = msgLongR(sender, "tag");
    if (raw < 0) return;
    const i: usize = @intCast(raw);
    const view = status_item.derive(m.last_snapshot orelse m.host.status(m.host.ctx)).history;
    if (i >= view.count) return;
    m.host.copy(m.host.ctx, view.entries[i].timestamp);
}

const ModelActionConfirmation = struct {
    title: [*:0]const u8,
    detail: [*:0]const u8,
    button: [*:0]const u8,
};

fn confirmationForModelAction(action: ModelAction) ?ModelActionConfirmation {
    return switch (action) {
        .install => .{
            .title = "Install Whisper Large v3 Turbo?",
            .detail = "Download the official F16 ggml-large-v3-turbo.bin artifact from ggerganov/whisper.cpp at revision 98aa99a0a9db05ae2342309f5096248665f7cba3 (1,624,555,275 bytes), credential-free. This large Model Operation uses the network only after you choose Install; Capture audio is never uploaded.",
            .button = "Install",
        },
        .update => .{
            .title = "Update Whisper Large v3 Turbo?",
            .detail = "The replacement is downloaded and verified as staged data while the working Model Installation stays usable. An active Utterance may finish before atomic activation. Local remains selected with no OpenAI fallback.",
            .button = "Update",
        },
        .remove => .{
            .title = "Remove the Local Model?",
            .detail = "An active Utterance may finish before the helper unloads. Local remains selected with no OpenAI fallback. The Model Installation and staged data are removed.",
            .button = "Remove",
        },
        .repair => .{
            .title = "Repair the Local Model?",
            .detail = "Valid working Model Installation data is preserved while repair data is staged. An active Utterance may finish before atomic activation. Local remains selected with no OpenAI fallback. If network access is needed, it is used only for this Model Operation; Capture audio is never uploaded.",
            .button = "Repair",
        },
        .cancel_operation => .{
            .title = "Cancel the Model Operation?",
            .detail = "The current cancellable stage stops cooperatively. Resumable staged data is retained and the working Model Installation stays usable. An active local Utterance and the no-fallback privacy boundary are unchanged.",
            .button = "Cancel Operation",
        },
        .discard => .{
            .title = "Discard Partial Model Data?",
            .detail = "Only resumable staged data is discarded. The working Model Installation, active local Utterance, and local selection with no OpenAI fallback are unchanged.",
            .button = "Discard",
        },
        else => null,
    };
}

fn confirmModelAction(action: ModelAction) bool {
    const content = confirmationForModelAction(action) orelse return true;
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Unlike the top-level Set-API-Key item, Install/Remove fire from the Local Model
    // submenu, whose tracking run loop is still tearing down as we present. An accessory
    // app is never frontmost, so activateIgnoringOtherApps: alone lands too late and the
    // alert opens behind the frontmost app. Activate, then raise the alert's own window
    // above ordinary windows and order it front regardless of active state — hud.zig's
    // #20 recipe — so the confirmation always surfaces focused (#31).
    msgBool(appkit.app(), "activateIgnoringOtherApps:", true);

    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr(content.title));
    msg1v(alert, "setInformativeText:", nsstr(content.detail));
    _ = msg1(alert, "addButtonWithTitle:", nsstr(content.button));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Cancel"));

    const win = msg(alert, "window");
    msgLong(win, "setLevel:", NSStatusWindowLevel);
    _ = msg(win, "orderFrontRegardless");

    return msgLongR(alert, "runModal") == NSAlertFirstButtonReturn;
}

test "Install confirmation names the pinned large artifact and its privacy boundary" {
    const copy = confirmationForModelAction(.install).?;

    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(copy.detail), "ggerganov/whisper.cpp") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(copy.detail), "ggml-large-v3-turbo.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(copy.detail), "1,624,555,275 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(copy.detail), "credential-free") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(copy.detail), "Capture audio is never uploaded") != null);
}

test "state-changing Local Model confirmations explain their containment boundary" {
    const update = std.mem.span(confirmationForModelAction(.update).?.detail);
    try std.testing.expect(std.mem.indexOf(u8, update, "active Utterance") != null);
    try std.testing.expect(std.mem.indexOf(u8, update, "staged") != null);
    try std.testing.expect(std.mem.indexOf(u8, update, "working Model Installation") != null);

    const remove = std.mem.span(confirmationForModelAction(.remove).?.detail);
    try std.testing.expect(std.mem.indexOf(u8, remove, "no OpenAI fallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, remove, "staged data are removed") != null);

    const cancel = std.mem.span(confirmationForModelAction(.cancel_operation).?.detail);
    try std.testing.expect(std.mem.indexOf(u8, cancel, "working Model Installation") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel, "staged data") != null);

    const discard = std.mem.span(confirmationForModelAction(.discard).?.detail);
    try std.testing.expect(std.mem.indexOf(u8, discard, "staged data") != null);
    try std.testing.expect(std.mem.indexOf(u8, discard, "working Model Installation") != null);
}

test "backtrackLine2 sharpens to not-applying only on Local with Backtrack on" {
    const cloud = "unavailable on the Local backend";
    const sharpened = "Not applying";

    // The three non-sharpened cases all show the plain cloud/network line.
    inline for (.{
        config.Settings{ .transcription_backend = .openai, .backtrack = true },
        config.Settings{ .transcription_backend = .openai, .backtrack = false },
        config.Settings{ .transcription_backend = .local, .backtrack = false },
    }) |s| {
        var settings = s;
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(backtrackLine2(&settings)), cloud) != null);
    }

    // Only Local + on sharpens — the opted-in preference is kept, not erased.
    var on_local = config.Settings{ .transcription_backend = .local, .backtrack = true };
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(backtrackLine2(&on_local)), sharpened) != null);
}

// ---- vocabulary editing pure halves (spec §3/§4) --------------------------------------

test "vocabularyTitle reflects the count, plural, and backend-aware suffix" {
    var buf: [96]u8 = undefined;
    // Local: `(off)` / `(N terms)…`, no suffix.
    try std.testing.expectEqualStrings("Vocabulary (off)", vocabularyTitle(&buf, 0, .local));
    try std.testing.expectEqualStrings("Vocabulary (1 term)\xe2\x80\xa6", vocabularyTitle(&buf, 1, .local));
    try std.testing.expectEqualStrings("Vocabulary (3 terms)\xe2\x80\xa6", vocabularyTitle(&buf, 3, .local));
    // OpenAI: the ` — local only` suffix replaces the disclosure ellipsis (§4).
    try std.testing.expectEqualStrings("Vocabulary (off) \xe2\x80\x94 local only", vocabularyTitle(&buf, 0, .openai));
    try std.testing.expectEqualStrings("Vocabulary (3 terms) \xe2\x80\x94 local only", vocabularyTitle(&buf, 3, .openai));
}

test "parseVocabularyLines splits, trims, and drops blank lines" {
    const list = parseVocabularyLines(std.testing.allocator, "  type-wave \n\nwhisper.cpp\n   \nBjorn").?;
    defer {
        for (list) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(list);
    }
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("type-wave", list[0]);
    try std.testing.expectEqualStrings("whisper.cpp", list[1]);
    try std.testing.expectEqualStrings("Bjorn", list[2]);
}

test "parseVocabularyLines yields an empty list for blank/empty text" {
    const empty = parseVocabularyLines(std.testing.allocator, "").?;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const spaces = parseVocabularyLines(std.testing.allocator, "  \n\t\n").?;
    defer std.testing.allocator.free(spaces);
    try std.testing.expectEqual(@as(usize, 0), spaces.len);
}

test "prefillText joins one term per line; empty list yields an empty field" {
    const text = prefillText(std.testing.allocator, &.{ "type-wave", "whisper.cpp" }).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("type-wave\nwhisper.cpp", text);

    const empty = prefillText(std.testing.allocator, &.{}).?;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "prefill → parse round-trips a list byte-for-byte" {
    const original = [_][]const u8{ "type-wave", "whisper.cpp", "Bjorn" };
    const text = prefillText(std.testing.allocator, &original).?;
    defer std.testing.allocator.free(text);
    const back = parseVocabularyLines(std.testing.allocator, text).?;
    defer {
        for (back) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(back);
    }
    try std.testing.expectEqual(original.len, back.len);
    for (original, back) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "droppedItemsMessage pluralizes and names the structural caps" {
    var buf: [160]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, droppedItemsMessage(&buf, 1), "Dropped 1 term ") != null);
    const many = droppedItemsMessage(&buf, 5);
    try std.testing.expect(std.mem.indexOf(u8, many, "Dropped 5 terms ") != null);
    try std.testing.expect(std.mem.indexOf(u8, many, "128 terms max") != null);
}

test "vocabularyInfoText always guides, and adds a soft hint only when near/over budget" {
    var buf: [256]u8 = undefined;
    const short = vocabularyInfoText(&buf, &.{ "type-wave", "whisper.cpp" });
    try std.testing.expect(std.mem.indexOf(u8, short, "One term per line") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "tokens") == null); // no hint when well within budget

    // A list past the conservative Whisper budget trips the soft, non-blocking hint (§6).
    const term = blk: {
        var b: [50]u8 = undefined;
        @memset(&b, 'a');
        break :blk b;
    };
    var backing: [20][]const u8 = undefined;
    for (&backing) |*slot| slot.* = &term;
    const long = vocabularyInfoText(&buf, &backing);
    try std.testing.expect(std.mem.indexOf(u8, long, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, "tokens") != null);
}

test "RevealSet toggles one entry on and off, keyed by timestamp" {
    var set = RevealSet{};
    try std.testing.expect(!set.contains(100));
    set.toggle(100);
    try std.testing.expect(set.contains(100));
    set.toggle(100); // second ⌥-click re-masks
    try std.testing.expect(!set.contains(100));
    try std.testing.expectEqual(@as(usize, 0), set.len);
}

test "RevealSet reveals entries independently — one row's toggle never flips another" {
    var set = RevealSet{};
    set.toggle(10);
    set.toggle(20);
    set.toggle(30);
    try std.testing.expect(set.contains(10) and set.contains(20) and set.contains(30));
    set.toggle(20); // hide only the middle one
    try std.testing.expect(set.contains(10) and !set.contains(20) and set.contains(30));
    try std.testing.expectEqual(@as(usize, 2), set.len);
}

test "RevealSet never overflows its capacity-bounded backing" {
    var set = RevealSet{};
    var ts: i64 = 1;
    while (ts <= recent_insertions.capacity + 5) : (ts += 1) set.toggle(ts);
    try std.testing.expectEqual(@as(usize, recent_insertions.capacity), set.len); // capped, no overrun
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

/// The Vocabulary editor (spec §3): NSAlert + a multi-line NSTextView-in-NSScrollView
/// accessory pre-filled with the current (clamped) list, one term per line. Save parses →
/// trims → drops blanks → applies the §1 structural clamp → commits `session_shaped = false`
/// (no session cycle; Whisper reads the list fresh at the next Talk-Key press). Cancel is a
/// no-op. When the clamp dropped items, a follow-up alert names the count. The item edits on
/// both backends; on OpenAI it is inert (§4) — the menu title already says `— local only`.
fn onVocabulary(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    // Accessory app not frontmost → activate so the modal takes keystrokes (#31).
    msgBool(appkit.app(), "activateIgnoringOtherApps:", true);

    const current = m.store.current();

    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr("Edit Vocabulary"));
    var info_buf: [256]u8 = undefined;
    msg1v(alert, "setInformativeText:", nsstr(vocabularyInfoText(&info_buf, current.vocabulary).ptr));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Save"));
    _ = msg1(alert, "addButtonWithTitle:", nsstr("Cancel"));

    // Multi-line accessory: a bezeled, vertically-scrolling NSTextView. Disable the smart
    // substitutions that would silently mangle terms (curly quotes, dash swaps, replacement).
    const frame = NSRect{ .x = 0, .y = 0, .w = 320, .h = 160 };
    const scroll = allocInitFrame("NSScrollView", frame);
    msgBool(scroll, "setHasVerticalScroller:", true);
    msgLong(scroll, "setBorderType:", 2); // NSBezelBorder
    const text_view = allocInitFrame("NSTextView", frame);
    msgBool(text_view, "setRichText:", false);
    msgBool(text_view, "setSmartInsertDeleteEnabled:", false);
    msgBool(text_view, "setAutomaticQuoteSubstitutionEnabled:", false);
    msgBool(text_view, "setAutomaticDashSubstitutionEnabled:", false);
    msgBool(text_view, "setAutomaticTextReplacementEnabled:", false);
    msgBool(text_view, "setAutomaticSpellingCorrectionEnabled:", false);

    // Pre-fill with the loaded (already clamped) list — items the load clamp dropped are
    // visibly absent (surface-by-round-trip, spec §3). Empty list → empty field.
    if (prefillText(m.alloc, current.vocabulary)) |prefill| {
        defer m.alloc.free(prefill);
        msg1v(text_view, "setString:", nsstr(prefill.ptr));
    }
    msg1v(scroll, "setDocumentView:", text_view);
    msg1v(alert, "setAccessoryView:", scroll);
    msg1v(msg(alert, "window"), "setInitialFirstResponder:", text_view);

    if (msgLongR(alert, "runModal") != NSAlertFirstButtonReturn) return; // Cancel — no-op

    // Read → split/trim/drop-blank → structural clamp. Terms are duped into m.alloc so they
    // outlive this pool inside the leaked snapshot; dropped = entered − committed (§3).
    const entered = parseVocabularyLines(m.alloc, std.mem.span(utf8(msg(text_view, "string")))) orelse return;
    const committed = config.clampVocabulary(m.alloc, entered) orelse return;
    const dropped = entered.len - committed.len;

    var next = current.*;
    next.vocabulary = committed;
    const value = config.serializeVocabularyValue(m.alloc, committed) orelse return;
    defer m.alloc.free(value);
    m.commitSettings(next, "vocabulary", value, false); // read-at-use — never session_shaped (§4)
    m.syncVocabulary();
    feedback.log("  menu: Vocabulary → {d} terms{s}\n", .{ committed.len, if (dropped > 0) " (clamped)" else "" });

    if (dropped > 0) {
        var note_buf: [160]u8 = undefined;
        const note = msg(msg(cls("NSAlert"), "alloc"), "init");
        msg1v(note, "setMessageText:", nsstr("Some terms were dropped"));
        msg1v(note, "setInformativeText:", nsstr(droppedItemsMessage(&note_buf, dropped).ptr));
        _ = msg1(note, "addButtonWithTitle:", nsstr("OK"));
        _ = msgLongR(note, "runModal");
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
    m.syncBacktrack(); // pick up a hand-edited .backtrack and re-word line 2 for the backend
    m.syncVocabulary(); // pick up a hand-edited vocabulary list (count) + backend suffix
    m.last_snapshot = null; // force refresh after settings or external model-state changes
    m.refreshChrome();
    m.rebuildHistory(); // (re)populate Recent Insertions with fresh masked labels (spec §4.1)
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
    _ = class_addMethod(target_cls, sel_registerName("onHistoryEntry:"), @ptrCast(&onHistoryEntry), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onHistoryCopy:"), @ptrCast(&onHistoryCopy), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOverlay:"), @ptrCast(&onOverlay), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onBacktrack:"), @ptrCast(&onBacktrack), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onPause:"), @ptrCast(&onPause), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOpenConfig:"), @ptrCast(&onOpenConfig), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onSetApiKey:"), @ptrCast(&onSetApiKey), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onVocabulary:"), @ptrCast(&onVocabulary), v_at);
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
