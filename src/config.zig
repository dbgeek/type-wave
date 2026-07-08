//! config.zig — the daemon's configuration (wayfinder #16, secret re-homed by #33):
//! non-secret settings from a ZON file (`~/.config/type-wave/config.zon`) and the
//! OpenAI secret from the login keychain (keychain.zig).
//!
//! Key precedence: **process env → keychain**. The exported OPENAI_API_KEY is the dev
//! override — a foreground `nix develop` run has it in the environment, so unsigned
//! `zig-out` builds never touch Security.framework (an ad-hoc binary is a stranger to
//! the keychain item and would prompt — see keychain.zig). The installed signed daemon
//! runs under launchd with no shell environment, so it reads the keychain item it
//! created itself (`type-wave --set-key`), prompt-free.
//!
//! The legacy `~/.config/type-wave/env` file is retired as a source: a key still found
//! there is auto-migrated into the keychain once (and the file can then be deleted).
//!
//! Resilience (issue #10's self-healing ethos): a missing OR malformed config.zon
//! yields all defaults with a logged warning — a config typo must never keep the
//! daemon from starting. A missing secret never stops startup either: the daemon's
//! self-heal supervisor polls `loadApiKeyOnly` until a key appears.
//!
//! Lifetime: settings are a load-once, process-lifetime singleton. Backing allocations
//! are intentionally never freed — and `std.zon.parse.free` must NOT be called on the
//! parsed `Settings`: fields omitted from the file keep their struct-default value,
//! which points at a static string literal, and `free` would fault trying to release
//! it (verified against this Zig nightly).

const std = @import("std");
const tap = @import("tap.zig");
const insert = @import("insert.zig");
const keychain = @import("keychain.zig");

/// Non-secret settings. The field names + types ARE the accepted `config.zon` schema
/// (std.zon parses the file straight into this struct). Every field has a default, so
/// an absent file — or an absent field — falls back cleanly.
///
/// `model`/`language`/`delay` are strings, not enums, on purpose: issue #11 wants to
/// A/B `gpt-4o-mini-transcribe` (and other language/delay values) by editing the file
/// alone, no rebuild. `talk_key`/`noise_reduction`/`insertion` are enums — a closed,
/// validated vocabulary the code switches on.
pub const Settings = struct {
    talk_key: tap.TalkKey = .right_option,
    model: []const u8 = "gpt-realtime-whisper",
    language: []const u8 = "en",
    delay: []const u8 = "low",
    noise_reduction: NoiseReduction = .near_field,
    insertion: insert.Method = .paste,
    /// Show the live-partials overlay pill at the cursor (wayfinder #22). On by default;
    /// set `.overlay = false` for sound-only feedback. A headless run (no display) also
    /// degrades to sound-only on its own, so this never blocks startup.
    overlay: bool = true,

    /// OpenAI input-audio noise reduction. `.off` sends JSON `null` (feature disabled).
    pub const NoiseReduction = enum { near_field, far_field, off };

    /// The noise_reduction "type" string the Transcription Session wants, or null when
    /// disabled (session.zig emits `"noise_reduction":null` for that).
    pub fn noiseReductionType(self: Settings) ?[]const u8 {
        return switch (self.noise_reduction) {
            .near_field => "near_field",
            .far_field => "far_field",
            .off => null,
        };
    }
};

const config_rel = ".config/type-wave/config.zon";
const env_rel = ".config/type-wave/env";
const max_file = 64 * 1024;

/// Load just the non-secret settings — defaults when the file is absent/malformed or
/// `$HOME` is unset. The daemon (wayfinder #19) loads these once at startup; they never
/// block the process from starting, and the secret is polled separately (self-heal).
pub fn loadSettingsOnly(io: std.Io, gpa: std.mem.Allocator) Settings {
    const home = homeDir() orelse return .{};
    return loadSettings(io, gpa, home);
}

/// Re-read just the OpenAI secret — null while still absent. The daemon's self-heal
/// supervisor (wayfinder #19) polls this until a key appears (exported env var,
/// keychain item, or a legacy env file to migrate), then constructs the Transcription
/// Session. NUL-terminated so it drops straight into the `Authorization: Bearer` header.
pub fn loadApiKeyOnly(io: std.Io, gpa: std.mem.Allocator) ?[:0]const u8 {
    return loadApiKey(io, gpa);
}

fn homeDir() ?[]const u8 {
    const h = std.c.getenv("HOME") orelse return null;
    const s = std.mem.span(h);
    return if (s.len == 0) null else s;
}

/// Read + parse config.zon; any failure short of a live parse degrades to defaults.
fn loadSettings(io: std.Io, gpa: std.mem.Allocator, home: []const u8) Settings {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, config_rel }) catch return .{};

    const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_file), .of(u8), 0) catch |e| {
        if (e != error.FileNotFound)
            std.debug.print("config: could not read {s}: {s} — using defaults.\n", .{ path, @errorName(e) });
        return .{}; // absent (the normal first-run case) or unreadable => defaults
    };
    // src is intentionally not freed (parsed strings are copied out of it, but this is
    // a one-time load and the whole Config leaks for the process lifetime by design).

    var diag: std.zon.parse.Diagnostics = .{};
    const parsed = std.zon.parse.fromSliceAlloc(Settings, gpa, src, &diag, .{}) catch {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        diag.format(&w) catch {};
        std.debug.print("config: {s} is malformed — using defaults.\n  {s}\n", .{ path, w.buffered() });
        return .{};
    };
    return parsed;
}

/// The secret: process environment first (the dev override), then the keychain item.
/// A keychain miss falls through to the one-time env-file migration. Returns null only
/// when no source yields a key.
fn loadApiKey(io: std.Io, gpa: std.mem.Allocator) ?[:0]const u8 {
    if (apiKeyFromEnv(gpa)) |key| return key;
    switch (keychain.readKey(gpa)) {
        .key => |key| {
            last_keychain_err = 0; // healthy again — a later failure re-logs
            return key;
        },
        .absent => return migrateEnvFile(io, gpa),
        .err => |st| {
            logKeychainErrOnce(st);
            return null;
        },
    }
}

/// Supervisor-thread-only (like the poll that calls it): the last keychain status logged,
/// so a locked/denied keychain isn't re-reported every 3 s tick. 0 = nothing reported.
var last_keychain_err: keychain.OSStatus = 0;

fn logKeychainErrOnce(st: keychain.OSStatus) void {
    if (st == last_keychain_err) return;
    last_keychain_err = st;
    var buf: [256]u8 = undefined;
    std.debug.print(
        "config: keychain read failed: {s} — treating the key as missing (will keep retrying; the item is never rewritten).\n",
        .{keychain.describe(st, &buf)},
    );
}

/// One-time migration (wayfinder #33): the keychain has no item, but the retired
/// `~/.config/type-wave/env` file may still hold the key from the pre-keychain era. If it
/// does, store it in the keychain and hand it to this run. Once the store succeeds the
/// keychain hit wins every later lookup, so the file is never read again — that's what
/// makes the migration one-time. A failed store still returns the key (the daemon should
/// work today); the migration simply retries on a later poll or the next start.
///
/// ACL note: the migrating process becomes the item's creator, so this is meant to run in
/// the installed signed daemon. Foreground dev runs export OPENAI_API_KEY and never get
/// here (the env override wins above).
fn migrateEnvFile(io: std.Io, gpa: std.mem.Allocator) ?[:0]const u8 {
    const home = homeDir() orelse return null;
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, env_rel }) catch return null;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file)) catch |e| {
        if (e != error.FileNotFound)
            std.debug.print("config: could not read {s}: {s}\n", .{ path, @errorName(e) });
        return null; // no legacy file (the normal case once migrated) => no key anywhere
    };
    defer gpa.free(raw);
    const val = parseEnvKey(raw) orelse return null;
    const key = gpa.dupeSentinel(u8, val, 0) catch return null;

    const st = keychain.storeKey(key);
    if (st == keychain.errSecSuccess) {
        std.debug.print(
            "config: migrated the API key from {s} into the login keychain — the file is no longer used and can be deleted.\n",
            .{path},
        );
    } else {
        var buf: [256]u8 = undefined;
        std.debug.print(
            "config: found the API key in {s} but storing it in the keychain failed: {s} — using it for this run; migration will retry.\n",
            .{ path, keychain.describe(st, &buf) },
        );
    }
    return key;
}

fn apiKeyFromEnv(gpa: std.mem.Allocator) ?[:0]const u8 {
    const v = std.c.getenv("OPENAI_API_KEY") orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    return gpa.dupeSentinel(u8, s, 0) catch null;
}

/// Extract OPENAI_API_KEY's value from a shell-sourceable env file. Accepts both
/// `OPENAI_API_KEY=...` and `export OPENAI_API_KEY=...`, ignores blank lines and `#`
/// comments, and strips one layer of matching single/double quotes. Last assignment
/// wins. The returned slice borrows `text` — the caller copies it before freeing.
fn parseEnvKey(text: []const u8) ?[]const u8 {
    const key = "OPENAI_API_KEY";
    var result: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue; // e.g. OPENAI_API_KEY_OTHER=...
        var val = std.mem.trim(u8, rest[1..], " \t");
        if (val.len >= 2 and
            ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\'')))
            val = val[1 .. val.len - 1];
        if (val.len > 0) result = val;
    }
    return result;
}

// ---- tests (backfilled with the coordinator work, 2026-07-08) ----------------

test "parseEnvKey reads a bare assignment" {
    try std.testing.expectEqualStrings("sk-abc", parseEnvKey("OPENAI_API_KEY=sk-abc").?);
}

test "parseEnvKey accepts an export prefix" {
    try std.testing.expectEqualStrings("sk-xyz", parseEnvKey("export OPENAI_API_KEY=sk-xyz").?);
}

test "parseEnvKey strips one layer of matching quotes" {
    try std.testing.expectEqualStrings("sk-dq", parseEnvKey("OPENAI_API_KEY=\"sk-dq\"").?);
    try std.testing.expectEqualStrings("sk-sq", parseEnvKey("OPENAI_API_KEY='sk-sq'").?);
}

test "parseEnvKey: last assignment wins, blanks and comments ignored" {
    const text =
        \\# a comment
        \\
        \\OPENAI_API_KEY=first
        \\export OPENAI_API_KEY=second
    ;
    try std.testing.expectEqualStrings("second", parseEnvKey(text).?);
}

test "parseEnvKey ignores a near-miss key and an absent key" {
    try std.testing.expect(parseEnvKey("OPENAI_API_KEY_OTHER=nope") == null);
    try std.testing.expect(parseEnvKey("# nothing here\nFOO=bar") == null);
}
