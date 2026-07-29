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
const status_item = @import("status_item.zig");
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
/// `-[NSObject performSelector:withObject:afterDelay:]` — schedules `aSelector` on the current
/// run loop in the **default** mode. Used by Re-insert (spec §5.1.5) to defer the replay until
/// the Status Item menu's modal tracking loop ends: a `delay: 0` timer will not fire while the
/// run loop is in event-tracking mode, so it fires only once the menu has closed and the prior
/// app is key again.
inline fn performAfter(self: id, aSelector: SEL, arg: id, delay: f64) void {
    const f: *const fn (id, SEL, SEL, id, f64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(self, sel_registerName("performSelector:withObject:afterDelay:"), aSelector, arg, delay);
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

// =====================================================================================
// The daemon-facing seams.
// =====================================================================================

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
    /// The vocabulary changed (menu edit or hand-edit found on open) — ask the warm
    /// OpenAI session to re-bind `keywords` at its next idle tick: a session.update
    /// push, never a cycle (openai-biasing-spec §1). The local path is untouched
    /// (read-at-use, Lease-pinned at press).
    markSessionRebias: *const fn (ctx: *anyopaque) void,
    /// The Overlay toggle changed — lazy-build / enable / disable the HUD.
    setOverlay: *const fn (ctx: *anyopaque, on: bool) void,
    setPaused: *const fn (ctx: *anyopaque, paused: bool) void,
    /// Store the API key (Keychain). Returns whether the store succeeded.
    storeApiKey: *const fn (ctx: *anyopaque, key: []const u8) bool,
    modelAction: *const fn (ctx: *anyopaque, action: ModelAction) void,
    /// Clear the daemon's log (#252) — the disposal path for the transcript history #250's
    /// redaction leaves behind on disk. Returns whether it was cleared, so a failure can be
    /// shown rather than swallowed: the user just asked for their dictation history to be
    /// gone, and a silent failure would tell them it is when it isn't.
    clearLog: *const fn (ctx: *anyopaque) bool,
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
    /// Re-insert one Recent Insertions entry at the current frontmost cursor (spec §5.1): resolve
    /// the record with capture `stamp` against the authoritative ring and replay its **verbatim**
    /// `inserted` bytes (trailing space and all, never re-running Backtrack) as a Coordinator-less
    /// bypass job on the insert worker — no Utterance identity, so it never writes the ring on
    /// success or failure. The menu defers this call until the Status Item menu has closed, so the
    /// replay lands at whatever Focused Target is frontmost then (unconditional, no target guard).
    /// An evicted stamp is a no-op. Keyed by the same stable `stamp` as `historyText` / `copy`.
    reinsert: *const fn (ctx: *anyopaque, stamp: i64) void,
    /// Menu Quit — begin the clean shutdown (ends in appkit.stop()).
    quit: *const fn (ctx: *anyopaque) void,
};

// =====================================================================================
// The settings write path's half of the radio groups. The table itself — and every
// checkmark decision over it — moved to status_item.zig (ADR-0011), because which option
// reads as selected is presentation. What stays here is the write: turning a clicked
// (group, option) into a field on a `Settings` under construction.
// =====================================================================================

const groups = status_item.groups;

/// Set group `gi`'s option `oi` on a Settings under construction. The typed option tables
/// live beside the group table in status_item.zig, so this and `settingsView`'s read-back
/// can never drift apart.
fn applyOption(s: *config.Settings, gi: usize, oi: usize) void {
    switch (gi) {
        0 => s.transcription_backend = status_item.backends[oi],
        1 => s.talk_key = status_item.talk_keys[oi],
        2 => s.model = status_item.models[oi],
        3 => s.language = status_item.languages[oi],
        4 => s.delay = status_item.delays[oi],
        5 => s.noise_reduction = status_item.noises[oi],
        6 => s.insertion = status_item.insertions[oi],
        else => unreachable,
    }
}

// =====================================================================================
// Vocabulary editing (spec §3/§4) — the pure halves, kept off AppKit so they unit-test
// without a display. `onVocabulary` below is the thin ObjC glue that drives them.
// =====================================================================================

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

// =====================================================================================
// AppKitChrome — the production adapter at the **Status Item Chrome** seam (ADR-0011). It
// owns every menu-item handle and every ObjC call, and decides nothing: `apply` is a
// straight run of setTitle: / setHidden: / setEnabled: / setState: over the Presentation's
// rows. The one impure reading it still makes is the clock, for the Recent Insertions
// relative times — a clock in a value-compared Presentation would defeat the early-out.
// =====================================================================================

fn setTitle(item: id, row: *const status_item.Row) void {
    msg1v(item, "setTitle:", nsstr(row.title()));
}
fn setTitleHidden(item: id, row: *const status_item.Row) void {
    setTitle(item, row);
    msgBool(item, "setHidden:", row.hidden);
}
fn setChecked(item: id, on: bool) void {
    msgLong(item, "setState:", if (on) NSControlStateOn else NSControlStateOff);
}

const AppKitChrome = struct {
    /// Only for the on-demand Recent Insertions text fetch — a revealed row's `inserted`
    /// bytes come from the authoritative ring, never from a projected value.
    host: Host = undefined,

    button: id = null, // the status-item button (carries the icon)
    status_line: id = null, // the disabled first item
    primary_item: id = null,
    privacy_item: id = null,
    /// The Secure Event Input disclosure row (#245): shown only while the condition holds,
    /// because it is the one state that stops `⌃⌘⌫` reaching the daemon at all.
    secure_input_item: id = null,
    network_item: id = null,
    set_api_key_item: id = null,
    pause_item: id = null, // title flips Pause/Resume
    overlay_item: id = null, // checkbox mirror of settings.overlay
    vocabulary_item: id = null, // title reflects the live term count + backend (spec §3/§4)
    backtrack_item: id = null, // checkbox mirror of settings.backtrack
    backtrack_cloud_item: id = null, // disclosure line 1 (static; on and off)
    backtrack_backend_item: id = null, // disclosure line 2 (swaps on Local + on)
    submenu: [status_item.group_count]id = @splat(null),
    group_parent: [status_item.group_count]id = @splat(null),
    local_model_parent: id = null,
    local_model_status: id = null,
    local_model_source: id = null,
    local_model_artifact: id = null,
    local_model_runtime: id = null,
    local_model_installer: id = null,
    local_operation_status: id = null,
    local_failure_status: id = null,
    model_actions: [status_item.model_action_count]id = @splat(null),

    // ---- Recent Insertions (spec §4): fixed items, retitled/toggled per apply ----
    history_parent: id = null, // the top-level "Recent Insertions ▸" item
    history_submenu: id = null, // its submenu; holds the fixed entry rows
    history_entries: [recent_insertions.capacity]id = @splat(null), // one label row each
    history_alt_entries: [recent_insertions.capacity]id = @splat(null), // the ⌥-alternate twin per row (fires reveal)
    history_reveal_items: [recent_insertions.capacity]id = @splat(null), // the in-submenu "Reveal text" item per row
    history_copy_items: [recent_insertions.capacity]id = @splat(null), // the in-submenu "Copy" item per row
    history_reinsert_items: [recent_insertions.capacity]id = @splat(null), // the in-submenu "Re-insert here" item per row

    pub fn apply(self: *AppKitChrome, p: *const status_item.Presentation) void {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // ---- the menu-bar icon ----
        var img = sfSymbol("waveform.badge.mic");
        if (img != null) {
            const cfg = symbolConfig(17.0, 0.0, 2); // 17 pt, regular weight, medium scale
            img = msg1(img, "imageWithSymbolConfiguration:", cfg);
            msgBool(img, "setTemplate:", true); // adopt the menu bar's monochrome light/dark
            msg1v(self.button, "setImage:", img);
            msg1v(self.button, "setTitle:", nsstr(""));
        } else {
            // No SF Symbols on this macOS — a text glyph keeps the item clickable.
            msg1v(self.button, "setTitle:", nsstr(p.icon_fallback.title()));
        }
        // How dim is the Chrome's business; whether, is the Presentation's.
        msgDouble(self.button, "setAlphaValue:", if (p.dimmed) 0.35 else 1.0);

        // ---- title-only rows (each built disabled or always-enabled; the flag stays put) ----
        setTitle(self.status_line, &p.status_line);
        setTitle(self.pause_item, &p.pause);
        setTitle(self.vocabulary_item, &p.vocabulary);
        setTitle(self.backtrack_backend_item, &p.backtrack_backend);
        setTitle(self.local_model_status, &p.installation);
        setTitle(self.local_operation_status, &p.operation);

        // ---- checkmarks ----
        setChecked(self.overlay_item, p.overlay.checked);
        setChecked(self.backtrack_item, p.backtrack.checked);
        for (0..status_item.group_count) |gi| {
            const sub = self.submenu[gi];
            const n = msgLongR(sub, "numberOfItems");
            var i: c_long = 0;
            while (i < n) : (i += 1) {
                const oi: usize = @intCast(i);
                setChecked(
                    msgIdxId(sub, "itemAtIndex:", i),
                    oi < status_item.max_group_opts and p.group_checked[gi][oi],
                );
            }
            msgBool(self.group_parent[gi], "setHidden:", p.group_hidden[gi]);
        }

        // ---- visibility-only rows ----
        msgBool(self.set_api_key_item, "setHidden:", p.set_api_key.hidden);
        msgBool(self.privacy_item, "setHidden:", p.privacy.hidden);
        msgBool(self.network_item, "setHidden:", p.network.hidden);

        // ---- title + visibility rows ----
        setTitleHidden(self.primary_item, &p.primary);
        msgBool(self.primary_item, "setEnabled:", p.primary.enabled);
        setTitleHidden(self.secure_input_item, &p.secure_input);
        setTitleHidden(self.local_failure_status, &p.failure);
        setTitleHidden(self.local_model_source, &p.identity_source);
        setTitleHidden(self.local_model_artifact, &p.identity_artifact);
        setTitleHidden(self.local_model_runtime, &p.identity_runtime);
        setTitleHidden(self.local_model_installer, &p.identity_installer);

        // ---- the Local Model action rows ----
        for (self.model_actions, 0..) |item, i|
            msgBool(item, "setHidden:", p.model_action_hidden[i]);

        self.applyHistory(&p.history);
    }

    /// The Recent Insertions rows (spec §4.1). The Presentation says which rows show and
    /// which are revealed; the label itself is formatted here, because a revealed row's text
    /// is fetched on demand from the authoritative ring — transcript bytes never ride a
    /// projected value.
    fn applyHistory(self: *AppKitChrome, h: *const status_item.History) void {
        if (self.history_parent == null) return;
        setTitle(self.history_parent, &h.parent);
        msgBool(self.history_parent, "setEnabled:", h.parent.enabled);
        // Drop the disclosure arrow while the ring is empty — there is nothing to open.
        msg1v(self.history_parent, "setSubmenu:", if (h.empty) null else self.history_submenu);

        const now = feedback.nowMs();
        var label_buf: [1024]u8 = undefined; // a revealed snippet + a long app name + metadata
        for (self.history_entries, 0..) |row, i| {
            const hidden = h.rows[i].hidden;
            msgBool(row, "setHidden:", hidden);
            msgBool(self.history_alt_entries[i], "setHidden:", hidden);
            if (hidden) continue;

            const entry = h.rows[i].entry;
            const revealed = h.rows[i].revealed;
            // A withheld record (#286) has no bytes behind it: the three text actions are shown
            // disabled rather than hidden, so the row reads as deliberate rather than broken —
            // the reveal item carries the reason. `setAutoenablesItems:` is off for these
            // submenus, so an explicit `setEnabled:` is what decides.
            const text_available = h.rows[i].text_available;
            msgBool(self.history_copy_items[i], "setEnabled:", text_available);
            msgBool(self.history_reinsert_items[i], "setEnabled:", text_available);
            msgBool(self.history_reveal_items[i], "setEnabled:", text_available);
            msgBool(self.history_alt_entries[i], "setEnabled:", text_available);
            const label = if (revealed) label: {
                // On-demand text fetch (spec §4.1 / §5): the `inserted` bytes are read from the
                // authoritative ring under its leaf lock — never from a projected value — keyed
                // by the entry's stable timestamp so text can't misalign with its row.
                var text_buf: [recent_insertions.max_bytes]u8 = undefined;
                const n = self.host.historyText(self.host.ctx, entry.timestamp, &text_buf);
                break :label status_item.historyRevealedLabel(&label_buf, entry, text_buf[0..n], now);
            } else status_item.historyLabel(&label_buf, entry, now);

            msg1v(row, "setTitle:", nsstr(label.ptr));
            // Keep the ⌥-alternate's title in lockstep so the row doesn't jump on ⌥-hold.
            msg1v(self.history_alt_entries[i], "setTitle:", nsstr(label.ptr));
            // The in-submenu affordance mirrors the toggle state — or names why there is none.
            msg1v(self.history_reveal_items[i], "setTitle:", nsstr(status_item.revealItemTitle(revealed, text_available).ptr));
        }
    }
};

pub const Menu = struct {
    io: std.Io = undefined,
    alloc: std.mem.Allocator = undefined,
    store: *config.Store = undefined,
    host: Host = undefined,

    /// False until `init` succeeds; false forever on a headless start. The daemon then
    /// runs without a status item (and blocks on plain CFRunLoopRun, not [NSApp run]).
    active: bool = false,
    target: id = null, // the runtime-minted TWMenuTarget instance

    /// The two halves of the Status Item Chrome seam: the AppKit adapter, and the pump that
    /// composes one Presentation per refresh and applies it across the seam.
    chrome: AppKitChrome = .{},
    pump: status_item.StatusItem(AppKitChrome) = undefined,

    /// Which entries the user has toggled to show inline (spec §4). Menu-session state: the
    /// adapter owns it and hands it to `present` as an input (ADR-0011).
    reveal: status_item.RevealSet = .{},
    /// The entry stamp a "Re-insert here" click stashed, awaiting the deferred fire once the menu
    /// closes (spec §5.1.5). At most one is pending — the menu closes on the click, so a second
    /// re-insert can only start after this one has fired and cleared it.
    pending_reinsert: ?i64 = null,

    /// The last Snapshot pulled from the daemon. A settings write re-applies from this rather
    /// than paying for `Host.status`'s model_store I/O again: a menu write cannot move a
    /// daemon-side axis, and the ~2 s pump tick picks up anything that follows from it.
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
        self.chrome = .{ .host = host };
        self.pump = .init(&self.chrome);
        g_menu = self;

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        self.target = makeTarget();

        const bar = msg(cls("NSStatusBar"), "systemStatusBar");
        const item = statusItemVariable(bar);
        // statusItemWithLength: returns an autoreleased item the status bar holds; keep
        // our own ref for the process lifetime.
        _ = msg(item, "retain");
        self.chrome.button = msg(item, "button");

        // Every row is built with a placeholder title and default visibility: the first
        // `apply` fills all of them, so no build step decides any wording or state.
        const menu = newMenu();
        self.chrome.status_line = self.addDisabled(menu, "type-wave");
        addSeparator(menu);
        self.addRadioGroup(menu, 0);
        // Backtrack sits directly beneath the Backend radio group it depends on, with two
        // always-visible disclosure lines (docs/backtrack-spec.md §Settings & UX). Unlike
        // the openai_only groups it is never hidden — hiding would erase an opted-in
        // preference — so on the Local backend it stays checked/enabled and line 2 sharpens.
        self.chrome.backtrack_item = self.addAction(menu, "Backtrack (rewrite self-corrections)", "onBacktrack:");
        self.chrome.backtrack_cloud_item = self.addDisabled(menu, "Uses OpenAI cloud \xe2\x80\x94 transcript text leaves your Mac");
        self.chrome.backtrack_backend_item = self.addDisabled(menu, "");
        self.chrome.primary_item = self.addAction(menu, "", "onPrimary:");
        self.chrome.privacy_item = self.addDisabled(menu, "Audio stays on this Mac");
        self.chrome.network_item = self.addDisabled(menu, "Network used only for this model operation");
        self.chrome.secure_input_item = self.addDisabled(menu, "");
        addSeparator(menu);
        for (1..status_item.group_count) |gi| self.addRadioGroup(menu, gi);
        self.addLocalModel(menu);
        self.chrome.overlay_item = self.addAction(menu, "Overlay HUD", "onOverlay:");
        addSeparator(menu);
        self.chrome.set_api_key_item = self.addAction(menu, "Set OpenAI API Key\xe2\x80\xa6", "onSetApiKey:");
        self.chrome.pause_item = self.addAction(menu, "Pause dictation", "onPause:");
        self.chrome.vocabulary_item = self.addAction(menu, "Vocabulary (off)", "onVocabulary:");
        _ = self.addAction(menu, "Open config file", "onOpenConfig:");
        addSeparator(menu);
        self.addRecentInsertions(menu);
        addSeparator(menu);
        _ = self.addAction(menu, "Quit type-wave", "onQuit:");

        // menuWillOpen: → the refresh-on-open re-read/diff/swap (#32's no-watcher answer).
        msg1v(menu, "setDelegate:", self.target);
        msg1v(item, "setMenu:", menu);

        self.active = true;
        self.refresh(); // the first apply paints every row

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

    // ---- the refresh path (pull → compose → apply across the seam) -------------------

    /// Pull a fresh Snapshot from the daemon and re-apply.
    fn refresh(self: *Menu) void {
        if (!self.active) return;
        self.last_snapshot = self.host.status(self.host.ctx);
        self.applyNow();
    }

    /// Re-apply after a settings write, reusing the cached Snapshot — see `last_snapshot`.
    fn refreshSettings(self: *Menu) void {
        if (!self.active) return;
        self.applyNow();
    }

    fn applyNow(self: *Menu) void {
        const snapshot = self.last_snapshot orelse blk: {
            const fresh = self.host.status(self.host.ctx);
            self.last_snapshot = fresh;
            break :blk fresh;
        };
        _ = self.pump.refresh(snapshot, status_item.settingsView(self.store.current()), self.reveal);
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

    fn addRadioGroup(self: *Menu, menu: id, gi: usize) void {
        const g = &groups[gi];
        const sub = newMenu();
        for (g.opts, 0..) |opt, oi| {
            const it = makeItem(opt.label, sel_registerName("onRadio:"));
            msg1v(it, "setTarget:", self.target);
            msgLong(it, "setTag:", @intCast(gi * 100 + oi));
            msg1v(sub, "addItem:", it);
        }
        const parent = makeItem(g.title, null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.chrome.submenu[gi] = sub;
        self.chrome.group_parent[gi] = parent;
    }

    fn addLocalModel(self: *Menu, menu: id) void {
        const sub = newMenu();
        self.chrome.local_model_status = self.addDisabled(sub, "Whisper Large v3 Turbo — not installed");
        self.chrome.local_model_source = self.addDisabled(sub, "");
        self.chrome.local_model_artifact = self.addDisabled(sub, "");
        self.chrome.local_model_runtime = self.addDisabled(sub, "");
        self.chrome.local_model_installer = self.addDisabled(sub, "");
        self.chrome.local_operation_status = self.addDisabled(sub, "Model Operation — idle");
        self.chrome.local_failure_status = self.addDisabled(sub, "");
        addSeparator(sub);
        for (model_action_definitions) |definition| {
            const item = self.addAction(sub, definition.title, "onModelAction:");
            msgLong(item, "setTag:", @intFromEnum(definition.action));
            self.chrome.model_actions[@intFromEnum(definition.action)] = item;
        }
        // Clear log (#252) sits beside Open diagnostics — the two log affordances together,
        // one to read it and one to dispose of it. Static like "Open config file" and "Quit":
        // its title never changes and it is never hidden, so there is nothing for the
        // Presentation to decide about it.
        _ = self.addAction(sub, "Clear log\xe2\x80\xa6", "onClearLog:");
        const parent = makeItem("Local Model", null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.chrome.local_model_parent = parent;
    }

    /// The **Recent Insertions ▸** submenu (spec §4). Built once with a fixed pool of
    /// `capacity` entry rows — each row is itself a submenu carrying **Copy**, **Re-insert
    /// here** and the reveal toggle. Rows are retitled and shown/hidden per apply, mirroring
    /// the codebase's "build once, toggle" idiom (no per-open allocation, no leak). Autoenable
    /// is turned off so an enabled row can carry a submenu of disabled items and still open.
    fn addRecentInsertions(self: *Menu, menu: id) void {
        const sub = newMenu();
        msgBool(sub, "setAutoenablesItems:", false);
        for (0..recent_insertions.capacity) |i| {
            const row = makeItem("", null);
            const row_sub = newMenu();
            msgBool(row_sub, "setAutoenablesItems:", false);
            // Copy (spec §5.2): fires the shared `onHistoryCopy:` selector, tagged with this
            // row's fixed newest-first index — resolved against the displayed Presentation to
            // the entry's stamp, then copied on the insert worker.
            const copy_it = makeItem("Copy", sel_registerName("onHistoryCopy:"));
            msg1v(copy_it, "setTarget:", self.target);
            msgLong(copy_it, "setTag:", @intCast(i));
            msg1v(row_sub, "addItem:", copy_it);
            self.chrome.history_copy_items[i] = copy_it;
            // Re-insert here (spec §5.1): fires the shared `onHistoryReinsert:` selector, tagged
            // with this row's fixed newest-first index. The handler defers the actual replay until
            // the menu closes (so it lands at the then-frontmost Focused Target, §5.1.5); the
            // daemon then submits the verbatim `inserted` bytes as a Coordinator-less bypass job.
            const reinsert_it = makeItem("Re-insert here", sel_registerName("onHistoryReinsert:"));
            msg1v(reinsert_it, "setTarget:", self.target);
            msgLong(reinsert_it, "setTag:", @intCast(i));
            msg1v(row_sub, "addItem:", reinsert_it);
            self.chrome.history_reinsert_items[i] = reinsert_it;
            // "Reveal text" — the discoverable equivalent of the ⌥-click reveal (spec §4). Its
            // title flips to "Hide text" while revealed; both fire the shared `onHistoryEntry:`
            // toggle, tagged with this row's fixed newest-first index.
            const reveal_it = makeItem("Reveal text", sel_registerName("onHistoryEntry:"));
            msg1v(reveal_it, "setTarget:", self.target);
            msgLong(reveal_it, "setTag:", @intCast(i));
            msg1v(row_sub, "addItem:", reveal_it);
            self.chrome.history_reveal_items[i] = reveal_it;

            msg1v(row, "setSubmenu:", row_sub);
            msgBool(row, "setHidden:", true);
            msg1v(sub, "addItem:", row);
            self.chrome.history_entries[i] = row;

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
            self.chrome.history_alt_entries[i] = alt;
        }
        const parent = makeItem("Recent Insertions", null);
        msg1v(parent, "setSubmenu:", sub);
        msg1v(menu, "addItem:", parent);
        self.chrome.history_parent = parent;
        self.chrome.history_submenu = sub;
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
    // One apply re-checkmarks the group and re-words everything that tracks the backend —
    // the Backtrack disclosure line and the Vocabulary item's `— local only` suffix (§4).
    m.refreshSettings();
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
    m.host.setOverlay(m.host.ctx, next.overlay);
    m.refreshSettings();
    feedback.log("  menu: Overlay HUD → {s}\n", .{if (next.overlay) "on" else "off"});
}

fn onBacktrack(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    var next = m.store.current().*;
    next.backtrack = !next.backtrack;
    // Read-at-use / pinned at Talk Key press — no Host callback, no session cycle.
    m.commitSettings(next, "backtrack", if (next.backtrack) "true" else "false", false);
    m.refreshSettings(); // toggle checkmark + line-2 wording (sharpens on Local + on)
    feedback.log("  menu: Backtrack → {s}\n", .{if (next.backtrack) "on" else "off"});
}

/// Pause/resume, flipping the state the **displayed** Presentation reported (ADR-0011) rather
/// than re-reading it — the row the user clicked said which way it would go, and re-reading
/// would pay for the status read's model_store I/O to answer one bool.
fn onPause(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const paused = (m.pump.displayed() orelse return).paused;
    m.host.setPaused(m.host.ctx, !paused);
    feedback.log("  menu: dictation {s}\n", .{if (!paused) "paused" else "resumed"});
    m.refresh();
}

/// The primary row's click, routed off the action the **displayed** Presentation carries
/// (ADR-0011): what fires is what the label offered, not what a fresh derivation would now
/// decide — which is what closes the gap where the state moved between render and click.
fn onPrimary(sender_self: id, command: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const action = (m.pump.displayed() orelse return).primary_action;
    switch (action) {
        .none, .operation_progress => {},
        .set_openai_api_key => onSetApiKey(sender_self, command, sender),
        .install_local_model => if (confirmModelAction(.install)) m.host.modelAction(m.host.ctx, .install),
        .update_local_model => if (confirmModelAction(.update)) m.host.modelAction(m.host.ctx, .update),
        .resume_model_operation => m.host.modelAction(m.host.ctx, .resume_operation),
        .retry_model_operation => m.host.modelAction(m.host.ctx, .retry_operation),
        .repair_local_model => if (confirmModelAction(.repair)) m.host.modelAction(m.host.ctx, .repair),
        .retry_local_runtime => m.host.modelAction(m.host.ctx, .retry_runtime),
    }
    m.pump.invalidate();
    m.refresh();
}

fn onModelAction(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const raw = msgLongR(sender, "tag");
    const action = std.enums.fromInt(ModelAction, raw) orelse return;
    if (!confirmModelAction(action)) return;
    m.host.modelAction(m.host.ctx, action);
    m.pump.invalidate();
    m.refresh();
}

/// Resolve a history row's `tag` (its fixed newest-first index) to the entry's stable capture
/// stamp, off the **displayed** Presentation (ADR-0011) — the row the user clicked is the row
/// they saw, so the index can never point at an entry that has since shifted.
fn historyStampForSender(m: *Menu, sender: id) ?i64 {
    const raw = msgLongR(sender, "tag");
    if (raw < 0) return null;
    const i: usize = @intCast(raw);
    const p = m.pump.displayed() orelse return null;
    if (i >= p.history.count) return null;
    return p.history.rows[i].entry.timestamp;
}

/// Reveal toggle for one Recent Insertions entry (spec §4): the shared selector behind both
/// the ⌥-click alternate row and the in-submenu "Reveal text" item. It flips that entry's
/// reveal flag and re-applies, so the row shows (or re-masks) its text — no transcript byte is
/// touched here; the Chrome fetches it on demand only for a revealed row.
fn onHistoryEntry(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const stamp = historyStampForSender(m, sender) orelse return;
    m.reveal.toggle(stamp);
    // The reveal set is an input to `present`, so the Presentation genuinely changed and the
    // pump's early-out will let this through — no invalidate needed.
    m.refreshSettings();
}

/// Copy one Recent Insertions entry to the clipboard (spec §5.2): the per-entry Copy item's
/// selector. It hands the resolved stamp to `host.copy`; the daemon fetches + trims the text and
/// does the pasteboard write on the insert worker. No transcript byte is touched here — the menu
/// only dispatches.
fn onHistoryCopy(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    const stamp = historyStampForSender(m, sender) orelse return;
    m.host.copy(m.host.ctx, stamp);
}

/// Re-insert one Recent Insertions entry at the current frontmost cursor (spec §5.1): the
/// per-entry "Re-insert here" item's selector. It **stashes** the resolved stamp and defers the
/// actual replay to `onReinsertFire:` — the Status Item menu's modal tracking holds key focus
/// until it closes, so firing now would land the insert in the menu, not the user's target. No
/// transcript byte is touched here; the daemon fetches the verbatim bytes on the deferred fire.
fn onHistoryReinsert(_: id, _: SEL, sender: id) callconv(.c) void {
    const m = g_menu orelse return;
    m.pending_reinsert = historyStampForSender(m, sender) orelse return;
    // Defer until the menu's modal loop unwinds: an afterDelay:0 timer fires in the default
    // run-loop mode, i.e. only once NSMenu tracking has ended and the prior app is key again
    // (spec §5.1.5). The replay then lands at whatever Focused Target is frontmost — unconditional.
    performAfter(m.target, sel_registerName("onReinsertFire:"), null, 0.0);
}

/// Fires one run-loop turn after a "Re-insert here" click, by which point the Status Item menu
/// has closed and the prior app is key again (spec §5.1.5). Hands the stashed entry's stamp to
/// `host.reinsert`, which replays the verbatim `inserted` bytes on the insert worker as a
/// Coordinator-less bypass job — landing at the now-frontmost Focused Target, unconditional, and
/// never recorded into the ring (§5.1.4). A null stash (already fired, or the menu was dismissed
/// without a click) is a no-op.
fn onReinsertFire(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    const stamp = m.pending_reinsert orelse return;
    m.pending_reinsert = null;
    m.host.reinsert(m.host.ctx, stamp);
}

/// Clear log… (#252): confirm, clear, and say so if it did not work. Never reachable from
/// anywhere but this click — no timer, no startup path, no size threshold calls `host.clearLog`.
fn onClearLog(_: id, _: SEL, _: id) callconv(.c) void {
    const m = g_menu orelse return;
    if (!confirm(clear_log_confirmation)) return;
    if (m.host.clearLog(m.host.ctx)) return; // the cleared log's own first line records it
    // A failure has to reach the user directly, not only the log: the log is what failed, and
    // a clear that did nothing looks exactly like one that worked. The daemon writes the
    // reason to the log for a bug report; this is the half the user sees.
    acknowledge(clear_log_failure);
}

const Confirmation = struct {
    title: [*:0]const u8,
    detail: [*:0]const u8,
    button: [*:0]const u8,
};

/// The Clear log… confirmation (#252). It names what disappears — the whole diagnostic
/// history, transcripts included — and what does not, so nobody clears it expecting the
/// Recent Insertions ring or their settings to go with it.
const clear_log_confirmation = Confirmation{
    .title = "Clear the type-wave log?",
    .detail = "Every line currently in ~/Library/Logs/type-wave.log is deleted, including any transcript text an earlier version recorded verbatim. The diagnostic history a bug report would attach goes with it, and it cannot be recovered. type-wave keeps logging to the same file afterwards; your settings and Recent Insertions are unaffected.",
    .button = "Clear log",
};

const clear_log_failure = Confirmation{
    .title = "The log was not cleared.",
    .detail = "type-wave could not empty ~/Library/Logs/type-wave.log, so its contents are unchanged. This is expected when the daemon is running in the foreground, where its diagnostics go to the terminal rather than to a file.",
    .button = "OK",
};

fn confirmationForModelAction(action: ModelAction) ?Confirmation {
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
    return confirm(content);
}

/// Raise a two-button confirmation and report whether the affirmative one was chosen.
///
/// Unlike the top-level Set-API-Key item, everything routed through here fires from the
/// Local Model submenu, whose tracking run loop is still tearing down as we present. An
/// accessory app is never frontmost, so activateIgnoringOtherApps: alone lands too late and
/// the alert opens behind the frontmost app. Activate, then raise the alert's own window
/// above ordinary windows and order it front regardless of active state — hud.zig's #20
/// recipe — so the confirmation always surfaces focused (#31).
fn confirm(content: Confirmation) bool {
    return runAlert(content, "Cancel") == NSAlertFirstButtonReturn;
}

/// The one-button variant: something already happened (or failed to), and the user only has
/// to acknowledge it. Same surfacing recipe as `confirm`.
fn acknowledge(content: Confirmation) void {
    _ = runAlert(content, null);
}

fn runAlert(content: Confirmation, second_button: ?[*:0]const u8) c_long {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    msgBool(appkit.app(), "activateIgnoringOtherApps:", true);

    const alert = msg(msg(cls("NSAlert"), "alloc"), "init");
    msg1v(alert, "setMessageText:", nsstr(content.title));
    msg1v(alert, "setInformativeText:", nsstr(content.detail));
    _ = msg1(alert, "addButtonWithTitle:", nsstr(content.button));
    if (second_button) |title| _ = msg1(alert, "addButtonWithTitle:", nsstr(title));

    const win = msg(alert, "window");
    msgLong(win, "setLevel:", NSStatusWindowLevel);
    _ = msg(win, "orderFrontRegardless");

    return msgLongR(alert, "runModal");
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

test "the Clear log confirmation says what disappears and what survives" {
    const detail = std.mem.span(clear_log_confirmation.detail);
    // What goes: the file by name, the whole history, and the transcripts #250's redaction
    // stopped writing but could not retract.
    try std.testing.expect(std.mem.indexOf(u8, detail, "~/Library/Logs/type-wave.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "transcript") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "cannot be recovered") != null);
    // What the user is giving up by clearing: the diagnostics a bug report attaches.
    try std.testing.expect(std.mem.indexOf(u8, detail, "bug report") != null);
    // And what does *not* go, so nobody reads this as a wider erase than it is.
    try std.testing.expect(std.mem.indexOf(u8, detail, "keeps logging") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "Recent Insertions are unaffected") != null);

    // A confirmation, not a notice: the affirmative button names the act.
    try std.testing.expectEqualStrings("Clear log", std.mem.span(clear_log_confirmation.button));
}

test "a failed clear says the log is unchanged rather than implying it went" {
    const detail = std.mem.span(clear_log_failure.detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, "unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "foreground") != null);
}

// ---- vocabulary editing pure halves (spec §3/§4) --------------------------------------
// The Vocabulary *item title* moved to status_item.zig with the rest of the wording
// (ADR-0011); what stays here is the dialog, which is interaction rather than reflection.

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

test "the Status Item Chrome contract holds for the production adapter" {
    // Unlike the Helper and Session Transport seams, whose contracts nothing invokes, this one
    // is asserted by StatusItem(Chrome) itself — including for AppKitChrome, which no test can
    // otherwise reach. A renamed or dropped `apply` fails the build here rather than at runtime.
    status_item.assertChrome(AppKitChrome);
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
/// (no session cycle; Whisper reads the list fresh at the next Talk-Key press, and a warm
/// OpenAI session re-binds `keywords` via an idle push — openai-biasing-spec §1). Cancel is
/// a no-op. When the clamp dropped items, a follow-up alert names the count.
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
    const rebias = config.diffSettings(current, &next).rebias; // before the swap replaces `current`'s peer
    m.commitSettings(next, "vocabulary", value, false); // read-at-use — never session_shaped (§4)
    // A real change re-binds the warm OpenAI session's keywords at the next idle tick
    // (openai-biasing-spec §1) — a push, not a cycle; Save-without-change stays a no-op.
    if (rebias) m.host.markSessionRebias(m.host.ctx);
    m.refreshSettings();
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
        if (d.rebias) m.host.markSessionRebias(m.host.ctx);
        if (d.overlay) m.host.setOverlay(m.host.ctx, fresh.overlay);
    }
    // Apply unconditionally: the Recent Insertions relative times are the one thing the
    // Presentation deliberately does not carry, so an unchanged value would still render stale
    // ("2m ago" on a row that is now an hour old). Everything else — checkmarks, hand-edited
    // settings, external model-state changes — rides the pump's own comparison.
    m.pump.invalidate();
    m.refresh();
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
    _ = class_addMethod(target_cls, sel_registerName("onHistoryReinsert:"), @ptrCast(&onHistoryReinsert), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onReinsertFire:"), @ptrCast(&onReinsertFire), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOverlay:"), @ptrCast(&onOverlay), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onBacktrack:"), @ptrCast(&onBacktrack), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onPause:"), @ptrCast(&onPause), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onOpenConfig:"), @ptrCast(&onOpenConfig), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onClearLog:"), @ptrCast(&onClearLog), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onSetApiKey:"), @ptrCast(&onSetApiKey), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onVocabulary:"), @ptrCast(&onVocabulary), v_at);
    _ = class_addMethod(target_cls, sel_registerName("onQuit:"), @ptrCast(&onQuit), v_at);
    _ = class_addMethod(target_cls, sel_registerName("menuWillOpen:"), @ptrCast(&onMenuWillOpen), v_at);
    _ = class_addMethod(target_cls, sel_registerName("twStop:"), @ptrCast(&onStop), v_at);
    objc_registerClassPair(target_cls);
    return msg(msg(target_cls, "alloc"), "init");
}

/// CFRunLoopTimer callout — the chrome pump tick (main thread). The cadence lives here in the
/// adapter, as the HUD's does: the timer calls in, the pump composes, the Chrome draws.
fn chromeTick(_: CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *Menu = @ptrCast(@alignCast(info.?));
    self.refresh();
}
