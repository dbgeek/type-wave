//! vocab.zig — pure helpers turning a user vocabulary list into what the local Whisper
//! backend and the menu need (docs/vocab-biasing-spec.md §2, §6). Two independently
//! testable functions, allocation only on the built string, and **no wiring**:
//!
//!   * `buildPrompt` — the bare comma glossary sent as Whisper's `initial_prompt`,
//!     self-truncated drop-tail / keep-head so Whisper's own silent head-drop (#162)
//!     never bites the user's most-important (leading) terms.
//!   * `estimateTokens` / `budget` — the conservative token projection that drives the
//!     menu's soft, non-blocking "long list" hint.
//!
//! The chars→token heuristic is single-homed here (spec §2: "numbers tunable and
//! centralized") so construction and the menu hint can never disagree about the budget.

const std = @import("std");

/// Conservative chars→token divisor. Real English runs ~4 chars/token; glossary terms
/// (names, jargon, code identifiers) tokenize worse, so dividing by 3 **over-counts**
/// tokens and buys head-room below Whisper's hard cap. Tunable.
pub const chars_per_token: usize = 3;

/// Target token budget for the constructed glossary — the ceiling `buildPrompt`
/// truncates to. Sized well below Whisper's ~223-BPE cap (#162, 448/2) so the string we
/// actually send always survives Whisper's own truncation intact, keeping keep-head
/// safe. Tunable.
pub const target_tokens: usize = 180;

/// "Getting long" advisory threshold for the menu hint — below `target_tokens` so the
/// user sees the soft warning on the run-up, before construction actually starts
/// dropping tail items. Tunable.
pub const near_tokens: usize = 150;

/// Character budget the glossary is truncated to: target tokens × chars/token.
const budget_chars: usize = target_tokens * chars_per_token;

/// The glossary joiner. `buildPrompt` and the char-counting helpers must agree on it.
const separator = ", ";

/// Tri-state budget signal for the dialog's soft, non-blocking hint (spec §6).
pub const Budget = enum { ok, near, over };

/// Total character length of the bare comma glossary for `list`, without building it —
/// each item's own bytes plus a 2-byte ", " before every item after the first. Empty
/// list ⇒ 0.
fn glossaryChars(list: []const []const u8) usize {
    var total: usize = 0;
    for (list, 0..) |item, i| {
        if (i != 0) total += separator.len;
        total += item.len;
    }
    return total;
}

/// Conservative token estimate for the **full, untruncated** glossary built from `list` —
/// what the menu warns against, before `buildPrompt` truncates to fit. Ceil-divides so a
/// non-empty list is never estimated at zero tokens; empty list ⇒ 0.
pub fn estimateTokens(list: []const []const u8) usize {
    const chars = glossaryChars(list);
    if (chars == 0) return 0;
    return (chars + chars_per_token - 1) / chars_per_token; // ceil-divide, conservative
}

/// Tri-state budget classification driving the dialog's soft hint (spec §6): `.over` once
/// the estimate crosses the construction budget (so `buildPrompt` will drop tail items),
/// `.near` on the advisory run-up, `.ok` otherwise. Advisory only — never blocks a Save.
pub fn budget(list: []const []const u8) Budget {
    const est = estimateTokens(list);
    if (est > target_tokens) return .over;
    if (est > near_tokens) return .near;
    return .ok;
}

/// Build the bare comma-separated glossary (`"term1, term2, term3"`) for `list`, in **user
/// list order** — the model is flat/unweighted, so we never reorder by "importance".
/// Self-truncated drop-tail / keep-head at **whole-item** boundaries to `budget_chars`:
/// keep the leading items that fit, drop the rest, never split a term — the documented
/// "most important first" convention. A non-empty list always keeps ≥1 item (load clamps
/// each item to 100 chars, so one always fits the budget). An empty list ⇒ an empty string
/// (the downstream no-op signal both the backend and the menu key off). Caller owns the
/// returned slice.
pub fn buildPrompt(allocator: std.mem.Allocator, list: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (list) |item| {
        const not_first = out.items.len != 0;
        const would_be = out.items.len + (if (not_first) separator.len else 0) + item.len;
        if (not_first and would_be > budget_chars) break; // whole-item drop-tail / keep-head
        if (not_first) try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

const talloc = std.testing.allocator;

test "buildPrompt joins terms as a bare comma glossary in user list order" {
    const prompt = try buildPrompt(talloc, &.{ "type-wave", "whisper.cpp", "Zig" });
    defer talloc.free(prompt);
    try std.testing.expectEqualStrings("type-wave, whisper.cpp, Zig", prompt);
}

test "buildPrompt returns an empty string for an empty list (the no-op signal)" {
    const prompt = try buildPrompt(talloc, &.{});
    defer talloc.free(prompt);
    try std.testing.expectEqual(@as(usize, 0), prompt.len);
}

test "buildPrompt returns a single term without any separator" {
    const prompt = try buildPrompt(talloc, &.{"solo"});
    defer talloc.free(prompt);
    try std.testing.expectEqualStrings("solo", prompt);
}

test "buildPrompt returns a within-budget list intact" {
    const list = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const prompt = try buildPrompt(talloc, &list);
    defer talloc.free(prompt);
    try std.testing.expectEqualStrings("alpha, beta, gamma, delta", prompt);
}

test "buildPrompt drops whole tail items to fit the budget, never splitting a term" {
    // 50-char terms: item 0 costs 50, each later item costs 2 (", ") + 50 = 52.
    // Cumulative for n items = 50 + (n-1)*52; ≤ 540 (budget) holds through n = 10
    // (518), and item 11 would reach 570 > 540 — so exactly 10 of 15 survive.
    const term = repeated('a', 50);
    var backing: [15][]const u8 = undefined;
    for (&backing) |*slot| slot.* = term;
    const prompt = try buildPrompt(talloc, &backing);
    defer talloc.free(prompt);

    var kept: usize = 1; // one term ⇒ zero separators; each extra term ⇒ one ", "
    for (prompt) |c| {
        if (c == ',') kept += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), kept);
    try std.testing.expect(prompt.len <= budget_chars); // stayed within budget
    // Whole-item: the string is exactly the kept terms joined — no split fragment.
    try std.testing.expect(std.mem.endsWith(u8, prompt, term));
    try std.testing.expect(!std.mem.endsWith(u8, prompt, ", ")); // no dangling separator
}

test "buildPrompt keeps at least the first term even if it alone exceeds the budget" {
    // Pathological (clamp normally caps items at 100 chars, so this can't arise in prod):
    // a single over-budget term is still returned whole rather than split or dropped.
    const giant = repeated('x', budget_chars + 100);
    const prompt = try buildPrompt(talloc, &.{giant});
    defer talloc.free(prompt);
    try std.testing.expectEqualStrings(giant, prompt);
}

test "estimateTokens is zero for an empty list and ceil-divides otherwise" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(&.{}));
    // "abc, de" = 7 chars ⇒ ceil(7/3) = 3 tokens (conservative over-count).
    try std.testing.expectEqual(@as(usize, 3), estimateTokens(&.{ "abc", "de" }));
}

test "budget crosses ok → near → over at the expected list sizes" {
    // Each term is 30 chars; joined cost is 30 + (n-1)*32 chars, /3 (ceil) for tokens.
    const term = repeated('t', 30);
    var backing: [40][]const u8 = undefined;
    for (&backing) |*slot| slot.* = term;

    // Small list stays comfortably ok.
    try std.testing.expectEqual(Budget.ok, budget(backing[0..5]));

    // Find the first size that trips .near and the first that trips .over, and assert the
    // classification matches estimateTokens against the thresholds at those sizes.
    var first_near: ?usize = null;
    var first_over: ?usize = null;
    for (1..backing.len + 1) |n| {
        const b = budget(backing[0..n]);
        if (b != .ok and first_near == null) first_near = n;
        if (b == .over and first_over == null) first_over = n;
    }
    try std.testing.expect(first_near != null);
    try std.testing.expect(first_over != null);
    try std.testing.expect(first_near.? < first_over.?); // near is reached before over
    try std.testing.expect(estimateTokens(backing[0..first_near.?]) > near_tokens);
    try std.testing.expect(estimateTokens(backing[0 .. first_near.? - 1]) <= near_tokens);
    try std.testing.expect(estimateTokens(backing[0..first_over.?]) > target_tokens);
    try std.testing.expect(estimateTokens(backing[0 .. first_over.? - 1]) <= target_tokens);
}

test "budget agrees with buildPrompt: an .over list is the one that gets truncated" {
    const term = repeated('a', 50);
    var backing: [15][]const u8 = undefined;
    for (&backing) |*slot| slot.* = term;
    try std.testing.expectEqual(Budget.over, budget(&backing));

    const prompt = try buildPrompt(talloc, &backing);
    defer talloc.free(prompt);
    try std.testing.expect(prompt.len < glossaryChars(&backing)); // actually dropped tail
}

/// Test-only: a `[]const u8` of `n` copies of `c`, built at comptime (mirrors config.zig's
/// helper — avoids the `**` repeat operator this Zig's ast-check rejects on strings). The
/// array lives in a struct-const so it has static storage the returned slice points at.
fn repeated(comptime c: u8, comptime n: usize) []const u8 {
    return &(struct {
        const arr = blk: {
            var b: [n]u8 = undefined;
            @memset(&b, c);
            break :blk b;
        };
    }).arr;
}
