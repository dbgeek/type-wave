//! Pure presentation policy for the compact Status Item hierarchy.
//!
//! Three stages, all pure, each separately assertable (ADR-0011):
//!
//!   1. `project(Readings) -> Snapshot`   — what is true (the corrupt override, runner precedence)
//!   2. `derive(Snapshot)  -> Decisions`  — what it means (headline, icon tier, primary action)
//!   3. `present(Decisions, SettingsView) -> Presentation` — how it reads (every title, every
//!      `hidden` / `enabled` / `checked` flag)
//!
//! The `Presentation` is **complete**: it carries the finished bytes of every row the Status
//! Item shows, so the **Status Item Chrome** seam it crosses (`apply(Presentation)`) decides
//! nothing. `AppKitChrome` in menu.zig is the production adapter — every ObjC call lives
//! there — and a `FakeChrome` below records applied Presentations, so the row titles are
//! asserted as values rather than read out of a running menu.
//!
//! The one thing the Presentation deliberately does *not* carry is Recent Insertions row
//! text: a history row is structural (`entry` + `revealed` + `hidden`) and the adapter formats
//! it with `historyLabel` / `historyRevealedLabel`, fetching the `inserted` bytes on demand
//! from the authoritative ring. That keeps transcript bytes out of a projected value —
//! privacy by construction, the same rule the `Snapshot` follows.

const std = @import("std");
const backend = @import("transcription_backend.zig");
const config = @import("config.zig");
const installation_identity = @import("installation_identity.zig");
const readiness = @import("readiness.zig");
const coord = @import("coordinator.zig");
const recent_insertions = @import("recent_insertions.zig");
const secure_input = @import("secure_input.zig");
const tapmod = @import("tap.zig");
const insertmod = @import("insert.zig");

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
    /// The record was undone by `⌃⌘⌫` (#225, single-shot model): the row renders dimmed and a
    /// re-insert of it acts as a redo. Masked like every other field — no transcript bytes.
    undone: bool = false,
    /// The Utterance was spoken under a held Secure Event Input, so the ring stored none of its
    /// text (#286). The row says so instead of showing a masked run, and `char_len` stays 0 —
    /// the one row whose content is presumed a secret is the one row not to publish a length
    /// for.
    withheld: bool = false,
};

/// Project one authoritative Insertion Record to its text-free view. Reads the record's
/// byte buffer for the codepoint count only — no transcript bytes leave the ring's side.
pub fn historyEntryView(rec: *const recent_insertions.Record) HistoryEntryView {
    const bytes = rec.inserted();
    const chars = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
    return .{
        // A withheld record has no bytes to count, and publishes no length either way.
        .char_len = if (rec.withheld) 0 else @intCast(@min(chars, std.math.maxInt(u16))),
        .app = rec.focused_app,
        .timestamp = rec.timestamp,
        .outcome = rec.outcome,
        .undone = rec.undone,
        .withheld = rec.withheld,
    };
}

pub const Snapshot = struct {
    selected_backend: backend.Backend,
    health: readiness.Health,
    /// Secure Event Input, as the Secure Input Observer published it on the supervisor's facts
    /// pass (#245). Not part of `health`: it gates nothing and dims nothing — dictation is
    /// unaffected — it is a capability the user needs told about, not a prerequisite the
    /// daemon is waiting on. The holder's *name* stays in the log; a plain enum keeps the
    /// whole `Snapshot` `std.meta.eql`-comparable and free of cross-thread string sharing.
    secure_input: secure_input.State = .clear,
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

/// The distinct outcome tag rendered beside the dot so a never-inserted (`failed` /
/// `refused`) or `degraded` entry is unmistakable (spec §2.4 / §4). `.none` for a clean `ok`
/// insertion. `refused` keeps its own tag rather than folding into `failed`: both mean
/// nothing landed, but only one of them means something went wrong, and the recovery differs
/// — a refused transcript re-inserts cleanly once the intended app is frontmost again.
pub const HistoryTag = enum { none, degraded, failed, refused };

/// One entry as the menu renders it — the derived, still text-free descriptor. `derive`
/// turns each `HistoryEntryView` into this (dot colour + tag from the outcome), leaving the
/// menu a dumb adapter that only formats the masked label (spec §4.1).
pub const HistoryEntry = struct {
    dot: HistoryDot = .ok,
    tag: HistoryTag = .none,
    char_len: u16 = 0,
    app: ?coord.AppIdentity = null,
    timestamp: i64 = 0,
    /// Undone by `⌃⌘⌫` (#225): the row renders dimmed with an `[undone]` marker; re-insert redoes.
    undone: bool = false,
    /// Spoken under a held Secure Event Input (#286): the body reads `not retained` and the row
    /// trails a `[secure input]` marker. Orthogonal to `tag`, which reports the *outcome* — a
    /// withheld Insertion can equally have landed, failed or been refused.
    withheld: bool = false,
};

/// The rendered Recent Insertions View: newest-first entries, `[0..count]` live.
pub const HistoryView = struct {
    entries: [recent_insertions.capacity]HistoryEntry = @splat(.{}),
    count: usize = 0,
};

/// Stage 2's value: what the daemon's state *means*, before any wording. Private — nothing
/// outside this module reads it (ADR-0011: the interface narrowed to `Presentation` when the
/// menu stopped re-deciding). Its 30-odd tests below reach it as a same-file declaration.
const Decisions = struct {
    headline: Headline,
    icon_tier: IconTier,
    primary_action: PrimaryAction,
    show_openai_controls: bool,
    audio_stays_on_mac: bool,
    model_operation_uses_network: bool,
    model_actions: std.EnumSet(ModelAction),
    model_failure: ModelFailure,
    history: HistoryView,
    /// The Secure Event Input row's state (#245). Passed through rather than folded into the
    /// headline: the headline answers "can dictation fire", and this does not change that
    /// answer.
    secure_input: secure_input.State,

    pub fn allowsModelAction(self: Decisions, action: ModelAction) bool {
        return self.model_actions.contains(action);
    }
};

/// The derived dot colour + tag for one recorded outcome (spec §4).
fn historyDot(outcome: coord.InsertResult) HistoryDot {
    return switch (outcome) {
        .ok => .ok,
        .degraded => .degraded,
        // A refusal shares the red dot: the dot answers "did this text land", and it did not.
        // The tag below is what separates the two reasons.
        .failed, .refused => .failed,
    };
}
fn historyTag(outcome: coord.InsertResult) HistoryTag {
    return switch (outcome) {
        .ok => .none,
        .degraded => .degraded,
        .failed => .failed,
        .refused => .refused,
    };
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
            .undone = entry.undone,
            .withheld = entry.withheld,
        };
    }
    return view;
}

fn derive(s: Snapshot) Decisions {
    const operation_active = s.operation.isActive();
    const hl = headline(s);
    return .{
        .history = deriveHistory(s),
        .headline = hl,
        // The dim tier folds the readiness attention signal with the backend-failure
        // headline into one field, so the menu no longer re-ORs two modules' terms.
        .icon_tier = if (s.health.needsAttention() or hl == .backend_failure) .dimmed else .normal,
        .primary_action = primaryAction(s),
        .secure_input = s.secure_input,
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
    /// The Secure Input Observer's published state (#245), read off the daemon's atomic at
    /// snapshot time.
    secure_input: secure_input.State = .clear,
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
        .secure_input = r.secure_input,
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
        .refused => "  [refused]",
    };
}

/// The dimmed leading glyph for an undone row (#225): a hollow white circle replaces the
/// outcome dot so the entry visually reads as de-emphasized (a menu title carries no per-glyph
/// colour, so the "dim" rides the glyph, exactly as the outcome colour does). The trailing
/// `[undone]` marker keeps the state unmistakable — and the degraded/failed tag still shows.
fn historyLeadGlyph(entry: HistoryEntry) [:0]const u8 {
    // ⚪ (U+26AA) when undone, else the outcome dot.
    return if (entry.undone) "\xe2\x9a\xaa" else historyDotGlyph(entry.dot);
}
fn historyUndoneSuffix(entry: HistoryEntry) []const u8 {
    return if (entry.undone) "  [undone]" else "";
}

/// The withheld marker (#286). Its own suffix rather than a `HistoryTag` variant because the tag
/// answers *what happened to the Insertion* and this answers *whether its text was kept* — a
/// withheld row still carries its own `[failed]` or `[refused]` when it has one.
fn historySecureSuffix(entry: HistoryEntry) []const u8 {
    return if (entry.withheld) "  [secure input]" else "";
}

/// The body of a withheld row: what the `•` run and char count are replaced by. The run means
/// "text is here, masked", so showing it would promise a reveal that cannot happen.
const withheld_body = "not retained";

/// Assemble one history row: `<dot> <body> · <App> · <time>  [<tag>]  [undone]`, the shared
/// shape of the masked and revealed labels — only `body` differs (the `•` run + char count vs
/// the actual text). An undone entry (#225) leads with a dimmed glyph and trails with an
/// `[undone]` marker. Keeping the scaffolding single-homed means the row shape is edited in one
/// place. Returns a sentinel-terminated slice for `NSString`; `now_ms` is the caller's clock.
fn historyRowLabel(buf: []u8, entry: HistoryEntry, body: []const u8, now_ms: i64) [:0]const u8 {
    const dot = historyLeadGlyph(entry);
    const tag = historyTagSuffix(entry.tag);
    const secure = historySecureSuffix(entry);
    const undone = historyUndoneSuffix(entry);
    var when: [24]u8 = undefined;
    const ago = relativeTime(&when, now_ms - entry.timestamp);
    const mid = " \xc2\xb7 "; // " · " (U+00B7)
    if (entry.app) |app| {
        if (app.displayName().len > 0)
            return std.fmt.bufPrintSentinel(buf, "{s} {s}{s}{s}{s}{s}{s}{s}{s}", .{
                dot, body, mid, app.displayName(), mid, ago, tag, secure, undone,
            }, 0) catch dot;
    }
    return std.fmt.bufPrintSentinel(buf, "{s} {s}{s}{s}{s}{s}{s}", .{
        dot, body, mid, ago, tag, secure, undone,
    }, 0) catch dot;
}

/// Format one masked entry label — **metadata only, never the `inserted` text** (spec §4):
/// `<dot> <masked run> · <n> chars · <App> · <time>  [<tag>]`. The `•` run is a capped stand-in
/// for the hidden receipt, and `char_len` reports its length. Returns a sentinel-terminated
/// slice for `NSString`; `now_ms` is the caller's clock.
pub fn historyLabel(buf: []u8, entry: HistoryEntry, now_ms: i64) [:0]const u8 {
    // A withheld row (#286) has no receipt to stand in for and no length to report.
    if (entry.withheld) return historyRowLabel(buf, entry, withheld_body, now_ms);

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

// =====================================================================================
// The radio groups — the `config.zon` settings the Status Item edits. `model` / `language`
// / `delay` carry the #31-decided curated presets (exotic values stay hand-editable: a
// snapshot value matching no preset simply shows no checkmark in that group); the rest are
// the closed enums. The table lives here rather than in menu.zig because it *describes the
// Status Item* — the checkmark each group shows is presentation, decided by `settingsView`
// below. menu.zig still owns the write path and reads `field` / `zon` from here.
// =====================================================================================

pub const Opt = struct {
    label: [*:0]const u8,
    zon: []const u8, // the value text written into config.zon
};
pub const GroupDef = struct {
    title: [*:0]const u8,
    field: []const u8, // the config.zon field name
    session_shaped: bool,
    openai_only: bool = false,
    opts: []const Opt,
};

pub const groups = [_]GroupDef{
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

pub const group_count = groups.len;
pub const max_group_opts = blk: {
    var most: usize = 0;
    for (groups) |g| {
        if (g.opts.len > most) most = g.opts.len;
    }
    break :blk most;
};
pub const model_action_count = std.meta.fieldNames(ModelAction).len;

/// The typed twins of each group's `zon` text, in the same order as its `opts`. menu.zig's
/// write path indexes these to set the chosen field on a `Settings` under construction;
/// `settingsView` reads them back to decide which option is checked.
pub const talk_keys = [_]tapmod.TalkKey{ .right_option, .left_option, .globe };
pub const backends = [_]backend.Backend{ .openai, .local };
pub const languages = [_][]const u8{ "en", "sv", "" }; // "" = auto-detect (session omits the field)
// "minimal" earned its slot via the issue #36 benchmark: ~30-50ms faster to Final
// Transcript than "low" but measurably worse WER on quiet speech, so "low" stays the
// default and "minimal" is the one-click latency escape hatch ("xhigh" stays
// hand-edit-only). See docs/research/delay-tier-benchmark.md.
pub const delays = [_][]const u8{ "minimal", "low", "medium", "high" };
pub const noises = [_]config.Settings.NoiseReduction{ .near_field, .far_field, .off };
pub const insertions = [_]insertmod.Method{ .paste, .keystroke };

/// The scalar projection of the live Settings Snapshot that `present` words the settings-shaped
/// rows from. It exists because `config.Settings` holds **slices** (`model`, `language`,
/// `delay`, `vocabulary`), which no `std.meta.eql`-comparable value can carry: reducing them
/// to "which curated option is selected" and "how many terms" is what keeps the `Presentation`
/// comparable, and therefore what keeps the pump's apply-only-on-change early-out honest.
pub const SettingsView = struct {
    /// Which option of each group is selected — null when a hand-edited value matches no
    /// curated preset (that group then shows no checkmark).
    selected: [group_count]?u8 = @splat(null),
    /// Read from the settings side rather than the `Snapshot`, because the Backtrack
    /// disclosure line and the Vocabulary title have always tracked the live Settings.
    selected_backend: backend.Backend = .openai,
    backtrack: bool = false,
    overlay: bool = true,
    vocabulary_count: usize = 0,
};

/// Project the live Settings Snapshot to its scalar view. The per-group search is the one
/// place that knows a hand-edited value can match no preset; group 2 (`model`) has a single
/// curated option, so it matches by string rather than by index.
pub fn settingsView(s: *const config.Settings) SettingsView {
    var view = SettingsView{
        .selected_backend = s.transcription_backend,
        .backtrack = s.backtrack,
        .overlay = s.overlay,
        .vocabulary_count = s.vocabulary.len,
    };
    for (0..group_count) |gi| view.selected[gi] = currentOption(s, gi);
    return view;
}

fn currentOption(s: *const config.Settings, gi: usize) ?u8 {
    switch (gi) {
        0 => for (backends, 0..) |b, i| {
            if (s.transcription_backend == b) return @intCast(i);
        },
        1 => for (talk_keys, 0..) |k, i| {
            if (s.talk_key == k) return @intCast(i);
        },
        2 => if (std.mem.eql(u8, s.model, "gpt-realtime-whisper")) return 0,
        3 => for (languages, 0..) |l, i| {
            if (std.mem.eql(u8, s.language, l)) return @intCast(i);
        },
        4 => for (delays, 0..) |d, i| {
            if (std.mem.eql(u8, s.delay, d)) return @intCast(i);
        },
        5 => for (noises, 0..) |n, i| {
            if (s.noise_reduction == n) return @intCast(i);
        },
        6 => for (insertions, 0..) |m, i| {
            if (s.insertion == m) return @intCast(i);
        },
        else => unreachable,
    }
    return null;
}

// =====================================================================================
// The wording. Every string the Status Item shows is decided here — the menu used to
// re-branch several of these on raw `Snapshot` axes, which is what ADR-0011 closes.
// =====================================================================================

fn statusText(hl: Headline, selected: backend.Backend) []const u8 {
    return switch (hl) {
        .paused => "type-wave — Paused",
        .ready => "type-wave — OpenAI ready", // `.ready` is OpenAI-only; local yields `.ready_offline`
        .ready_offline => "type-wave — Ready offline",
        .preparing => if (selected == .openai) "type-wave — Reconnecting\xe2\x80\xa6" else "type-wave — Preparing local backend\xe2\x80\xa6",
        .selected_backend_prerequisite_missing => if (selected == .openai) "type-wave — No OpenAI API key" else "type-wave — No local Model Installation",
        .backend_failure => if (selected == .openai) "type-wave — OpenAI unavailable" else "type-wave — Local backend unavailable",
        .microphone_needed => "type-wave — Microphone needed",
        .input_monitoring_needed => "type-wave — Input Monitoring needed",
        .accessibility_needed => "type-wave — Accessibility needed",
    };
}

fn primaryText(action: PrimaryAction, operation: Operation) []const u8 {
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

/// The Secure Event Input row's wording (#245), one string per published state. The two held
/// states are worded apart because the remedy is: a live holder can be quit, while a hold
/// whose holder is gone can only be cleared by logging out. Both say what is actually lost —
/// dictation is unaffected, the recovery chord is not. `.clear` hides the row, so its string
/// is never shown; it exists so this stays a total switch.
fn secureInputText(state: secure_input.State) []const u8 {
    return switch (state) {
        .clear => "",
        .held => "Secure Input on \xe2\x80\x94 undo (\xe2\x8c\x83\xe2\x8c\x98\xe2\x8c\xab) unavailable",
        .stuck => "Secure Input stuck on \xe2\x80\x94 undo (\xe2\x8c\x83\xe2\x8c\x98\xe2\x8c\xab) needs a log out",
    };
}

/// Disclosure line 2 beneath the Backtrack toggle. On the Local backend with Backtrack
/// on it sharpens to the "enabled but not applying" status — the toggle stays checked so
/// it can be pre-enabled for the switch to OpenAI (docs/backtrack-spec.md §Settings & UX);
/// otherwise it states the cloud/network reality, shown identically whether on or off.
fn backtrackLine2(selected: backend.Backend, backtrack: bool) []const u8 {
    if (selected == .local and backtrack)
        return "Not applying \xe2\x80\x94 needs the OpenAI backend";
    return "Needs internet; unavailable on the Local backend";
}

fn installationText(inst: Installation) []const u8 {
    return switch (inst) {
        .absent => "Whisper Large v3 Turbo — not installed",
        .ready => "Whisper Large v3 Turbo — installed",
        .update_available => "Whisper Large v3 Turbo — update available",
        .corrupt => "Whisper Large v3 Turbo — corrupt",
    };
}

/// The actionable recovery named on the Failure row beside a reported detail.
fn recoveryText(failure: ModelFailure) []const u8 {
    return switch (failure) {
        .none => "",
        .installation_corrupt => "Repair or Remove",
        .runtime_unavailable => "Retry or Open diagnostics",
        .operation_failed => "Retry or Open diagnostics",
        .operation_cancelled => "Retry if still needed",
    };
}

/// The Failure row when no detail was reported — the failure kind alone has to carry both
/// what went wrong and what to do about it.
fn failureFallbackText(failure: ModelFailure) []const u8 {
    return switch (failure) {
        .none => "",
        .installation_corrupt => "Failure — Model Installation corrupt; Repair or Remove",
        .runtime_unavailable => "Failure — Local runtime unavailable; Retry or Open diagnostics",
        .operation_failed => "Failure — Model Operation failed; Retry or Open diagnostics",
        .operation_cancelled => "Model Operation cancelled; Retry if still needed",
    };
}

/// The Vocabulary menu-item title from the live term count and the active backend. Local:
/// `Vocabulary (off)` / `Vocabulary (3 terms)…`. OpenAI: the same with a ` — local only`
/// suffix that replaces the disclosure ellipsis — the list is editable but inert there
/// until you switch to Local (spec §4). Static fallback on the (unreachable) format overflow.
const local_only_suffix = " \xe2\x80\x94 local only";
const dialog_ellipsis = "\xe2\x80\xa6";
fn vocabularyText(buf: []u8, count: usize, selected: backend.Backend) []const u8 {
    if (count == 0)
        return std.fmt.bufPrint(buf, "Vocabulary (off){s}", .{
            if (selected == .openai) local_only_suffix else "",
        }) catch "Vocabulary";
    const unit = if (count == 1) "term" else "terms";
    const tail = if (selected == .openai) local_only_suffix else dialog_ellipsis;
    return std.fmt.bufPrint(buf, "Vocabulary ({d} {s}){s}", .{ count, unit, tail }) catch "Vocabulary";
}

/// The Recent Insertions parent row: an empty ring reads as a disabled row with no arrow,
/// because there is nothing to open (spec §4).
fn historyParentText(empty: bool) []const u8 {
    return if (empty) "No recent insertions" else "Recent Insertions";
}

/// The in-submenu reveal affordance, mirroring the row's toggle state (spec §4). A row with no
/// text behind it (#286) gets the reason in place of the affordance: the item is disabled either
/// way, and a disabled "Reveal text" would leave the user guessing which of the two it means.
pub fn revealItemTitle(revealed: bool, text_available: bool) [:0]const u8 {
    if (!text_available) return "No text retained — spoken under Secure Event Input";
    return if (revealed) "Hide text" else "Reveal text";
}

// =====================================================================================
// The Status Item Chrome seam — one method, `apply(Presentation)`.
// =====================================================================================

/// The longest row title the Status Item can show. The widest producer is the Failure row
/// (a 256-byte reported detail plus its recovery phrase).
pub const max_title = 512;

/// One menu row's complete description: the finished title bytes plus the three flags AppKit
/// needs. Fixed-size and zero-tailed by construction — every byte past `len` is 0 — so equal
/// titles compare equal under `std.meta.eql` and `title()` hands `NSString` its sentinel
/// without a copy.
pub const Row = struct {
    bytes: [max_title]u8 = @splat(0),
    len: u16 = 0,
    hidden: bool = false,
    enabled: bool = true,
    checked: bool = false,

    /// The NUL-terminated title, for `stringWithUTF8String:`.
    pub fn title(self: *const Row) [*:0]const u8 {
        return @ptrCast(&self.bytes);
    }

    /// The title as a plain slice, for assertions.
    pub fn text(self: *const Row) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn setText(row: *Row, value: []const u8) void {
    const n = @min(value.len, max_title - 1);
    @memcpy(row.bytes[0..n], value[0..n]);
    @memset(row.bytes[n..], 0); // keep the zero tail total, not merely inherited from the reset
    row.len = @intCast(n);
}

fn setFmt(row: *Row, comptime fmt: []const u8, args: anytype, fallback: []const u8) void {
    const printed = std.fmt.bufPrint(row.bytes[0 .. max_title - 1], fmt, args) catch {
        setText(row, fallback);
        return;
    };
    row.len = @intCast(printed.len);
    @memset(row.bytes[row.len..], 0);
}

/// Ephemeral per-entry reveal state for the Recent Insertions submenu (spec §4): which entries
/// the user has ⌥-clicked (or picked "Reveal text" for) to show inline. Keyed by the entry's
/// capture `timestamp` — stable across menu reopens and safe under ring shift (an evicted
/// entry's stamp simply stops matching), unlike the newest-first index, which slides as new
/// Insertions arrive. Holds **no transcript text** — reveal only flips a flag; the bytes are
/// fetched on demand by the adapter. At most `capacity` entries can be live at once.
///
/// The type lives here so `present` can take it as a typed input; the *instance* stays with the
/// adapter, which owns it as menu-session state and toggles it on the ⌥-click (ADR-0011).
pub const RevealSet = struct {
    stamps: [recent_insertions.capacity]i64 = @splat(0),
    len: usize = 0,

    pub fn contains(self: *const RevealSet, ts: i64) bool {
        for (self.stamps[0..self.len]) |s| {
            if (s == ts) return true;
        }
        return false;
    }

    /// Add `ts` if absent, remove it if present — the ⌥-click toggle. A full set (all
    /// `capacity` slots taken) silently ignores a new add; every real ring has ≤ capacity
    /// distinct stamps, so this only guards the degenerate case.
    pub fn toggle(self: *RevealSet, ts: i64) void {
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

/// One Recent Insertions row — **structural only**. The label is not here: the adapter formats
/// it with `historyLabel` / `historyRevealedLabel`, fetching the `inserted` bytes on demand from
/// the authoritative ring for a revealed row. That is what keeps transcript text out of a
/// projected value (spec §4.1), and it is why this row carries `revealed` rather than bytes.
pub const HistoryRow = struct {
    entry: HistoryEntry = .{},
    revealed: bool = false,
    hidden: bool = true,
    /// Whether this row has transcript bytes behind it at all. False only for a withheld record
    /// (#286): reveal, Copy and Re-insert are then shown **disabled**, so the row explains
    /// itself rather than offering actions that would find nothing. The ring returning zero
    /// bytes for such a stamp is the floor under this, not the gate — the gate is here, in the
    /// Presentation, where it is tested.
    text_available: bool = true,
};

pub const History = struct {
    parent: Row = .{},
    empty: bool = true,
    rows: [recent_insertions.capacity]HistoryRow = @splat(.{}),
    count: usize = 0,
};

/// The complete, comparable description of everything the Status Item shows this tick — the
/// value that crosses the Status Item Chrome seam. Every title is finished bytes and every
/// visibility/enablement/checkmark is an explicit flag, so `AppKitChrome.apply` is a straight
/// run of `setTitle:` / `setHidden:` / `setEnabled:` / `setState:` with no branch of its own.
///
/// `primary_action` and each history row's `entry.timestamp` ride along so a **click routes off
/// the Presentation that was displayed** (ADR-0011) rather than re-deriving from a fresh read.
pub const Presentation = struct {
    /// The needs-attention icon tier. How dim is the Chrome's business; whether, is this value's.
    dimmed: bool = false,
    /// The text glyph shown when this macOS has no SF Symbols.
    icon_fallback: Row = .{},
    status_line: Row = .{},
    primary: Row = .{},
    /// What a click on the primary row means. `.none` while the row is hidden.
    primary_action: PrimaryAction = .none,
    privacy: Row = .{},
    network: Row = .{},
    secure_input: Row = .{},
    set_api_key: Row = .{},
    pause: Row = .{},
    /// The live pause state, so the Pause row's click can flip it without a fresh status read.
    paused: bool = false,
    overlay: Row = .{},
    vocabulary: Row = .{},
    backtrack: Row = .{},
    backtrack_backend: Row = .{},
    installation: Row = .{},
    identity_source: Row = .{},
    identity_artifact: Row = .{},
    identity_runtime: Row = .{},
    identity_installer: Row = .{},
    operation: Row = .{},
    failure: Row = .{},
    /// Per radio group: the `openai_only` groups hide with the OpenAI controls.
    group_hidden: [group_count]bool = @splat(false),
    /// Per radio group, per option: the checkmark. All false for a group whose hand-edited
    /// value matches no curated preset.
    group_checked: [group_count][max_group_opts]bool = @splat(@splat(false)),
    /// Indexed by `@intFromEnum(ModelAction)`.
    model_action_hidden: [model_action_count]bool = @splat(true),
    history: History = .{},
};

/// Stage 3: word the Snapshot, using stage 2's decisions and the scalar settings view. Fills
/// `out` rather than returning by value — the Presentation carries every row's bytes, so it is
/// a large-ish value and the pump keeps one live copy for its early-out.
pub fn present(out: *Presentation, s: Snapshot, sv: SettingsView, reveal: RevealSet) void {
    out.* = .{};
    const d = derive(s);

    out.dimmed = d.icon_tier == .dimmed;
    setText(&out.icon_fallback, if (out.dimmed) "tw!" else "tw");
    setText(&out.status_line, statusText(d.headline, s.selected_backend));

    setText(&out.pause, if (s.health.paused) "Resume dictation" else "Pause dictation");
    out.paused = s.health.paused;

    for (groups, 0..) |group, gi| {
        if (group.openai_only) out.group_hidden[gi] = !d.show_openai_controls;
        if (sv.selected[gi]) |oi| {
            if (oi < max_group_opts) out.group_checked[gi][oi] = true;
        }
    }
    out.set_api_key.hidden = !d.show_openai_controls;

    out.primary_action = d.primary_action;
    if (d.primary_action == .operation_progress and s.operation_bytes != null) {
        const bytes = s.operation_bytes.?;
        setFmt(&out.primary, "{s} — {d}/{d} bytes", .{
            primaryText(d.primary_action, s.operation), bytes.completed, bytes.total,
        }, primaryText(d.primary_action, s.operation));
    } else {
        setText(&out.primary, primaryText(d.primary_action, s.operation));
    }
    out.primary.hidden = d.primary_action == .none;
    out.primary.enabled = d.primary_action != .operation_progress;

    out.privacy.hidden = !d.audio_stays_on_mac;
    out.network.hidden = !d.model_operation_uses_network;
    setText(&out.secure_input, secureInputText(d.secure_input));
    out.secure_input.hidden = d.secure_input == .clear;

    out.overlay.checked = sv.overlay;
    out.backtrack.checked = sv.backtrack;
    setText(&out.backtrack_backend, backtrackLine2(sv.selected_backend, sv.backtrack));
    var vocab_buf: [max_title]u8 = undefined;
    setText(&out.vocabulary, vocabularyText(&vocab_buf, sv.vocabulary_count, sv.selected_backend));

    setText(&out.installation, installationText(s.installation));
    const identity_hidden = s.installation_identity == null;
    for ([_]*Row{ &out.identity_source, &out.identity_artifact, &out.identity_runtime, &out.identity_installer }) |row|
        row.hidden = identity_hidden;
    if (s.installation_identity) |identity| {
        setFmt(&out.identity_source, "Repository — {s}@{s} — installation {s}", .{
            identity.repository.value(),
            identity.revision.value(),
            if (identity.installation_id) |installation_id| installation_id.value() else "legacy",
        }, "Repository identity unavailable");
        setFmt(&out.identity_artifact, "Artifact — {s} — {d} bytes — sha256 {s}", .{
            identity.artifact.value(),
            identity.artifact_size,
            &std.fmt.bytesToHex(identity.artifact_sha256, .lower),
        }, "Artifact identity unavailable");
        setFmt(&out.identity_runtime, "Runtime — {s} — sha256 {s}", .{
            identity.runtime.value(),
            &std.fmt.bytesToHex(identity.runtime_sha256, .lower),
        }, "Runtime identity unavailable");
        setFmt(&out.identity_installer, "Installed by — {s}", .{identity.installed_by.value()}, "Installer identity unavailable");
    }

    // The raw tag is the user-visible operation word, as it has been since the Model Operation
    // rows landed; ADR-0011 moved the decision here without rewording it.
    if (s.operation_bytes) |bytes| {
        setFmt(&out.operation, "Model Operation — {s} — {d}/{d} bytes", .{ @tagName(s.operation), bytes.completed, bytes.total }, "Model Operation");
    } else {
        setFmt(&out.operation, "Model Operation — {s}", .{@tagName(s.operation)}, "Model Operation");
    }

    if (s.failure_detail) |detail| {
        setFmt(&out.failure, "Failure — {s} — {s}", .{ detail.value(), recoveryText(d.model_failure) }, "Failure — Open diagnostics");
    } else {
        setText(&out.failure, failureFallbackText(d.model_failure));
    }
    out.failure.hidden = d.model_failure == .none;

    for (0..model_action_count) |i|
        out.model_action_hidden[i] = !d.model_actions.contains(@enumFromInt(i));

    presentHistory(&out.history, d.history, reveal);
}

fn presentHistory(out: *History, view: HistoryView, reveal: RevealSet) void {
    out.empty = view.count == 0;
    out.count = view.count;
    setText(&out.parent, historyParentText(out.empty));
    out.parent.enabled = !out.empty;
    for (view.entries[0..view.count], 0..) |entry, i| {
        out.rows[i] = .{
            .entry = entry,
            // A withheld row can never be revealed, whatever the RevealSet holds — a stale
            // toggle on its stamp (or one aimed at an evicted entry that reused it) must not
            // put an empty body where the reason belongs.
            .revealed = !entry.withheld and reveal.contains(entry.timestamp),
            .hidden = false,
            .text_available = !entry.withheld,
        };
    }
}

/// The Status Item Chrome seam's contract, invoked by `StatusItem(Chrome)` itself — as
/// `hud.assertChrome` is by `Hud(Chrome)`, and unlike `local_backend.assertHelper` /
/// `session.assertTransport`, which the generic types they protect never call.
pub fn assertChrome(comptime Chrome: type) void {
    if (!@hasDecl(Chrome, "apply"))
        @compileError("type '" ++ @typeName(Chrome) ++ "' is not a Status Item Chrome: missing method 'apply'");
}

/// The Status Item's **pump**: it composes one `Presentation` per refresh and applies it
/// across the Chrome seam, holding nothing but the last one applied. The cadence stays with
/// the adapter (a `CFRunLoopTimer`, main-thread by necessity) exactly as the HUD's does —
/// the adapter calls in, the pump composes, the Chrome draws.
///
/// The early-out compares the **Presentation**, not the `Snapshot` it came from, so two
/// different Snapshots that read identically cost one apply rather than two.
pub fn StatusItem(comptime Chrome: type) type {
    assertChrome(Chrome);
    return struct {
        const Self = @This();

        chrome: *Chrome,
        last: ?Presentation = null,

        pub fn init(chrome: *Chrome) Self {
            return .{ .chrome = chrome };
        }

        /// Compose and apply. Returns true when the Presentation changed and was applied.
        pub fn refresh(self: *Self, s: Snapshot, sv: SettingsView, reveal: RevealSet) bool {
            var next: Presentation = undefined;
            present(&next, s, sv, reveal);
            if (self.last) |*last| {
                if (std.meta.eql(last.*, next)) return false;
            }
            self.last = next;
            self.chrome.apply(&self.last.?);
            return true;
        }

        /// Drop the early-out so the next `refresh` applies unconditionally — used when
        /// something outside the Presentation went stale (relative times on menu open).
        pub fn invalidate(self: *Self) void {
            self.last = null;
        }

        /// The Presentation currently on screen, or null before the first apply. Click
        /// routing reads this: what the user clicked is what they saw (ADR-0011).
        pub fn displayed(self: *const Self) ?*const Presentation {
            return if (self.last) |*p| p else null;
        }
    };
}

fn snap(fields: struct {
    selected_backend: backend.Backend = .local,
    health: readiness.Health = .{ .paused = false, .status = .ready_offline },
    terminal_backend_failure: bool = false,
    local_runtime_failure: bool = false,
    installation: Installation = .ready,
    operation: Operation = .idle,
    operation_bytes: ?ByteProgress = null,
    installation_identity: ?InstallationIdentity = null,
    failure_detail: ?FailureDetail = null,
    secure_input: secure_input.State = .clear,
}) Snapshot {
    return .{
        .selected_backend = fields.selected_backend,
        .health = fields.health,
        .terminal_backend_failure = fields.terminal_backend_failure,
        .local_runtime_failure = fields.local_runtime_failure,
        .installation = fields.installation,
        .operation = fields.operation,
        .operation_bytes = fields.operation_bytes,
        .installation_identity = fields.installation_identity,
        .failure_detail = fields.failure_detail,
        .secure_input = fields.secure_input,
    };
}

test "a held Secure Event Input reaches the menu without changing the headline or the icon (#245)" {
    // It is surfaced, not folded into readiness: dictation is unaffected — the Talk Key rides
    // on modifier events, which keep flowing — so dimming the icon would say something false.
    const ready = derive(snap(.{ .health = .{ .paused = false, .status = .ready } }));
    const held = derive(snap(.{
        .health = .{ .paused = false, .status = .ready },
        .secure_input = .held,
    }));

    try std.testing.expectEqual(secure_input.State.held, held.secure_input);
    try std.testing.expectEqual(ready.headline, held.headline);
    try std.testing.expectEqual(ready.icon_tier, held.icon_tier);
    try std.testing.expectEqual(ready.primary_action, held.primary_action);
}

test "a stale hold is carried through distinctly — the remedy differs (#245)" {
    const p = derive(snap(.{ .secure_input = .stuck }));
    try std.testing.expectEqual(secure_input.State.stuck, p.secure_input);
}

test "no hold means no row" {
    try std.testing.expectEqual(secure_input.State.clear, derive(snap(.{})).secure_input);
}

test "project carries the observed hold from the daemon's readings to the snapshot" {
    const s = project(.{
        .selected_backend = .local,
        .health = .{ .paused = false, .status = .ready_offline },
        .secure_input = .stuck,
    });
    try std.testing.expectEqual(secure_input.State.stuck, s.secure_input);
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

test "historyEntryView carries the record's undone flag into the masked view (#225)" {
    var rec = record("undone one ", .ok, null);
    try std.testing.expect(!historyEntryView(&rec).undone); // default: not undone
    rec.undone = true;
    try std.testing.expect(historyEntryView(&rec).undone);
}

test "historyEntryView publishes no length for a withheld record (#286)" {
    // A withheld record stores no bytes, so there is nothing to count — and nothing to publish
    // either: the one row whose content is presumed a secret does not report its length.
    var rec = record("", .ok, coord.AppIdentity.init("com.apple.Terminal", "Terminal"));
    rec.withheld = true;
    const view = historyEntryView(&rec);
    try std.testing.expect(view.withheld);
    try std.testing.expectEqual(@as(u16, 0), view.char_len);
    // The rest of the metadata still crosses: the row is a real row.
    try std.testing.expectEqualStrings("Terminal", view.app.?.displayName());
    try std.testing.expectEqual(@as(i64, 1000), view.timestamp);
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

test "a refused Insertion reads as never-landed, but not as a failure" {
    // Both mean nothing reached the cursor, so both take the red dot; only the tag separates
    // them, because the recovery differs — a refused transcript re-inserts cleanly once the
    // intended app is frontmost again, where a failed one hit a broken mechanism.
    const s = history(&.{.{ .char_len = 9, .outcome = .refused, .timestamp = 30 }});
    const h = derive(s).history;
    try std.testing.expectEqual(HistoryDot.failed, h.entries[0].dot);
    try std.testing.expectEqual(HistoryTag.refused, h.entries[0].tag);

    var buf: [512]u8 = undefined;
    const label = historyRowLabel(&buf, h.entries[0], "•••••••••", 30);
    try std.testing.expect(std.mem.indexOf(u8, label, "[refused]") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[failed]") == null);
}

test "derive carries the undone flag through to the rendered entry (#225)" {
    const s = history(&.{
        .{ .char_len = 3, .outcome = .ok, .timestamp = 30, .undone = true },
        .{ .char_len = 2, .outcome = .ok, .timestamp = 20, .undone = false },
    });
    const h = derive(s).history;
    try std.testing.expect(h.entries[0].undone);
    try std.testing.expect(!h.entries[1].undone);
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

test "historyLabel renders an undone entry dimmed: white circle glyph + [undone] marker (#225)" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .ok, .tag = .none, .char_len = 4, .app = null, .timestamp = 0, .undone = true };
    const label = historyLabel(&buf, entry, 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "\xe2\x9a\xaa") != null); // ⚪ dimmed lead glyph
    try std.testing.expect(std.mem.indexOf(u8, label, "\xf0\x9f\x9f\xa2") == null); // 🟢 ok dot suppressed
    try std.testing.expect(std.mem.indexOf(u8, label, "[undone]") != null);
}

test "historyLabel leaves a live (non-undone) entry with its outcome dot and no marker (#225)" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .ok, .tag = .none, .char_len = 4, .app = null, .timestamp = 0, .undone = false };
    const label = historyLabel(&buf, entry, 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "\xf0\x9f\x9f\xa2") != null); // 🟢 ok dot present
    try std.testing.expect(std.mem.indexOf(u8, label, "\xe2\x9a\xaa") == null); // no dimmed glyph
    try std.testing.expect(std.mem.indexOf(u8, label, "[undone]") == null);
}

test "historyLabel keeps the degraded tag alongside the undone marker (#225)" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .degraded, .tag = .degraded, .char_len = 4, .app = null, .timestamp = 0, .undone = true };
    const label = historyLabel(&buf, entry, 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "[degraded]") != null); // outcome still surfaced
    try std.testing.expect(std.mem.indexOf(u8, label, "[undone]") != null);
}

test "historyRevealedLabel also dims an undone entry (#225)" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .ok, .tag = .none, .char_len = 6, .app = null, .timestamp = 0, .undone = true };
    const label = historyRevealedLabel(&buf, entry, "hello ", 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "hello") != null); // the redo text still shows
    try std.testing.expect(std.mem.indexOf(u8, label, "\xe2\x9a\xaa") != null); // ⚪ dimmed lead glyph
    try std.testing.expect(std.mem.indexOf(u8, label, "[undone]") != null);
}

test "historyLabel renders a withheld row as 'not retained' with no run and no count (#286)" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{
        .dot = .ok,
        .tag = .none,
        .char_len = 0,
        .app = coord.AppIdentity.init("com.apple.Terminal", "Terminal"),
        .timestamp = 0,
        .withheld = true,
    };
    const label = historyLabel(&buf, entry, 120_000);
    try std.testing.expect(std.mem.indexOf(u8, label, "not retained") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[secure input]") != null);
    // No masked run: it means "text is here, masked", and would promise a reveal that cannot
    // happen. No count either — not even the "0 chars" the count would have rendered.
    try std.testing.expect(std.mem.indexOf(u8, label, "\xe2\x80\xa2") == null);
    try std.testing.expect(std.mem.indexOf(u8, label, "chars") == null);
    // Still a full row otherwise: where it went, and when.
    try std.testing.expect(std.mem.indexOf(u8, label, "Terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "2m ago") != null);
}

test "a withheld row keeps its own outcome tag and undone marker (#286)" {
    // Withholding answers *was the text kept*; the tag answers *what happened to the Insertion*.
    // Both are true at once, so both show.
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{
        .dot = .failed,
        .tag = .refused,
        .char_len = 0,
        .app = null,
        .timestamp = 0,
        .undone = true,
        .withheld = true,
    };
    const label = historyLabel(&buf, entry, 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "not retained") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[refused]") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[secure input]") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "[undone]") != null);
}

test "an ordinary row carries no withheld marker" {
    var buf: [256]u8 = undefined;
    const entry = HistoryEntry{ .dot = .ok, .tag = .none, .char_len = 4, .app = null, .timestamp = 0 };
    const label = historyLabel(&buf, entry, 0);
    try std.testing.expect(std.mem.indexOf(u8, label, "[secure input]") == null);
    try std.testing.expect(std.mem.indexOf(u8, label, "not retained") == null);
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

// =====================================================================================
// The Status Item Chrome seam (ADR-0011). These are the tests that make the Presentation's
// wording assertable: every title the menu used to build inside `refreshChrome`, where no
// test could reach it, is pinned here as an exact string.
// =====================================================================================

fn settingsFor(fields: struct {
    selected: [group_count]?u8 = @splat(null),
    selected_backend: backend.Backend = .local,
    backtrack: bool = false,
    overlay: bool = true,
    vocabulary_count: usize = 0,
}) SettingsView {
    return .{
        .selected = fields.selected,
        .selected_backend = fields.selected_backend,
        .backtrack = fields.backtrack,
        .overlay = fields.overlay,
        .vocabulary_count = fields.vocabulary_count,
    };
}

fn presented(s: Snapshot, sv: SettingsView) Presentation {
    var p: Presentation = undefined;
    present(&p, s, sv, .{});
    return p;
}

fn fixtureIdentity() InstallationIdentity {
    return .{
        .repository = installation_identity.Text.init("ggerganov/whisper.cpp") catch unreachable,
        .revision = installation_identity.Text.init("98aa99a0") catch unreachable,
        .runtime = installation_identity.Text.init("whisper-cli") catch unreachable,
        .runtime_sha256 = @splat(0xab),
        .artifact = installation_identity.Text.init("ggml-large-v3-turbo.bin") catch unreachable,
        .installation_id = installation_identity.Text.init("inst-7") catch unreachable,
        .artifact_size = 1_624_555_275,
        .artifact_sha256 = @splat(0xcd),
        .installed_by = installation_identity.Text.init("type-wave 0.3.2") catch unreachable,
    };
}

test "the status line words every headline, re-splitting only where the backend changes it" {
    // `derive` collapses OpenAI and Local into one Headline; three of the nine arms have to
    // split them back apart, and that split is the reason this wording belongs here rather
    // than in the adapter (ADR-0011).
    const openai = settingsFor(.{ .selected_backend = .openai });
    const local = settingsFor(.{});

    try std.testing.expectEqualStrings("type-wave — Paused", presented(snap(.{ .health = .{ .paused = true, .status = .ready_offline } }), local).status_line.text());
    try std.testing.expectEqualStrings("type-wave — Ready offline", presented(snap(.{}), local).status_line.text());
    try std.testing.expectEqualStrings("type-wave — OpenAI ready", presented(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
    }), openai).status_line.text());
    try std.testing.expectEqualStrings("type-wave — Microphone needed", presented(snap(.{
        .health = .{ .paused = false, .status = .microphone_needed },
        .installation = .absent,
    }), local).status_line.text());
    try std.testing.expectEqualStrings("type-wave — Input Monitoring needed", presented(snap(.{
        .health = .{ .paused = false, .status = .input_monitoring_needed },
        .installation = .absent,
    }), local).status_line.text());
    try std.testing.expectEqualStrings("type-wave — Accessibility needed", presented(snap(.{
        .health = .{ .paused = false, .status = .accessibility_needed },
        .installation = .absent,
    }), local).status_line.text());

    // The three backend-split arms.
    try std.testing.expectEqualStrings("type-wave — Reconnecting\xe2\x80\xa6", presented(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .reconnecting },
    }), openai).status_line.text());
    try std.testing.expectEqualStrings("type-wave — Preparing local backend\xe2\x80\xa6", presented(snap(.{
        .health = .{ .paused = false, .status = .preparing_local },
    }), local).status_line.text());
    try std.testing.expectEqualStrings("type-wave — No OpenAI API key", presented(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .no_key },
    }), openai).status_line.text());
    try std.testing.expectEqualStrings("type-wave — No local Model Installation", presented(snap(.{
        .health = .{ .paused = false, .status = .no_local_installation },
        .installation = .absent,
    }), local).status_line.text());
    try std.testing.expectEqualStrings("type-wave — OpenAI unavailable", presented(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
        .terminal_backend_failure = true,
    }), openai).status_line.text());
    try std.testing.expectEqualStrings("type-wave — Local backend unavailable", presented(snap(.{ .terminal_backend_failure = true }), local).status_line.text());
}

test "the icon's dim tier and its no-SF-Symbols fallback glyph agree" {
    const dim = presented(snap(.{ .health = .{ .paused = true, .status = .ready_offline } }), settingsFor(.{}));
    try std.testing.expect(dim.dimmed);
    try std.testing.expectEqualStrings("tw!", dim.icon_fallback.text());

    const normal = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expect(!normal.dimmed);
    try std.testing.expectEqualStrings("tw", normal.icon_fallback.text());
}

test "the pause row's title and its click state are the same fact" {
    const running = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expectEqualStrings("Pause dictation", running.pause.text());
    try std.testing.expect(!running.paused);

    const paused = presented(snap(.{ .health = .{ .paused = true, .status = .ready_offline } }), settingsFor(.{}));
    try std.testing.expectEqualStrings("Resume dictation", paused.pause.text());
    try std.testing.expect(paused.paused); // what `onPause:` flips, without re-reading status
}

test "the primary row carries its title, its visibility, and the action a click fires" {
    const hidden = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expectEqual(PrimaryAction.none, hidden.primary_action);
    try std.testing.expect(hidden.primary.hidden);
    try std.testing.expectEqualStrings("", hidden.primary.text());

    const install = presented(snap(.{
        .health = .{ .paused = false, .status = .no_local_installation },
        .installation = .absent,
    }), settingsFor(.{}));
    try std.testing.expectEqual(PrimaryAction.install_local_model, install.primary_action);
    try std.testing.expectEqualStrings("Install Whisper Large v3 Turbo\xe2\x80\xa6", install.primary.text());
    try std.testing.expect(!install.primary.hidden);
    try std.testing.expect(install.primary.enabled);

    try std.testing.expectEqualStrings("Set OpenAI API key\xe2\x80\xa6", presented(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .no_key },
    }), settingsFor(.{ .selected_backend = .openai })).primary.text());
    try std.testing.expectEqualStrings("Local model update available\xe2\x80\xa6", presented(snap(.{ .installation = .update_available }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Repair local model\xe2\x80\xa6", presented(snap(.{ .installation = .corrupt }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Retry local runtime", presented(snap(.{ .terminal_backend_failure = true }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Resume Model Operation", presented(snap(.{ .operation = .paused }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Retry Model Operation", presented(snap(.{ .operation = .failed }), settingsFor(.{})).primary.text());
}

test "an in-progress Model Operation names its stage, shows bytes, and cannot be clicked" {
    const p = presented(snap(.{ .operation = .installing, .operation_bytes = .{ .completed = 3, .total = 9 } }), settingsFor(.{}));
    try std.testing.expectEqualStrings("Installing Whisper Large v3 Turbo\xe2\x80\xa6 — 3/9 bytes", p.primary.text());
    try std.testing.expect(!p.primary.hidden);
    try std.testing.expect(!p.primary.enabled); // progress is a status line, not an action

    // Without byte progress the stage name stands alone.
    try std.testing.expectEqualStrings("Verifying Model Installation\xe2\x80\xa6", presented(snap(.{ .operation = .verifying }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Waiting for local inference to drain\xe2\x80\xa6", presented(snap(.{ .operation = .waiting_for_inference }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Activating Model Installation\xe2\x80\xa6", presented(snap(.{ .operation = .activating }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Removing Model Installation\xe2\x80\xa6", presented(snap(.{ .operation = .removing }), settingsFor(.{})).primary.text());
    try std.testing.expectEqualStrings("Discarding staged model data\xe2\x80\xa6", presented(snap(.{ .operation = .discarding }), settingsFor(.{})).primary.text());
}

test "the OpenAI-only rows hide together with the OpenAI controls" {
    const local = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expect(local.set_api_key.hidden);
    for (groups, 0..) |g, gi|
        try std.testing.expectEqual(g.openai_only, local.group_hidden[gi]);

    const openai = presented(snap(.{
        .selected_backend = .openai,
        .health = .{ .paused = false, .status = .ready },
    }), settingsFor(.{ .selected_backend = .openai }));
    try std.testing.expect(!openai.set_api_key.hidden);
    for (0..group_count) |gi| try std.testing.expect(!openai.group_hidden[gi]);
}

test "the privacy and network disclosure rows follow the selected backend and the operation" {
    const offline = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expect(!offline.privacy.hidden); // "Audio stays on this Mac"
    try std.testing.expect(offline.network.hidden);

    const downloading = presented(snap(.{ .operation = .installing }), settingsFor(.{}));
    try std.testing.expect(!downloading.network.hidden); // network used for this operation only
}

test "the Secure Event Input row names what is lost, and only the stuck case asks for a log out" {
    // The row's whole job is to correct the impression the rest of the menu gives: dictation
    // is fine, so the wording has to say which half is actually gone (#245).
    const held = presented(snap(.{ .secure_input = .held }), settingsFor(.{}));
    try std.testing.expect(!held.secure_input.hidden);
    try std.testing.expect(std.mem.indexOf(u8, held.secure_input.text(), "undo") != null);
    try std.testing.expect(std.mem.indexOf(u8, held.secure_input.text(), "log out") == null); // the holder can be quit

    const stuck = presented(snap(.{ .secure_input = .stuck }), settingsFor(.{}));
    try std.testing.expect(std.mem.indexOf(u8, stuck.secure_input.text(), "undo") != null);
    try std.testing.expect(std.mem.indexOf(u8, stuck.secure_input.text(), "log out") != null); // nothing else clears it

    // No hold, no row — and no wording to leak.
    const clear = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expect(clear.secure_input.hidden);
    try std.testing.expectEqualStrings("", clear.secure_input.text());
}

test "the Model Installation row words all four on-disk states" {
    try std.testing.expectEqualStrings("Whisper Large v3 Turbo — not installed", presented(snap(.{ .installation = .absent }), settingsFor(.{})).installation.text());
    try std.testing.expectEqualStrings("Whisper Large v3 Turbo — installed", presented(snap(.{ .installation = .ready }), settingsFor(.{})).installation.text());
    try std.testing.expectEqualStrings("Whisper Large v3 Turbo — update available", presented(snap(.{ .installation = .update_available }), settingsFor(.{})).installation.text());
    try std.testing.expectEqualStrings("Whisper Large v3 Turbo — corrupt", presented(snap(.{ .installation = .corrupt }), settingsFor(.{})).installation.text());
}

test "the identity rows spell out the receipt, and hide together when there is none" {
    const absent = presented(snap(.{}), settingsFor(.{}));
    for ([_]*const Row{ &absent.identity_source, &absent.identity_artifact, &absent.identity_runtime, &absent.identity_installer }) |row|
        try std.testing.expect(row.hidden);

    const p = presented(snap(.{ .installation_identity = fixtureIdentity() }), settingsFor(.{}));
    try std.testing.expect(!p.identity_source.hidden);
    try std.testing.expectEqualStrings("Repository — ggerganov/whisper.cpp@98aa99a0 — installation inst-7", p.identity_source.text());
    try std.testing.expectEqualStrings(
        "Artifact — ggml-large-v3-turbo.bin — 1624555275 bytes — sha256 cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
        p.identity_artifact.text(),
    );
    try std.testing.expectEqualStrings(
        "Runtime — whisper-cli — sha256 abababababababababababababababababababababababababababababababab",
        p.identity_runtime.text(),
    );
    try std.testing.expectEqualStrings("Installed by — type-wave 0.3.2", p.identity_installer.text());
}

test "a legacy installation with no id says so rather than showing a blank" {
    var legacy = fixtureIdentity();
    legacy.installation_id = null;
    const p = presented(snap(.{ .installation_identity = legacy }), settingsFor(.{}));
    try std.testing.expectEqualStrings("Repository — ggerganov/whisper.cpp@98aa99a0 — installation legacy", p.identity_source.text());
}

test "the Model Operation row reports its phase, with byte progress when there is any" {
    try std.testing.expectEqualStrings("Model Operation — idle", presented(snap(.{}), settingsFor(.{})).operation.text());
    try std.testing.expectEqualStrings("Model Operation — verifying", presented(snap(.{ .operation = .verifying }), settingsFor(.{})).operation.text());
    try std.testing.expectEqualStrings(
        "Model Operation — installing — 512/2048 bytes",
        presented(snap(.{ .operation = .installing, .operation_bytes = .{ .completed = 512, .total = 2048 } }), settingsFor(.{})).operation.text(),
    );
}

test "the Failure row pairs a reported detail with its recovery, and stands alone without one" {
    const detail = try FailureDetail.init("sha256 mismatch");
    try std.testing.expectEqualStrings(
        "Failure — sha256 mismatch — Repair or Remove",
        presented(snap(.{ .installation = .corrupt, .failure_detail = detail }), settingsFor(.{})).failure.text(),
    );
    try std.testing.expectEqualStrings(
        "Failure — sha256 mismatch — Retry or Open diagnostics",
        presented(snap(.{ .operation = .failed, .failure_detail = detail }), settingsFor(.{})).failure.text(),
    );

    // No detail: the failure kind alone carries both the cause and the remedy.
    try std.testing.expectEqualStrings("Failure — Model Installation corrupt; Repair or Remove", presented(snap(.{ .installation = .corrupt }), settingsFor(.{})).failure.text());
    try std.testing.expectEqualStrings("Failure — Local runtime unavailable; Retry or Open diagnostics", presented(snap(.{ .local_runtime_failure = true }), settingsFor(.{})).failure.text());
    try std.testing.expectEqualStrings("Failure — Model Operation failed; Retry or Open diagnostics", presented(snap(.{ .operation = .failed }), settingsFor(.{})).failure.text());
    try std.testing.expectEqualStrings("Model Operation cancelled; Retry if still needed", presented(snap(.{ .operation = .cancelled }), settingsFor(.{})).failure.text());

    // Healthy: no row, no wording.
    const ok = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expect(ok.failure.hidden);
    try std.testing.expectEqualStrings("", ok.failure.text());
}

test "the Local Model action rows hide exactly where the action is not allowed" {
    const paused = presented(snap(.{ .operation = .paused }), settingsFor(.{}));
    try std.testing.expect(!paused.model_action_hidden[@intFromEnum(ModelAction.resume_operation)]);
    try std.testing.expect(!paused.model_action_hidden[@intFromEnum(ModelAction.discard)]);
    try std.testing.expect(paused.model_action_hidden[@intFromEnum(ModelAction.install)]);
    try std.testing.expect(paused.model_action_hidden[@intFromEnum(ModelAction.cancel_operation)]);
    // Diagnostics is always reachable — it is how a user reports the rest of this.
    try std.testing.expect(!paused.model_action_hidden[@intFromEnum(ModelAction.diagnostics)]);
}

test "the settings-shaped rows are worded from the live Settings, not the Snapshot" {
    const off_local = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expectEqualStrings("Vocabulary (off)", off_local.vocabulary.text());
    try std.testing.expect(off_local.overlay.checked);
    try std.testing.expect(!off_local.backtrack.checked);
    try std.testing.expectEqualStrings("Needs internet; unavailable on the Local backend", off_local.backtrack_backend.text());

    // Local + Backtrack on is the one case that sharpens: the toggle stays checked so it can be
    // pre-enabled for the switch to OpenAI, and line 2 says it is not applying.
    const on_local = presented(snap(.{}), settingsFor(.{ .backtrack = true, .vocabulary_count = 1 }));
    try std.testing.expect(on_local.backtrack.checked);
    try std.testing.expectEqualStrings("Not applying \xe2\x80\x94 needs the OpenAI backend", on_local.backtrack_backend.text());
    try std.testing.expectEqualStrings("Vocabulary (1 term)\xe2\x80\xa6", on_local.vocabulary.text());

    // OpenAI: the ` — local only` suffix replaces the disclosure ellipsis (§4), and Backtrack
    // states the cloud reality identically whether on or off.
    const openai = presented(snap(.{ .selected_backend = .openai, .health = .{ .paused = false, .status = .ready } }), settingsFor(.{
        .selected_backend = .openai,
        .backtrack = true,
        .overlay = false,
        .vocabulary_count = 3,
    }));
    try std.testing.expectEqualStrings("Vocabulary (3 terms) \xe2\x80\x94 local only", openai.vocabulary.text());
    try std.testing.expectEqualStrings("Needs internet; unavailable on the Local backend", openai.backtrack_backend.text());
    try std.testing.expect(!openai.overlay.checked);
}

test "the radio checkmark follows the selected option, and a hand-edited value shows none" {
    var selected: [group_count]?u8 = @splat(null);
    selected[1] = 2; // Talk Key → Globe (fn)
    const p = presented(snap(.{}), settingsFor(.{ .selected = selected }));
    try std.testing.expect(p.group_checked[1][2]);
    try std.testing.expect(!p.group_checked[1][0]);
    // Group 0 has no selection in this view, so nothing in it is checked.
    for (0..max_group_opts) |oi| try std.testing.expect(!p.group_checked[0][oi]);
}

test "settingsView reads each group back, including the single-option model group" {
    const defaults = config.Settings{};
    const v = settingsView(&defaults);
    try std.testing.expectEqual(@as(?u8, 0), v.selected[0]); // .openai
    try std.testing.expectEqual(@as(?u8, 0), v.selected[1]); // .right_option
    try std.testing.expectEqual(@as(?u8, 0), v.selected[2]); // the one curated model
    try std.testing.expectEqual(@as(?u8, 0), v.selected[3]); // "en"
    try std.testing.expectEqual(@as(?u8, 1), v.selected[4]); // "low" is the second delay tier
    try std.testing.expectEqual(@as(?u8, 0), v.selected[5]); // .near_field
    try std.testing.expectEqual(@as(?u8, 0), v.selected[6]); // .paste
    try std.testing.expectEqual(backend.Backend.openai, v.selected_backend);
    try std.testing.expectEqual(@as(usize, 0), v.vocabulary_count);
}

test "settingsView reports no checkmark for a hand-edited value outside the curated presets" {
    // "xhigh" and an unlisted model stay hand-editable by design — the group simply shows no
    // checkmark rather than lying about which preset is active.
    var hand_edited = config.Settings{ .delay = "xhigh", .model = "gpt-4o-transcribe" };
    hand_edited.language = "de";
    const v = settingsView(&hand_edited);
    try std.testing.expectEqual(@as(?u8, null), v.selected[2]); // model
    try std.testing.expectEqual(@as(?u8, null), v.selected[3]); // language
    try std.testing.expectEqual(@as(?u8, null), v.selected[4]); // delay
    try std.testing.expectEqual(@as(?u8, 0), v.selected[1]); // untouched groups still resolve
}

test "auto-detect is a real language option, not an absent one" {
    const auto = config.Settings{ .language = "" };
    try std.testing.expectEqual(@as(?u8, 2), settingsView(&auto).selected[3]);
}

// ---- the Recent Insertions rows: structural, deliberately text-free -------------------

test "an empty ring reads as a disabled parent row with nothing to open" {
    const p = presented(snap(.{}), settingsFor(.{}));
    try std.testing.expect(p.history.empty);
    try std.testing.expectEqual(@as(usize, 0), p.history.count);
    try std.testing.expectEqualStrings("No recent insertions", p.history.parent.text());
    try std.testing.expect(!p.history.parent.enabled);
    for (p.history.rows) |row| try std.testing.expect(row.hidden);
}

test "a populated ring shows one row per entry and hides the rest of the fixed pool" {
    const s = history(&.{
        .{ .char_len = 3, .outcome = .failed, .timestamp = 30 },
        .{ .char_len = 2, .outcome = .ok, .timestamp = 20 },
    });
    const p = presented(s, settingsFor(.{}));
    try std.testing.expect(!p.history.empty);
    try std.testing.expectEqualStrings("Recent Insertions", p.history.parent.text());
    try std.testing.expect(p.history.parent.enabled);
    try std.testing.expectEqual(@as(usize, 2), p.history.count);
    try std.testing.expect(!p.history.rows[0].hidden);
    try std.testing.expect(!p.history.rows[1].hidden);
    try std.testing.expect(p.history.rows[2].hidden);
    // Newest-first order, and the stamp a click routes off.
    try std.testing.expectEqual(@as(i64, 30), p.history.rows[0].entry.timestamp);
    try std.testing.expectEqual(HistoryDot.failed, p.history.rows[0].entry.dot);
}

test "a history row carries no transcript bytes — reveal is a flag, not text" {
    var reveal = RevealSet{};
    reveal.toggle(20); // reveal only the second row
    const s = history(&.{
        .{ .char_len = 3, .outcome = .ok, .timestamp = 30 },
        .{ .char_len = 2, .outcome = .ok, .timestamp = 20 },
    });
    var p: Presentation = undefined;
    present(&p, s, settingsFor(.{}), reveal);

    try std.testing.expect(!p.history.rows[0].revealed);
    try std.testing.expect(p.history.rows[1].revealed);
    // The type has no field that could carry `inserted` / `raw` text at all — the adapter
    // fetches it from the authoritative ring only for a revealed row.
    try std.testing.expect(!@hasField(HistoryRow, "title"));
    try std.testing.expect(!@hasField(HistoryRow, "inserted"));
}

test "a withheld row offers no text actions, and cannot be revealed by a stale toggle (#286)" {
    var reveal = RevealSet{};
    reveal.toggle(30); // the user had revealed this stamp — or an evicted entry that reused it
    const s = history(&.{
        .{ .char_len = 0, .outcome = .ok, .timestamp = 30, .withheld = true },
        .{ .char_len = 5, .outcome = .ok, .timestamp = 20 },
    });
    var p: Presentation = undefined;
    present(&p, s, settingsFor(.{}), reveal);

    // The gate lives here, in the Presentation, where it is tested — the ring returning zero
    // bytes for the stamp is only the floor under it.
    try std.testing.expect(!p.history.rows[0].text_available);
    try std.testing.expect(!p.history.rows[0].revealed); // whatever the RevealSet holds
    try std.testing.expect(p.history.rows[0].entry.withheld);
    // The row itself is present and clickable-through — only its text actions are not.
    try std.testing.expect(!p.history.rows[0].hidden);
    // An ordinary neighbour is untouched.
    try std.testing.expect(p.history.rows[1].text_available);
}

test "a reveal toggle on an evicted stamp leaves every row masked" {
    var reveal = RevealSet{};
    reveal.toggle(999); // a stamp the ring no longer holds
    const s = history(&.{.{ .char_len = 3, .outcome = .ok, .timestamp = 30 }});
    var p: Presentation = undefined;
    present(&p, s, settingsFor(.{}), reveal);
    try std.testing.expect(!p.history.rows[0].revealed);
}

test "the reveal affordance mirrors the row's state" {
    try std.testing.expectEqualStrings("Reveal text", revealItemTitle(false, true));
    try std.testing.expectEqualStrings("Hide text", revealItemTitle(true, true));
    // A withheld row says why there is nothing to reveal, whatever the toggle holds (#286).
    for ([_]bool{ false, true }) |revealed| {
        const title = revealItemTitle(revealed, false);
        try std.testing.expect(std.mem.indexOf(u8, title, "No text retained") != null);
        try std.testing.expect(std.mem.indexOf(u8, title, "Secure Event Input") != null);
    }
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

// ---- the Row invariant that makes the whole value comparable --------------------------

test "a Row's bytes past its length are always zero, so equal titles compare equal" {
    // The invariant NSString relies on for its sentinel, and std.meta.eql relies on for the
    // early-out: a shorter title must not leave a longer one's tail behind.
    const long = presented(snap(.{ .installation = .update_available }), settingsFor(.{}));
    const short = presented(snap(.{ .installation = .ready }), settingsFor(.{}));
    try std.testing.expect(!std.meta.eql(long.installation, short.installation));

    const short_again = presented(snap(.{ .installation = .ready }), settingsFor(.{}));
    try std.testing.expect(std.meta.eql(short.installation, short_again.installation));
    for (short.installation.bytes[short.installation.len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "present is total: the same inputs always yield a byte-identical Presentation" {
    const s = snap(.{ .operation = .installing, .operation_bytes = .{ .completed = 1, .total = 2 }, .installation_identity = fixtureIdentity() });
    const v = settingsFor(.{ .backtrack = true, .vocabulary_count = 4 });
    try std.testing.expect(std.meta.eql(presented(s, v), presented(s, v)));
}

// ---- the pump: apply-only-on-change, asserted off a FakeChrome ------------------------

const FakeChrome = struct {
    applied: usize = 0,
    last: Presentation = .{},

    pub fn apply(self: *FakeChrome, p: *const Presentation) void {
        self.applied += 1;
        self.last = p.*;
    }
};

test "the pump applies the first Presentation and then only when it changes" {
    var chrome = FakeChrome{};
    var pump = StatusItem(FakeChrome).init(&chrome);
    const v = settingsFor(.{});

    try std.testing.expect(pump.refresh(snap(.{}), v, .{}));
    try std.testing.expectEqual(@as(usize, 1), chrome.applied);

    // Same inputs — nothing reaches AppKit.
    try std.testing.expect(!pump.refresh(snap(.{}), v, .{}));
    try std.testing.expectEqual(@as(usize, 1), chrome.applied);

    // A moved axis gets through.
    try std.testing.expect(pump.refresh(snap(.{ .health = .{ .paused = true, .status = .ready_offline } }), v, .{}));
    try std.testing.expectEqual(@as(usize, 2), chrome.applied);
    try std.testing.expectEqualStrings("type-wave — Paused", chrome.last.status_line.text());
}

test "two different Snapshots that read identically cost one apply, not two" {
    // This is what comparing the Presentation buys over comparing the Snapshot: the ring's
    // history array is fixed-size, so stale slots past `history_count` differ between
    // Snapshots that render exactly the same menu.
    var chrome = FakeChrome{};
    var pump = StatusItem(FakeChrome).init(&chrome);
    const v = settingsFor(.{});

    var first = snap(.{});
    first.history[5] = .{ .char_len = 9, .outcome = .failed, .timestamp = 77 };
    var second = snap(.{});
    second.history[5] = .{ .char_len = 1, .outcome = .ok, .timestamp = 12 };
    try std.testing.expect(!std.meta.eql(first, second)); // the Snapshots differ...

    try std.testing.expect(pump.refresh(first, v, .{}));
    try std.testing.expect(!pump.refresh(second, v, .{})); // ...the Presentations do not
    try std.testing.expectEqual(@as(usize, 1), chrome.applied);
}

test "a settings change alone reaches the Chrome" {
    var chrome = FakeChrome{};
    var pump = StatusItem(FakeChrome).init(&chrome);
    try std.testing.expect(pump.refresh(snap(.{}), settingsFor(.{}), .{}));
    try std.testing.expect(pump.refresh(snap(.{}), settingsFor(.{ .backtrack = true }), .{}));
    try std.testing.expectEqual(@as(usize, 2), chrome.applied);
    try std.testing.expect(chrome.last.backtrack.checked);
}

test "a reveal toggle alone reaches the Chrome" {
    var chrome = FakeChrome{};
    var pump = StatusItem(FakeChrome).init(&chrome);
    const s = history(&.{.{ .char_len = 3, .outcome = .ok, .timestamp = 30 }});
    var reveal = RevealSet{};

    try std.testing.expect(pump.refresh(s, settingsFor(.{}), reveal));
    reveal.toggle(30);
    try std.testing.expect(pump.refresh(s, settingsFor(.{}), reveal));
    try std.testing.expectEqual(@as(usize, 2), chrome.applied);
    try std.testing.expect(chrome.last.history.rows[0].revealed);
}

test "invalidate forces the next apply through an unchanged Presentation" {
    // Menu-open needs this: the Recent Insertions relative times are formatted by the adapter
    // from a live clock, so an unchanged value would still render a stale "2m ago".
    var chrome = FakeChrome{};
    var pump = StatusItem(FakeChrome).init(&chrome);
    const v = settingsFor(.{});
    try std.testing.expect(pump.refresh(snap(.{}), v, .{}));
    try std.testing.expect(!pump.refresh(snap(.{}), v, .{}));
    pump.invalidate();
    try std.testing.expect(pump.refresh(snap(.{}), v, .{}));
    try std.testing.expectEqual(@as(usize, 2), chrome.applied);
}

test "the displayed Presentation is what click routing reads — and is null before the first apply" {
    var chrome = FakeChrome{};
    var pump = StatusItem(FakeChrome).init(&chrome);
    try std.testing.expect(pump.displayed() == null); // a click before the first paint is a no-op

    _ = pump.refresh(snap(.{ .installation = .absent, .health = .{ .paused = false, .status = .no_local_installation } }), settingsFor(.{}), .{});
    const shown = pump.displayed().?;
    try std.testing.expectEqual(PrimaryAction.install_local_model, shown.primary_action);
    try std.testing.expectEqualStrings("Install Whisper Large v3 Turbo\xe2\x80\xa6", shown.primary.text());

    // The routing identity and the label the user read come from the same value, so they
    // cannot disagree (ADR-0011).
    try std.testing.expectEqualStrings(chrome.last.primary.text(), shown.primary.text());
}
