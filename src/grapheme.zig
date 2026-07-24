//! grapheme.zig — the Undo deletion-count rule (wayfinder #211/#214, build ticket #220).
//! One `⌫` keystroke deletes one **extended grapheme cluster** (UAX #29) in AppKit and
//! Chromium/Electron text views, so "how many backspaces delete exactly this Insertion"
//! is the cluster count over the stored, with-trailing-space `inserted` UTF-8 bytes —
//! *not* the byte count (`Record.inserted_len`) and *not* the UTF-16 length. Counted via
//! CoreFoundation's `CFStringGetRangeOfComposedCharactersAtIndex` (the platform's own
//! segmentation, per #214). Zero-length input or any segmentation failure yields **0**,
//! which callers treat as refuse/no-op — never a partial count that would half-delete.

const std = @import("std");

// ---- CoreFoundation string segmentation ----
const CFStringRef = ?*anyopaque;
const CFIndex = c_long;
const CFRange = extern struct { location: CFIndex, length: CFIndex };
const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, is_external_representation: u8) CFStringRef;
extern "c" fn CFStringGetLength(str: CFStringRef) CFIndex;
extern "c" fn CFStringGetRangeOfComposedCharactersAtIndex(str: CFStringRef, index: CFIndex) CFRange;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

/// The number of `⌫` keystrokes that delete exactly `bytes` (UTF-8): its extended-
/// grapheme-cluster count. 0 on empty input, invalid UTF-8, or a CoreFoundation
/// segmentation failure — the caller's refuse/no-op signal (#214).
pub fn graphemeCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    // Invalid UTF-8 → null → 0. The ring only stores what the daemon inserted (valid
    // UTF-8), so this is the segmentation-failure refuse path, not an expected case.
    const str = CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), kCFStringEncodingUTF8, 0) orelse return 0;
    defer CFRelease(str);
    const len = CFStringGetLength(str); // UTF-16 units, the index space CF walks in
    var idx: CFIndex = 0;
    var count: usize = 0;
    while (idx < len) {
        const r = CFStringGetRangeOfComposedCharactersAtIndex(str, idx);
        // A cluster that doesn't advance past idx would loop forever; treat any such
        // degenerate range as segmentation failure → 0, never a partial count.
        if (r.length <= 0 or r.location + r.length <= idx) return 0;
        count += 1;
        idx = r.location + r.length;
    }
    return count;
}

// ---- tests: real CoreFoundation segmentation, asserting cluster counts ----

const expectEqual = std.testing.expectEqual;

test "graphemeCount counts ASCII one cluster per byte, trailing space included" {
    try expectEqual(@as(usize, 3), graphemeCount("abc"));
    try expectEqual(@as(usize, 4), graphemeCount("abc ")); // with-space counts one more (#214: restore pre-Insertion state)
}

test "graphemeCount returns 0 for empty input (refuse/no-op)" {
    try expectEqual(@as(usize, 0), graphemeCount(""));
}

test "graphemeCount counts multibyte clusters, not bytes" {
    try expectEqual(@as(usize, 4), graphemeCount("café")); // é = U+00E9, 2 UTF-8 bytes, 1 cluster
    try expectEqual(@as(usize, 4), graphemeCount("日本語 ")); // 3 CJK ideographs (3 bytes each) + space
}

test "graphemeCount folds combining marks into their base's cluster" {
    try expectEqual(@as(usize, 4), graphemeCount("cafe\u{0301}")); // e + combining acute = one cluster
    try expectEqual(@as(usize, 1), graphemeCount("n\u{0303}")); // n + combining tilde
}

test "graphemeCount counts emoji as clusters, not UTF-16 units" {
    try expectEqual(@as(usize, 1), graphemeCount("👍")); // U+1F44D: 4 bytes, 2 UTF-16 units, 1 cluster
    try expectEqual(@as(usize, 1), graphemeCount("👨\u{200D}👩\u{200D}👧\u{200D}👦")); // ZWJ family: 25 bytes, 11 UTF-16 units, 1 cluster
    try expectEqual(@as(usize, 1), graphemeCount("🇸🇪")); // regional-indicator pair, 1 flag
    try expectEqual(@as(usize, 3), graphemeCount("ok👍")); // mixed
}

test "graphemeCount counts a with-space input one more than its without-space form" {
    // The stored `inserted` bytes carry ensureTrailingSpace's separator; Undo deletes it
    // too (#214: restore the pre-Insertion state), so the space is one more cluster.
    try expectEqual(graphemeCount("👍") + 1, graphemeCount("👍 "));
    try expectEqual(graphemeCount("hej") + 1, graphemeCount("hej "));
}

test "graphemeCount returns 0 on invalid UTF-8 (segmentation failure, never partial)" {
    try expectEqual(@as(usize, 0), graphemeCount(&[_]u8{ 'o', 'k', 0xFF, 0xFE })); // valid prefix must not leak a partial count
    try expectEqual(@as(usize, 0), graphemeCount(&[_]u8{ 0xE6, 0x97 })); // truncated multibyte sequence
}
