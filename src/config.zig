//! config.zig — the daemon's configuration (wayfinder #16): non-secret settings
//! from a ZON file (`~/.config/type-wave/config.zon`) and the OpenAI secret from an
//! env file (`~/.config/type-wave/env`).
//!
//! WHY the secret is read from a file, not the environment: the daemon runs as a
//! launchd LaunchAgent OUTSIDE `nix develop`, so the flake `shellHook` that exports
//! OPENAI_API_KEY never fires for it (issue #7's caveat, re-flagged by #15). We parse
//! the env file ourselves. For a foreground `nix develop` run the variable IS already
//! exported, so we fall back to the process environment when the file is absent —
//! dev ergonomics with no separate setup.
//!
//! Resilience (issue #10's self-healing ethos): a missing OR malformed config.zon
//! yields all defaults with a logged warning — a config typo must never keep the
//! daemon from starting. The secret is the one hard stop: without it there is nothing
//! to connect to, so `load` returns `error.NoApiKey` and main refuses to start.
//!
//! Lifetime: `Config` is a load-once, process-lifetime singleton. Its backing
//! allocations are intentionally never freed — and `std.zon.parse.free` must NOT be
//! called on `settings`: fields omitted from the file keep their struct-default value,
//! which points at a static string literal, and `free` would fault trying to release
//! it (verified against this Zig nightly).

const std = @import("std");
const tap = @import("tap.zig");
const insert = @import("insert.zig");

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

pub const Config = struct {
    settings: Settings,
    /// NUL-terminated so it drops straight into the `Authorization: Bearer` header.
    api_key: [:0]const u8,
};

pub const LoadError = error{NoApiKey};

const config_rel = ".config/type-wave/config.zon";
const env_rel = ".config/type-wave/env";
const max_file = 64 * 1024;

/// Load settings (defaults if the file is absent/unreadable/malformed) and the OpenAI
/// secret (hard-required). `io` and `gpa` must outlive the process — see the lifetime
/// note above; nothing here is freed.
pub fn load(io: std.Io, gpa: std.mem.Allocator) LoadError!Config {
    const home = homeDir() orelse {
        std.debug.print("config: $HOME is not set — cannot locate ~/.config/type-wave.\n", .{});
        return error.NoApiKey; // no home => no key file => nothing to connect to
    };
    const settings = loadSettings(io, gpa, home);
    const api_key = loadApiKey(io, gpa, home) orelse {
        std.debug.print(
            \\config: no OPENAI_API_KEY found.
            \\  Put it in ~/.config/type-wave/env as a line:  OPENAI_API_KEY=sk-...
            \\  (chmod 600; see issue #7) — or export it into this shell for a foreground run.
            \\
        , .{});
        return error.NoApiKey;
    };
    return .{ .settings = settings, .api_key = api_key };
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

/// The secret: the env file first (the daemon's path), then the process environment
/// (the `nix develop` foreground path). Returns null only when neither yields a key.
fn loadApiKey(io: std.Io, gpa: std.mem.Allocator, home: []const u8) ?[:0]const u8 {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, env_rel }) catch return apiKeyFromEnv(gpa);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file)) catch |e| {
        if (e != error.FileNotFound)
            std.debug.print("config: could not read {s}: {s}\n", .{ path, @errorName(e) });
        return apiKeyFromEnv(gpa); // fall back to the exported env var
    };
    defer gpa.free(raw);

    if (parseEnvKey(raw)) |val| return gpa.dupeSentinel(u8, val, 0) catch null;
    return apiKeyFromEnv(gpa);
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
