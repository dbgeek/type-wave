//! Pure presentation policy for the compact Status Item hierarchy.
//!
//! AppKit rendering lives in menu.zig. This module turns independent daemon state axes
//! into the one headline, one primary action, and privacy cues the user sees.

const std = @import("std");
const backend = @import("transcription_backend.zig");
const installation_identity = @import("installation_identity.zig");
const readiness = @import("readiness.zig");
const coord = @import("coordinator.zig");
const recent_insertions = @import("recent_insertions.zig");

pub const Installation = enum {
    absent,
    ready,
    update_available,
    corrupt,
};

pub const Operation = enum {
    idle,
    installing,
    updating,
    paused,
    verifying,
    smoke_testing,
    waiting_for_inference,
    activating,
    removing,
    discarding,
    failed,
    cancelled,

    pub fn isActive(self: Operation) bool {
        return switch (self) {
            .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing, .discarding => true,
            .idle, .paused, .failed, .cancelled => false,
        };
    }

    pub fn isCancellable(self: Operation) bool {
        return switch (self) {
            .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference => true,
            else => false,
        };
    }

    pub fn reportsByteProgress(self: Operation) bool {
        return self == .installing or self == .updating or self == .verifying;
    }
};

pub const ModelAction = enum {
    install,
    update,
    resume_operation,
    retry_operation,
    discard,
    verify,
    repair,
    remove,
    retry_runtime,
    cancel_operation,
    diagnostics,
};

pub const ModelFailure = enum {
    none,
    installation_corrupt,
    runtime_unavailable,
    operation_failed,
    operation_cancelled,
};

/// The text-free masked projection of one Insertion Record — the **Recent Insertions View**
/// (CONTEXT.md, spec §4.1). It carries only metadata: no `inserted` / `raw` transcript
/// bytes ever reach it, so the whole `Snapshot` stays privacy-clean by construction. Fixed
/// inline fields make it `std.meta.eql`-comparable, so it rides through `project` / `derive`
/// without breaking `refreshChrome`'s snapshot early-out.
pub const HistoryEntryView = struct {
    char_len: u16 = 0,
    app: ?coord.AppIdentity = null,
    timestamp: i64 = 0,
    outcome: coord.InsertResult = .ok,
};

/// Project one authoritative Insertion Record to its text-free view. Reads the record's
/// byte buffer for the codepoint count only — no transcript bytes leave the ring's side.
pub fn historyEntryView(rec: *const recent_insertions.Record) HistoryEntryView {
    const bytes = rec.inserted();
    const chars = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
    return .{
        .char_len = @intCast(@min(chars, std.math.maxInt(u16))),
        .app = rec.focused_app,
        .timestamp = rec.timestamp,
        .outcome = rec.outcome,
    };
}

pub const Snapshot = struct {
    selected_backend: backend.Backend,
    health: readiness.Health,
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    installation: Installation = .absent,
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    installation_identity: ?InstallationIdentity = null,
    failure_detail: ?FailureDetail = null,
    /// The Recent Insertions View — masked, text-free, newest-first (spec §4.1). Fixed
    /// `[capacity]`; only `[0..history_count]` is live. Kept `eql`-comparable so the menu's
    /// snapshot early-out keeps working.
    history: [recent_insertions.capacity]HistoryEntryView = @splat(.{}),
    history_count: usize = 0,
};

pub const ByteProgress = struct { completed: u64, total: u64 };
pub const InstallationIdentity = installation_identity.Identity;
pub const FailureDetail = struct {
    bytes: [256]u8 = @splat(0),
    len: u16 = 0,

    pub fn init(detail: []const u8) !FailureDetail {
        if (detail.len == 0 or detail.len > 256) return error.InvalidFailureDetail;
        var result = FailureDetail{ .len = @intCast(detail.len) };
        @memcpy(result.bytes[0..detail.len], detail);
        return result;
    }

    pub fn value(self: *const FailureDetail) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Headline = enum {
    paused,
    microphone_needed,
    input_monitoring_needed,
    accessibility_needed,
    selected_backend_prerequisite_missing,
    backend_failure,
    preparing,
    ready,
    ready_offline,
};

pub const PrimaryAction = enum {
    none,
    set_openai_api_key,
    install_local_model,
    update_local_model,
    resume_model_operation,
    retry_model_operation,
    repair_local_model,
    retry_local_runtime,
    operation_progress,
};

/// The two-tier menu-bar icon (CONTEXT.md, Status Item): `normal` when dictation can fire,
/// `dimmed` when it needs attention (paused / a missing grant / a backend failure).
pub const IconTier = enum { normal, dimmed };

/// The status dot colour for one history entry (spec §4): green `ok`, amber `degraded`,
/// red `failed`.
pub const HistoryDot = enum { ok, degraded, failed };

/// The distinct outcome tag rendered beside the dot so a never-inserted (`failed`) or
/// `degraded` entry is unmistakable (spec §2.4 / §4). `.none` for a clean `ok` insertion.
pub const HistoryTag = enum { none, degraded, failed };

/// One entry as the menu renders it — the derived, still text-free descriptor. `derive`
/// turns each `HistoryEntryView` into this (dot colour + tag from the outcome), leaving the
/// menu a dumb adapter that only formats the masked label (spec §4.1).
pub const HistoryEntry = struct {
    dot: HistoryDot = .ok,
    tag: HistoryTag = .none,
    char_len: u16 = 0,
    app: ?coord.AppIdentity = null,
    timestamp: i64 = 0,
};

/// The rendered Recent Insertions View: newest-first entries, `[0..count]` live.
pub const HistoryView = struct {
    entries: [recent_insertions.capacity]HistoryEntry = @splat(.{}),
    count: usize = 0,
};

pub const Presentation = struct {
    headline: Headline,
    icon_tier: IconTier,
    primary_action: PrimaryAction,
    show_openai_controls: bool,
    audio_stays_on_mac: bool,
    model_operation_uses_network: bool,
    model_actions: std.EnumSet(ModelAction),
    model_failure: ModelFailure,
    history: HistoryView,

    pub fn allowsModelAction(self: Presentation, action: ModelAction) bool {
        return self.model_actions.contains(action);
    }
};

/// The derived dot colour + tag for one recorded outcome (spec §4).
fn historyDot(outcome: coord.InsertResult) HistoryDot {
    return switch (outcome) { .ok => .ok, .degraded => .degraded, .failed => .failed };
}
fn historyTag(outcome: coord.InsertResult) HistoryTag {
    return switch (outcome) { .ok => .none, .degraded => .degraded, .failed => .failed };
}

/// Turn the text-free views the `Snapshot` carries into the menu-ready `HistoryView`
/// (dot colour + tag), preserving the ring's newest-first order.
fn deriveHistory(s: Snapshot) HistoryView {
    var view = HistoryView{ .count = s.history_count };
    for (s.history[0..s.history_count], 0..) |entry, i| {
        view.entries[i] = .{
            .dot = historyDot(entry.outcome),
            .tag = historyTag(entry.outcome),
            .char_len = entry.char_len,
            .app = entry.app,
            .timestamp = entry.timestamp,
        };
    }
    return view;
}

pub fn derive(s: Snapshot) Presentation {
    const operation_active = s.operation.isActive();
    const hl = headline(s);
    return .{
        .history = deriveHistory(s),
        .headline = hl,
        // The dim tier folds the readiness attention signal with the backend-failure
        // headline into one field, so the menu no longer re-ORs two modules' terms.
        .icon_tier = if (s.health.needsAttention() or hl == .backend_failure) .dimmed else .normal,
        .primary_action = primaryAction(s),
        .show_openai_controls = s.selected_backend == .openai,
        .audio_stays_on_mac = s.selected_backend == .local and
            s.health.status == .ready_offline,
        .model_operation_uses_network = operation_active,
        .model_actions = modelActions(s, operation_active),
        .model_failure = if (s.operation == .failed)
            .operation_failed
        else if (s.operation == .cancelled)
            .operation_cancelled
        else if (s.installation == .corrupt)
            .installation_corrupt
        else if (s.local_runtime_failure)
            .runtime_unavailable
        else
            .none,
    };
}

/// The Model Operation Runner's live observation, in status_item-native types (mirrors
/// model_operation's `Current` so this module needn't import — and cycle with — that one).
pub const Observation = struct {
    active: bool,
    phase: Operation,
    bytes: ?ByteProgress,
    failure_detail: ?FailureDetail,
};

/// The daemon-gathered readings `project` assembles a `Snapshot` from. Everything here is
/// already mapped to status_item-native values by the daemon's gathering glue (the
/// model_store I/O and the recovery-phase -> Operation map); this struct carries no
/// model_store or provisioner types, so the projection policy stays pure and testable.
pub const Readings = struct {
    selected_backend: backend.Backend,
    health: readiness.Health,
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    /// The on-disk installation view before the corrupt override (absent/ready/update).
    installation: Installation = .absent,
    recovery_is_corrupt: bool = false,
    /// The on-disk operation view before the runner override.
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    installation_identity: ?InstallationIdentity = null,
    provisioner_failure_detail: ?FailureDetail = null,
    observed: ?Observation = null,
    /// The daemon's text-free projection of the Recent Insertions ring, newest-first
    /// (spec §4.1). `[0..history_count]` is live.
    history: [recent_insertions.capacity]HistoryEntryView = @splat(.{}),
    history_count: usize = 0,
};

/// Assemble the `Snapshot` the menu renders from the daemon's readings — the corrupt
/// override and the runner-observation precedence that used to live inline in
/// daemon.menuStatus. Pure policy over already-mapped values; the I/O and the enum mapping
/// stay in the daemon.
pub fn project(r: Readings) Snapshot {
    var installation = r.installation;
    if (r.recovery_is_corrupt) installation = .corrupt;

    var operation = r.operation;
    var operation_bytes = r.operation_bytes;
    var failure_detail = r.provisioner_failure_detail;
    if (r.observed) |o| {
        // The Runner's live observation overrides the on-disk recovery view — except a
        // paused operation stays paused unless the Runner is actively driving one, so a
        // stale idle observation cannot erase a paused resume point.
        if (o.active or operation != .paused) {
            operation = o.phase;
            operation_bytes = o.bytes;
        }
        failure_detail = o.failure_detail;
    }

    return .{
        .selected_backend = r.selected_backend,
        .health = r.health,
        .terminal_backend_failure = r.terminal_backend_failure,
        .local_runtime_failure = r.local_runtime_failure,
        .installation = installation,
        .operation = operation,
        .operation_bytes = operation_bytes,
        .installation_identity = r.installation_identity,
        .failure_detail = failure_detail,
        .history = r.history,
        .history_count = r.history_count,
    };
}

fn modelActions(s: Snapshot, operation_active: bool) std.EnumSet(ModelAction) {
    var actions: std.EnumSet(ModelAction) = .empty;
    actions.insert(.diagnostics);
    switch (s.operation) {
        .paused => {
            actions.insert(.resume_operation);
            actions.insert(.discard);
            return actions;
        },
        .failed, .cancelled => {
            actions.insert(.retry_operation);
            return actions;
        },
        .idle => {},
        else => {
            if (s.operation.isCancellable()) actions.insert(.cancel_operation);
            return actions;
        },
    }
    std.debug.assert(!operation_active);
    switch (s.installation) {
        .absent => actions.insert(.install),
        .ready => {
            actions.insert(.verify);
            actions.insert(.remove);
        },
        .update_available => {
            actions.insert(.update);
            actions.insert(.verify);
            actions.insert(.remove);
        },
        .corrupt => {
            actions.insert(.verify);
            actions.insert(.repair);
            actions.insert(.remove);
        },
    }
    if (s.local_runtime_failure) actions.insert(.retry_runtime);
    return actions;
}

fn headline(s: Snapshot) Headline {
    if (s.health.paused) return .paused;
    switch (s.health.status) {
        .microphone_needed => return .microphone_needed,
        .input_monitoring_needed => return .input_monitoring_needed,
        .accessibility_needed => return .accessibility_needed,
        else => {},
    }
    switch (s.health.status) {
        .no_key, .no_local_installation => return .selected_backend_prerequisite_missing,
        else => {},
    }
    if (s.terminal_backend_failure or (s.selected_backend == .local and s.installation == .corrupt)) return .backend_failure;
    return switch (s.health.status) {
        .reconnecting, .preparing_local => .preparing,
        .ready => .ready,
        .ready_offline => .ready_offline,
        .no_key, .no_local_installation, .microphone_needed, .input_monitoring_needed, .accessibility_needed => unreachable,
    };
}

fn primaryAction(s: Snapshot) PrimaryAction {
    if (s.selected_backend == .openai)
        return if (s.health.status == .no_key) .set_openai_api_key else .none;
    if (s.operation == .paused) return .resume_model_operation;
    if (s.operation == .failed or s.operation == .cancelled) return .retry_model_operation;
    if (s.operation.isActive()) return .operation_progress;
    if (s.installation == .absent) return .install_local_model;
    if (s.installation == .corrupt) return .repair_local_model;
    if (s.terminal_backend_failure) return .retry_local_runtime;
    if (s.installation == .update_available) return .update_local_model;
    return .none;
}

/// A short relative-time phrase for a history row (spec §4). `delta_ms` is `now - timestamp`;
/// impure `now` stays with the caller so this — and `historyLabel` — remain pure and testable.
fn relativeTime(buf: []u8, delta_ms_in: i64) []const u8 {
    const delta_ms: i64 = if (delta_ms_in < 0) 0 else delta_ms_in;
    const secs = @divTrunc(delta_ms, 1000);
    if (secs < 60) return "just now";
    const mins = @divTrunc(secs, 60);
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{mins}) catch "just now";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "just now";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(hours, 24)}) catch "just now";
}

/// The status-dot emoji glyph for an entry (a menu title carries no per-glyph colour, so the
/// colour rides the glyph): green `ok`, amber `degraded`, red `failed`.
fn historyDotGlyph(dot: HistoryDot) [:0]const u8 {
    return switch (dot) {
        .ok => "\xf0\x9f\x9f\xa2", // 🟢
        .degraded => "\xf0\x9f\x9f\xa1", // 🟡
        .failed => "\xf0\x9f\x94\xb4", // 🔴
    };
}

/// The trailing `[degraded]` / `[failed]` pill so a never-inserted (or degraded) entry is
/// unmistakable (spec §2.4 / §4); empty for a clean `ok`.
fn historyTagSuffix(tag: HistoryTag) []const u8 {
    return switch (tag) {
        .none => "",
        .degraded => "  [degraded]",
        .failed => "  [failed]",
    };
}

/// Assemble one history row: `<dot> <body> · <App> · <time>  [<tag>]`, the shared shape of the
/// masked and revealed labels — only `body` differs (the `•` run + char count vs the actual
/// text). Keeping the dot/app/time/tag scaffolding single-homed means the row shape is edited
/// in one place. Returns a sentinel-terminated slice for `NSString`; `now_ms` is the caller's
/// clock.
fn historyRowLabel(buf: []u8, entry: HistoryEntry, body: []const u8, now_ms: i64) [:0]const u8 {
    const dot = historyDotGlyph(entry.dot);
    const tag = historyTagSuffix(entry.tag);
    var when: [24]u8 = undefined;
    const ago = relativeTime(&when, now_ms - entry.timestamp);
    const mid = " \xc2\xb7 "; // " · " (U+00B7)
    if (entry.app) |app| {
        if (app.displayName().len > 0)
            return std.fmt.bufPrintSentinel(buf, "{s} {s}{s}{s}{s}{s}{s}", .{
                dot, body, mid, app.displayName(), mid, ago, tag,
            }, 0) catch dot;
    }
    return std.fmt.bufPrintSentinel(buf, "{s} {s}{s}{s}{s}", .{
        dot, body, mid, ago, tag,
    }, 0) catch dot;
}

/// Format one masked entry label — **metadata only, never the `inserted` text** (spec §4):
/// `<dot> <masked run> · <n> chars · <App> · <time>  [<tag>]`. The `•` run is a capped stand-in
/// for the hidden receipt, and `char_len` reports its length. Returns a sentinel-terminated
/// slice for `NSString`; `now_ms` is the caller's clock.
pub fn historyLabel(buf: []u8, entry: HistoryEntry, now_ms: i64) [:0]const u8 {
    var bullets: [8 * 3]u8 = undefined; // •, U+2022, is 3 bytes; capped at 8
    const runs: usize = @max(@as(usize, 1), @min(@as(usize, entry.char_len), 8));
    var bi: usize = 0;
    while (bi < runs * 3) : (bi += 3) @memcpy(bullets[bi..][0..3], "\xe2\x80\xa2");
    const run = bullets[0 .. runs * 3];

    var body_buf: [8 * 3 + 4 + 16]u8 = undefined; // run + " · " + "65535 chars"
    const body = std.fmt.bufPrint(&body_buf, "{s} \xc2\xb7 {d} chars", .{ run, entry.char_len }) catch run;
    return historyRowLabel(buf, entry, body, now_ms);
}

/// The capped, trailing-space-trimmed `inserted` snippet a revealed row shows. `inserted`
/// carries its single trailing space (the Insertion-chaining artifact); it is stripped for
/// display. Long dictations are truncated at `reveal_snippet_cap` codepoints with an ellipsis
/// so one entry can't blow the menu width. Codepoint-safe: an invalid-UTF-8 fallback caps by
/// bytes. Writes into `out`; returns the written slice.
const reveal_snippet_cap = 96;
fn revealSnippet(out: []u8, text_in: []const u8) []const u8 {
    const ell = "\xe2\x80\xa6"; // … (U+2026)
    const text = std.mem.trimEnd(u8, text_in, " \t\r\n");
    const view = std.unicode.Utf8View.init(text) catch {
        // Not valid UTF-8 (shouldn't happen for a transcript): cap by bytes, no ellipsis.
        const n = @min(text.len, out.len);
        @memcpy(out[0..n], text[0..n]);
        return out[0..n];
    };
    var iter = view.iterator();
    var count: usize = 0;
    while (count < reveal_snippet_cap) : (count += 1) {
        if (iter.nextCodepointSlice() == null) break;
    }
    const end = iter.i;
    if (end >= text.len) {
        const n = @min(text.len, out.len);
        @memcpy(out[0..n], text[0..n]);
        return out[0..n];
    }
    // Truncated: copy the first `end` bytes, then append the ellipsis.
    const n = @min(end, out.len -| ell.len);
    @memcpy(out[0..n], text[0..n]);
    @memcpy(out[n..][0..ell.len], ell);
    return out[0 .. n + ell.len];
}

/// Format one **revealed** entry label (spec §4 reveal): the same row as `historyLabel` but
/// with the masked `•` run and char count replaced by the entry's actual `inserted` `text`,
/// fetched on demand from the ring (never from the `Snapshot`). `text` is the with-space
/// `inserted` bytes; `revealSnippet` trims and caps it. Dot, App Identity, relative time and
/// the degraded/failed tag are unchanged. Returns a sentinel-terminated slice; `now_ms` is the
/// caller's clock.
pub fn historyRevealedLabel(buf: []u8, entry: HistoryEntry, text: []const u8, now_ms: i64) [:0]const u8 {
    var snip_buf: [reveal_snippet_cap * 4 + 3]u8 = undefined;
    const shown = revealSnippet(&snip_buf, text);
    return historyRowLabel(buf, entry, shown, now_ms);
}

fn snap(fields: struct {
    selected_backend: backend.Backend = .local,
    health: readiness.Health = .{ .paused = false, .status = .ready_offline },
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    installation: Installation = .ready,
    operation: Operation = .idle,
}) Snapshot {
    return .{
        .selected_backend = fields.selected_backend,
        .health = fields.health,
        .terminal_backend_failure = fields.terminal_backend_failure,
        .local_runtime_failure = fields.local_runtime_failure,
        .installation = fields.installation,
        .operation = fields.operation,
    };
}

test "compact headline follows pause, common prerequisite, selected prerequisite, failure, preparation, ready priority" {
    try std.testing.expectEqual(Headline.paused, derive(snap(.{ .health = .{ .paused = true, .status = .no_local_installation }, .terminal_backend_failure = true })).headline);
    try std.testing.expectEqual(Headline.microphone_needed, derive(snap(.{ .health = .{ .paused = false, .status = .microphone_needed }, .installation = .absent })).headline);
    try std.testing.expectEqual(Headline.input_monitoring_needed, derive(snap(.{ .health = .{ .paused = false, .status = .input_monitoring_needed }, .installation = .absent })).headline);
    try std.testing.expectEqual(Headline.selected_backend_prerequisite_missing, derive(snap(.{ .health = .{ .paused = false, .status = .no_local_installation }, .terminal_backend_failure = true, .installation = .absent })).headline);
    try std.testing.expectEqual(Headline.backend_failure, derive(snap(.{ .terminal_backend_failure = true })).headline);
    try std.testing.expectEqual(Headline.preparing, derive(snap(.{ .health = .{ .paused = false, .status = .preparing_local } })).headline);
    try std.testing.expectEqual(Headline.ready_offline, derive(snap(.{})).headline);
}

test "compact hierarchy exposes only the selected backend primary action" {
    try std.testing.expectEqual(PrimaryAction.set_openai_api_key, derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .no_key },
        .installation = .update_available,
    })).primary_action);
    try std.testing.expectEqual(PrimaryAction.install_local_model, derive(snap(.{
        .health = .{ .paused = false, .status = .no_local_installation },
        .installation = .absent,
    })).primary_action);
    try std.testing.expectEqual(PrimaryAction.update_local_model, derive(snap(.{ .installation = .update_available })).primary_action);
    try std.testing.expectEqual(PrimaryAction.repair_local_model, derive(snap(.{ .installation = .corrupt })).primary_action);
    try std.testing.expectEqual(PrimaryAction.retry_local_runtime, derive(snap(.{ .terminal_backend_failure = true })).primary_action);
}

test "local privacy cues survive every active Model Operation stage" {
    for ([_]Operation{ .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference, .activating, .removing, .discarding }) |operation| {
        const p = derive(snap(.{ .operation = operation }));
        try std.testing.expect(p.audio_stays_on_mac);
        try std.testing.expect(p.model_operation_uses_network);
        try std.testing.expectEqual(PrimaryAction.operation_progress, p.primary_action);
        try std.testing.expect(!p.show_openai_controls);
    }
}

test "local Model Operation recovery stays in its submenu under OpenAI selection" {
    const p = derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
        .operation = .paused,
    }));
    try std.testing.expectEqual(PrimaryAction.none, p.primary_action);
    try std.testing.expect(p.show_openai_controls);
    try std.testing.expect(!p.audio_stays_on_mac);
}

test "unselected local corruption and runtime failure do not change OpenAI headline" {
    const p = derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
        .installation = .corrupt,
        .local_runtime_failure = true,
    }));
    try std.testing.expectEqual(Headline.ready, p.headline);
    try std.testing.expectEqual(PrimaryAction.none, p.primary_action);
}

test "restart-paused Model Operation exposes only Resume and Discard recovery" {
    const p = derive(snap(.{ .operation = .paused }));

    try std.testing.expectEqual(PrimaryAction.resume_model_operation, p.primary_action);
    try std.testing.expect(p.allowsModelAction(.resume_operation));
    try std.testing.expect(p.allowsModelAction(.discard));
    try std.testing.expect(!p.allowsModelAction(.install));
    try std.testing.expect(!p.allowsModelAction(.cancel_operation));
}

test "failed and cancelled Model Operations retry instead of pretending to resume partial data" {
    for ([_]Operation{ .failed, .cancelled }) |operation| {
        const p = derive(snap(.{ .operation = operation }));

        try std.testing.expectEqual(PrimaryAction.retry_model_operation, p.primary_action);
        try std.testing.expect(p.allowsModelAction(.retry_operation));
        try std.testing.expect(!p.allowsModelAction(.resume_operation));
        try std.testing.expect(!p.allowsModelAction(.discard));
    }
}

test "Cancel is offered only while a Model Operation stage is cancellable" {
    for ([_]Operation{ .installing, .updating, .verifying, .smoke_testing, .waiting_for_inference }) |operation|
        try std.testing.expect(derive(snap(.{ .operation = operation })).allowsModelAction(.cancel_operation));
    for ([_]Operation{ .activating, .removing, .discarding }) |operation|
        try std.testing.expect(!derive(snap(.{ .operation = operation })).allowsModelAction(.cancel_operation));
}

test "Local Model failures identify the actionable recovery" {
    try std.testing.expectEqual(ModelFailure.installation_corrupt, derive(snap(.{ .installation = .corrupt })).model_failure);
    try std.testing.expectEqual(ModelFailure.runtime_unavailable, derive(snap(.{ .local_runtime_failure = true })).model_failure);
    try std.testing.expectEqual(ModelFailure.operation_failed, derive(snap(.{ .operation = .failed })).model_failure);
    try std.testing.expectEqual(ModelFailure.operation_cancelled, derive(snap(.{ .operation = .cancelled })).model_failure);
    try std.testing.expectEqual(ModelFailure.none, derive(snap(.{})).model_failure);
}

test "icon dims on the readiness attention signal and the backend-failure headline" {
    // Attention statuses dim the icon.
    try std.testing.expectEqual(IconTier.dimmed, derive(snap(.{ .health = .{ .paused = true, .status = .ready_offline } })).icon_tier);
    try std.testing.expectEqual(IconTier.dimmed, derive(snap(.{ .health = .{ .paused = false, .status = .microphone_needed }, .installation = .absent })).icon_tier);
    // A backend failure dims even when readiness alone would not (folds the second term).
    try std.testing.expectEqual(IconTier.dimmed, derive(snap(.{ .terminal_backend_failure = true })).icon_tier);
    // A ready backend keeps the icon normal.
    try std.testing.expectEqual(IconTier.normal, derive(snap(.{})).icon_tier);
    try std.testing.expectEqual(IconTier.normal, derive(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
    })).icon_tier);
}

fn reads(fields: struct {
    installation: Installation = .ready,
    recovery_is_corrupt: bool = false,
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    provisioner_failure_detail: ?FailureDetail = null,
    observed: ?Observation = null,
}) Readings {
    return .{
        .selected_backend = .local,
        .health = .{ .paused = false, .status = .ready_offline },
        .installation = fields.installation,
        .recovery_is_corrupt = fields.recovery_is_corrupt,
        .operation = fields.operation,
        .operation_bytes = fields.operation_bytes,
        .provisioner_failure_detail = fields.provisioner_failure_detail,
        .observed = fields.observed,
    };
}

test "project: the corrupt recovery flag overrides the on-disk installation view" {
    try std.testing.expectEqual(Installation.corrupt, project(reads(.{ .installation = .ready, .recovery_is_corrupt = true })).installation);
    try std.testing.expectEqual(Installation.ready, project(reads(.{ .installation = .ready, .recovery_is_corrupt = false })).installation);
}

test "project: an active runner observation overrides the on-disk operation and bytes" {
    const s = project(reads(.{
        .operation = .idle,
        .operation_bytes = null,
        .observed = .{ .active = true, .phase = .installing, .bytes = .{ .completed = 3, .total = 9 }, .failure_detail = null },
    }));
    try std.testing.expectEqual(Operation.installing, s.operation);
    try std.testing.expectEqual(@as(u64, 3), s.operation_bytes.?.completed);
}

test "project: a paused operation survives a stale inactive observation" {
    // observed.active = false AND on-disk op == .paused → the paused resume point stays.
    const s = project(reads(.{
        .operation = .paused,
        .operation_bytes = .{ .completed = 5, .total = 10 },
        .observed = .{ .active = false, .phase = .idle, .bytes = null, .failure_detail = null },
    }));
    try std.testing.expectEqual(Operation.paused, s.operation);
    try std.testing.expectEqual(@as(u64, 5), s.operation_bytes.?.completed);
}

test "project: a non-paused on-disk operation yields to an inactive observation" {
    // observed.active = false but on-disk op != .paused → the observation still wins.
    const s = project(reads(.{
        .operation = .installing,
        .observed = .{ .active = false, .phase = .idle, .bytes = null, .failure_detail = null },
    }));
    try std.testing.expectEqual(Operation.idle, s.operation);
}

test "project: failure_detail comes from the observation whenever one is present" {
    const provisioner_detail = try FailureDetail.init("provisioner");
    const observed_detail = try FailureDetail.init("runner");

    // No observation → the provisioner detail passes through.
    const without = project(reads(.{ .provisioner_failure_detail = provisioner_detail }));
    try std.testing.expectEqualStrings("provisioner", without.failure_detail.?.value());

    // Observation present → its detail replaces the provisioner's, regardless of activity.
    const with = project(reads(.{
        .provisioner_failure_detail = provisioner_detail,
        .observed = .{ .active = false, .phase = .idle, .bytes = null, .failure_detail = observed_detail },
    }));
    try std.testing.expectEqualStrings("runner", with.failure_detail.?.value());
}

// ============================================================================
// Recent Insertions View — the text-free pure split (spec §4.1).
// ============================================================================

fn record(text: []const u8, outcome: coord.InsertResult, app: ?coord.AppIdentity) recent_insertions.Record {
    var rec = recent_insertions.Record{};
    @memcpy(rec.inserted_bytes[0..text.len], text);
    rec.inserted_len = text.len;
    rec.outcome = outcome;
    rec.timestamp = 1000;
    rec.focused_app = app;
    return rec;
}

test "historyEntryView projects metadata only — no transcript bytes cross" {
    const rec = record("at 18:00 ", .degraded, coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack"));
    const view = historyEntryView(&rec);
    try std.testing.expectEqual(@as(u16, 9), view.char_len); // codepoints of "at 18:00 " incl. trailing space
    try std.testing.expectEqual(coord.InsertResult.degraded, view.outcome);
    try std.testing.expectEqual(@as(i64, 1000), view.timestamp);
    try std.testing.expectEqualStrings("Slack", view.app.?.displayName());
    // The view type has no field that could carry `inserted` / `raw` text at all.
    try std.testing.expect(!@hasField(HistoryEntryView, "inserted"));
    try std.testing.expect(!@hasField(HistoryEntryView, "raw"));
}

test "historyEntryView counts UTF-8 codepoints, not bytes" {
    const rec = record("café ", .ok, null); // 'é' is 2 bytes, 1 codepoint → 5 chars
    try std.testing.expectEqual(@as(u16, 5), historyEntryView(&rec).char_len);
}

fn history(views: []const HistoryEntryView) Snapshot {
    var s = snap(.{});
    for (views, 0..) |v, i| s.history[i] = v;
    s.history_count = views.len;
    return s;
}

test "derive maps outcome to dot colour and tag, newest-first order preserved" {
    const s = history(&.{
        .{ .char_len = 3, .outcome = .failed, .timestamp = 30 },
        .{ .char_len = 2, .outcome = .degraded, .timestamp = 20 },
        .{ .char_len = 1, .outcome = .ok, .timestamp = 10 },
    });
    const h = derive(s).history;
    try std.testing.expectEqual(@as(usize, 3), h.count);
    try std.testing.expectEqual(HistoryDot.failed, h.entries[0].dot);
    try std.testing.expectEqual(HistoryTag.failed, h.entries[0].tag);
    try std.testing.expectEqual(HistoryDot.degraded, h.entries[1].dot);
    try std.testing.expectEqual(HistoryTag.degraded, h.entries[1].tag);
    try std.testing.expectEqual(HistoryDot.ok, h.entries[2].dot);
    try std.testing.expectEqual(HistoryTag.none, h.entries[2].tag); // a clean insertion gets no tag
    try std.testing.expectEqual(@as(u16, 3), h.entries[0].char_len); // order == the ring's newest-first
}

test "an empty history derives to an empty view" {
    try std.testing.expectEqual(@as(usize, 0), derive(snap(.{})).history.count);
}

test "project carries the history views through unchanged" {
    var r = reads(.{});
    r.history[0] = .{ .char_len = 7, .outcome = .failed, .timestamp = 5 };
    r.history_count = 1;
    const s = project(r);
    try std.testing.expectEqual(@as(usize, 1), s.history_count);
    try std.testing.expectEqual(coord.InsertResult.failed, s.history[0].outcome);
}

test "historyLabel masks the transcript: dot, capped bullet run, char count, app, time, tag" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .failed, .tag = .failed, .char_len = 39, .app = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack"), .timestamp = 0 };
    const label = historyLabel(&buf, entry, 120_000); // 2 minutes later
    try std.testing.expect(std.mem.indexOf(u8, label, "\xf0\x9f\x94\xb4") != null); // 🔴 failed dot
    try std.testing.expect(std.mem.indexOf(u8, label, "\xe2\x80\xa2") != null); // a • masked run
    try std.testing.expect(std.mem.indexOf(u8, label, "39 chars") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "Slack") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "2m ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[failed]") != null);
}

test "historyLabel omits the app segment when no App Identity was captured" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .ok, .tag = .none, .char_len = 4, .app = null, .timestamp = 0 };
    const label = historyLabel(&buf, entry, 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "4 chars") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "just now") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[") == null); // an ok entry carries no tag
}

test "historyRevealedLabel shows the transcript text, trailing space trimmed, with metadata" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .failed, .tag = .failed, .char_len = 9, .app = coord.AppIdentity.init("com.tinyspeck.slackmacgap", "Slack"), .timestamp = 0 };
    const label = historyRevealedLabel(&buf, entry, "At 18:00 ", 120_000);
    try std.testing.expect(std.mem.indexOf(u8, label, "\xf0\x9f\x94\xb4") != null); // 🔴 failed dot
    try std.testing.expect(std.mem.indexOf(u8, label, "At 18:00") != null); // the actual text
    try std.testing.expect(std.mem.indexOf(u8, label, "At 18:00  \xc2\xb7") == null); // trailing space trimmed (no double space before the separator)
    try std.testing.expect(std.mem.indexOf(u8, label, "\xe2\x80\xa2") == null); // no masked bullet run
    try std.testing.expect(std.mem.indexOf(u8, label, "chars") == null); // char count replaced by text
    try std.testing.expect(std.mem.indexOf(u8, label, "Slack") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "2m ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[failed]") != null);
}

test "historyRevealedLabel omits the app segment when no App Identity was captured" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .ok, .tag = .none, .char_len = 6, .app = null, .timestamp = 0 };
    const label = historyRevealedLabel(&buf, entry, "hello ", 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "just now") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[") == null);
}

test "revealSnippet caps a long transcript at the codepoint limit with an ellipsis" {
    var out: [reveal_snippet_cap * 4 + 3]u8 = undefined;
    var long: [200]u8 = @splat('a');
    const snip = revealSnippet(&out, &long);
    try std.testing.expect(std.mem.endsWith(u8, snip, "\xe2\x80\xa6")); // …
    try std.testing.expectEqual(@as(usize, reveal_snippet_cap + 3), snip.len); // 96 'a' + 3-byte …
}

test "revealSnippet is codepoint-safe: it never truncates a multi-byte codepoint mid-way" {
    var out: [reveal_snippet_cap * 4 + 3]u8 = undefined;
    // 200 "é" (U+00E9, 2 bytes each) — capping at 96 codepoints must land on a boundary.
    var many: [400]u8 = undefined;
    var i: usize = 0;
    while (i < 400) : (i += 2) @memcpy(many[i..][0..2], "\xc3\xa9");
    const snip = revealSnippet(&out, &many);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snip)); // no split codepoint
    try std.testing.expect(std.mem.endsWith(u8, snip, "\xe2\x80\xa6"));
}

test "revealSnippet passes a short transcript through untruncated" {
    var out: [reveal_snippet_cap * 4 + 3]u8 = undefined;
    try std.testing.expectEqualStrings("hi there", revealSnippet(&out, "hi there "));
}

test "relativeTime buckets by magnitude" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("just now", relativeTime(&buf, 5_000));
    try std.testing.expectEqualStrings("2m ago", relativeTime(&buf, 120_000));
    try std.testing.expectEqualStrings("3h ago", relativeTime(&buf, 3 * 3_600_000));
    try std.testing.expectEqualStrings("2d ago", relativeTime(&buf, 2 * 86_400_000));
    try std.testing.expectEqualStrings("just now", relativeTime(&buf, -10_000)); // clock skew floors to now
}
