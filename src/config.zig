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
//! there is auto-migrated into the keychain once, and the plaintext file is then taken off
//! disk by the daemon rather than left for the user to delete (#282).
//!
//! Resilience (issue #10's self-healing ethos): a missing OR malformed config.zon
//! yields all defaults with a logged warning — a config typo must never keep the
//! daemon from starting. A missing secret never stops startup either: the daemon's
//! self-heal supervisor polls `loadApiKeyOnly` until a key appears.
//!
//! Lifetime: settings are load-and-leak, published as **immutable snapshots** through
//! `Store` (wayfinder #32/#34): the menu — the sole writer, on the main thread — builds
//! a complete fresh `Settings` per change and atomically swaps the pointer; every reader
//! acquire-loads once and reads fields off its coherent snapshot. Old snapshots are
//! intentionally never freed — and `std.zon.parse.free` must NOT be called on a parsed
//! `Settings`: fields omitted from the file keep their struct-default value, which
//! points at a static string literal, and `free` would fault trying to release it
//! (verified against this Zig nightly). That leak is also what makes a stale snapshot
//! held across a menu change (e.g. a Session keeping the old `model` pointer) safe.
//!
//! This module also owns the `config.zon` **write** path (wayfinder #32): a targeted
//! single-field textual patch that preserves comments and hand-formatting byte-for-byte,
//! with a full re-serialize only when the file is absent or malformed; both write
//! atomically (temp file + rename).

const std = @import("std");
const tap = @import("tap.zig");
const insert = @import("insert.zig");
/// Imported for one setter: `Store` publishes the log's transcript-redaction policy
/// (#250) as each snapshot goes live. This module's *own* messages stay on plain stderr
/// — they precede the running daemon, so they are not state transitions.
const feedback = @import("feedback.zig");
const keychain = @import("keychain.zig");
const backend = @import("transcription_backend.zig");
/// Imported for `scrub`: the migration's round-trip check reads the stored key back, and a
/// key copy this module makes owes the same zero-before-release the Key Holder gives its own.
const api_key = @import("api_key.zig");

/// Non-secret settings. The field names + types ARE the accepted `config.zon` schema
/// (std.zon parses the file straight into this struct). Every field has a default, so
/// an absent file — or an absent field — falls back cleanly.
///
/// `model`/`language`/`delay` are strings, not enums, on purpose: issue #11 wants to
/// A/B `gpt-4o-mini-transcribe` (and other language/delay values) by editing the file
/// alone, no rebuild. `talk_key`/`noise_reduction`/`insertion` are enums — a closed,
/// validated vocabulary the code switches on.
pub const Settings = struct {
    transcription_backend: backend.Backend = .openai,
    talk_key: tap.TalkKey = .right_option,
    /// Flipped to gpt-live-transcribe for 0.4.0 (#303, decision #299) on the A/B
    /// benchmark's accuracy win. An explicit `.model` pin is honored unchanged —
    /// pin "gpt-realtime-whisper" to keep the pre-0.4.0 behavior, no rebuild.
    model: []const u8 = "gpt-live-transcribe",
    language: []const u8 = "en",
    delay: []const u8 = "low",
    noise_reduction: NoiseReduction = .near_field,
    insertion: insert.Method = .paste,
    /// Pre-paste settle in milliseconds — the pause between writing the pasteboard and
    /// posting Cmd-V (paste insertion only; issue #37). The default suits native views,
    /// terminals and Electron; raise it (espanso used 100) if a slow target pastes the
    /// old clipboard. Hand-edit-only, like `delay = "xhigh"` — no menu group.
    pre_paste_ms: u32 = insert.default_pre_paste_ms,
    /// Show the live-partials overlay pill at the cursor (wayfinder #22). On by default;
    /// set `.overlay = false` for sound-only feedback. A headless run (no display) also
    /// degrades to sound-only on its own, so this never blocks startup.
    overlay: bool = true,
    /// Backtrack (docs/backtrack-spec.md): opt-in rewrite pass between the Final
    /// Transcript and its Insertion — spoken self-corrections applied, fillers removed,
    /// one OpenAI call. Transcript text leaves the Mac, so it applies only when the
    /// pinned backend is OpenAI; read at Talk Key press and pinned with the Lease.
    backtrack: bool = false,
    /// Custom vocabulary / phrase biasing (docs/vocab-biasing-spec.md §1): an opt-in,
    /// user-curated flat list of terms that nudges the recognizer's spelling. Default
    /// `&.{}` = "no biasing", mirroring how `language = ""` is the omission signal. The
    /// effect is local-Whisper-only and read at Talk Key press (pinned with the Lease);
    /// the list is structurally clamped at load (see `clampVocabulary`).
    vocabulary: []const []const u8 = &.{},
    /// Write the spoken words to the log, not just the fact that an Utterance resolved
    /// (#250). Off by default: `~/Library/Logs/type-wave.log` is unrotated, uncapped
    /// plaintext that the Status Item's Diagnostics action attaches to bug reports, so
    /// Partial and Final Transcripts reach it as a byte count instead. Turn it on to
    /// debug a transcription problem, then turn it off. Hand-edit-only like
    /// `pre_paste_ms` — a diagnostic escape hatch, not a product setting, so no menu
    /// group. The policy itself lives in feedback.zig; `Store` publishes it.
    log_transcripts: bool = false,

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

/// Structural pathology guards for a hand- or menu-edited vocabulary list
/// (docs/vocab-biasing-spec.md §1) — deliberately generous, larger than Whisper's
/// usable token budget so they never starve the (unlimited) OpenAI path. The real
/// per-backend token-budget truncation happens at prompt construction, not here.
/// Tunable.
const vocab_max_item_chars = 100;
const vocab_max_items = 128;

/// Load-/edit-time clamp (spec §1): drop items over the per-item char cap, blank or
/// whitespace-only items, and any beyond the whole-list cap (overflow tail). Order is
/// preserved and there is **no dedup** — a chopped or blank term biases toward a broken
/// fragment, so we drop whole items rather than truncate. Returns a freshly allocated
/// outer slice referencing the input's (leaked) string storage; the inner strings are
/// not copied. Null on OOM lets the caller keep the unclamped list.
///
/// Public so the menu's Save (spec §3) clamps the just-edited list through the exact same
/// structural rules as the load path — one authority for the 100-char / 128-item caps.
pub fn clampVocabulary(gpa: std.mem.Allocator, list: []const []const u8) ?[]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    errdefer kept.deinit(gpa);
    for (list) |item| {
        if (kept.items.len >= vocab_max_items) break; // whole-list cap — drop the tail
        if (item.len > vocab_max_item_chars) continue; // over the per-item char cap
        if (std.mem.trim(u8, item, " \t\r\n").len == 0) continue; // blank / whitespace-only
        kept.append(gpa, item) catch return null;
    }
    return kept.toOwnedSlice(gpa) catch null;
}

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
///
/// Mutable on purpose (#254): every caller owes the copy an `api_key.scrub` — a plaintext
/// key returned to the allocator un-zeroed outlives its use in the heap. The lifetime rule
/// itself is the Key Holder's (api_key.zig); this is only the read.
pub fn loadApiKeyOnly(io: std.Io, gpa: std.mem.Allocator) ?[:0]u8 {
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
    var parsed = std.zon.parse.fromSliceAlloc(Settings, gpa, src, &diag, .{}) catch {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        diag.format(&w) catch {};
        std.debug.print("config: {s} is malformed — using defaults.\n  {s}\n", .{ path, w.buffered() });
        return .{};
    };
    // Structural clamp of the vocabulary (spec §1): per-field and non-destructive — a
    // type mismatch already fell the whole file back to defaults above. On OOM keep the
    // parsed list as-is rather than lose the load. The old outer array leaks by design.
    if (clampVocabulary(gpa, parsed.vocabulary)) |clamped| parsed.vocabulary = clamped;
    return parsed;
}

/// The secret: process environment first (the dev override), then the keychain item.
/// A keychain miss falls through to the one-time env-file migration. Returns null only
/// when no source yields a key.
fn loadApiKey(io: std.Io, gpa: std.mem.Allocator) ?[:0]u8 {
    if (apiKeyFromEnv(gpa)) |key| return key;
    switch (keychain.readKey(gpa)) {
        .key => |key| {
            last_keychain_err = 0; // healthy again — a later failure re-logs
            // A legacy plaintext file beside a working keychain item is an *unfinished*
            // migration, not a second source: this arm is the one every already-migrated
            // machine takes, and it is the only place that ever sees them together (#282).
            retireLegacyEnvFile(io);
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

/// One-time migration (wayfinder #33, finished by #282): the keychain has no item, but the
/// retired `~/.config/type-wave/env` file may still hold the key from the pre-keychain era.
/// If it does, store it in the keychain, prove the keychain hands it back, take the plaintext
/// file off disk, and hand the key to this run. Once the store succeeds the keychain hit wins
/// every later lookup, so the file is never read again — that's what makes the migration
/// one-time, and it is exactly why the file has to go *now* rather than on a user's to-do
/// list: this code path is not coming back.
///
/// ACL note: the migrating process becomes the item's creator, so this is meant to run in
/// the installed signed daemon. Foreground dev runs export OPENAI_API_KEY and never get
/// here (the env override wins above).
fn migrateEnvFile(io: std.Io, gpa: std.mem.Allocator) ?[:0]u8 {
    const home = homeDir() orelse return null;
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, env_rel }) catch return null;

    var vault: LoginKeychain = .{};
    const attempt = migrateEnvFileAt(LoginKeychain, &vault, io, gpa, path);
    narrateMigration(attempt.outcome, path);
    return attempt.key;
}

/// The migration's seam onto the login keychain — the two calls it makes, asserted by name
/// here and invoked by `migrateEnvFileAt` itself, in the `grants.zig` / `undo.zig` idiom.
/// It exists so the **file** handling this module now owns can be driven against a fake:
/// Security.framework is unreachable from an unsigned test binary, and the decision that
/// matters (delete only on proof) has to be exercised on every arm, not just the happy one.
fn assertVault(comptime Vault: type) void {
    const required = [_][]const u8{ "storeKey", "readKey" };
    inline for (required) |name| {
        if (!@hasDecl(Vault, name))
            @compileError("type '" ++ @typeName(Vault) ++ "' is not a key Vault: missing method '" ++ name ++ "'");
    }
}

/// The production adapter: the real login keychain, stateless because `keychain.zig` is.
const LoginKeychain = struct {
    pub fn storeKey(_: *LoginKeychain, key: []const u8) keychain.OSStatus {
        return keychain.storeKey(key);
    }
    pub fn readKey(_: *LoginKeychain, gpa: std.mem.Allocator) keychain.ReadResult {
        return keychain.readKey(gpa);
    }
};

/// What one attempt at the migration achieved. Returned rather than logged so
/// `narrateMigration` is the single place any of it reaches the user, and so a test can
/// assert the outcome without reading stderr.
const Migration = struct {
    /// The key for this run, when the file yielded one — owned by the caller, which owes it
    /// an `api_key.scrub` (#254). Present even on the arms that failed to store it: the
    /// daemon should work today whatever the keychain did.
    key: ?[:0]u8 = null,
    outcome: Outcome,

    /// The whole decision table. Each arm is a different thing to tell the user, and — the
    /// point of the split — a different answer to *may the plaintext file go?*
    const Outcome = union(enum) {
        /// No legacy file (the normal case, and the state every machine ends in), or a file
        /// with no `OPENAI_API_KEY` assignment in it. Silent.
        nothing_to_migrate,
        /// The file is there but its key could not be lifted out of it. Nothing was stored
        /// and nothing was deleted.
        unreadable: anyerror,
        /// Stored, proved readable back, and the plaintext copy is off disk. Done, for good.
        completed,
        /// Stored and proved, but the file could not be removed — the one arm that leaves
        /// the user something to finish by hand, so it says so imperatively.
        file_stranded: anyerror,
        /// The store failed, so the keychain does not hold the key: the file stays, because
        /// it is the only copy we can prove exists. A later poll retries.
        store_failed: keychain.OSStatus,
        /// The store reported success but the key did not read back. Handled exactly like a
        /// failed store — the proof is what licenses the delete, not the report.
        unverified,
    };
};

fn migrateEnvFileAt(
    comptime Vault: type,
    vault: *Vault,
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) Migration {
    comptime assertVault(Vault);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file)) catch |failure| return switch (failure) {
        error.FileNotFound => .{ .outcome = .nothing_to_migrate },
        else => .{ .outcome = .{ .unreadable = failure } },
    };
    // The whole file is a key copy for as long as it is mapped: zero it before it goes
    // back to the allocator, exactly as the Key Holder does to the copies it owns (#254).
    defer {
        std.crypto.secureZero(u8, raw);
        gpa.free(raw);
    }
    const val = parseEnvKey(raw) orelse return .{ .outcome = .nothing_to_migrate };
    const key = gpa.dupeSentinel(u8, val, 0) catch return .{ .outcome = .{ .unreadable = error.OutOfMemory } };

    const st = vault.storeKey(key);
    if (st != keychain.errSecSuccess) return .{ .key = key, .outcome = .{ .store_failed = st } };
    if (!vaultHoldsKey(Vault, vault, gpa, key)) return .{ .key = key, .outcome = .unverified };

    // The file provably existed — it is what we just read the key out of — so "was there
    // anything to remove?" is not a question this path has.
    _ = removePlaintextKeyFile(io, path) catch |failure|
        return .{ .key = key, .outcome = .{ .file_stranded = failure } };
    return .{ .key = key, .outcome = .completed };
}

/// Prove the keychain hands back the very key we just stored. This is what licenses the
/// delete: `storeKey` reporting success is a claim, and the file is the only copy whose
/// existence we have checked ourselves. Comparing the bytes rather than merely counting a
/// hit also catches a store that landed on some other item.
///
/// The read is itself a plaintext copy of the secret, so it is scrubbed before release.
fn vaultHoldsKey(comptime Vault: type, vault: *Vault, gpa: std.mem.Allocator, key: [:0]const u8) bool {
    switch (vault.readKey(gpa)) {
        .key => |stored| {
            defer api_key.scrub(gpa, stored);
            return std.mem.eql(u8, stored, key);
        },
        .absent, .err => return false,
    }
}

/// Take the retired plaintext key file off disk: overwrite its bytes, then unlink it.
/// Returns whether there was a file to remove — `false` is the normal, quiet case.
///
/// The overwrite is **best effort and cannot be otherwise**. On APFS a write may land in
/// fresh blocks (copy-on-write) and an SSD's wear levelling can keep the old ones alive, so
/// no userland scrub can promise the bytes are unrecoverable — a backup already taken is
/// beyond reach either way. What it does buy is the thing the finding is actually about: the
/// live, readable copy that every process running as this user could simply `open` is gone.
/// So the overwrite never decides the outcome; only the unlink does.
fn removePlaintextKeyFile(io: std.Io, path: []const u8) !bool {
    scrub: {
        var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch break :scrub;
        defer file.close(io);
        const len = file.length(io) catch break :scrub;
        const zeros: [1024]u8 = @splat(0);
        var written: u64 = 0;
        while (written < len) {
            const n: usize = @intCast(@min(len - written, zeros.len));
            file.writePositionalAll(io, zeros[0..n], written) catch break :scrub;
            written += n;
        }
        file.sync(io) catch {};
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch |failure| switch (failure) {
        error.FileNotFound => return false,
        else => return failure,
    };
    return true;
}

/// The sweep is attempted at most once per process: the legacy file is a retired artifact
/// that cannot reappear, so one attempt is enough — and a failed one must not re-log every
/// 3 s tick. Atomic rather than a plain flag because `loadApiKey` is *not* single-threaded:
/// the supervisor's Key Holder poll and the Rewrite worker both reach it. A single `swap`
/// makes the attempt exactly-once with nothing left to reason about.
var legacy_sweep_attempted = std.atomic.Value(bool).init(false);

/// Finish a migration that already happened. Everyone who migrated under the old code has a
/// live API key sitting in cleartext at `~/.config/type-wave/env` right now, and `migrateEnvFile`
/// will never run for them again — the keychain hit wins first. This is that path's other
/// half: called only from the arm that has *positive proof* the keychain holds a key, so the
/// file we delete is provably redundant rather than merely presumed to be.
fn retireLegacyEnvFile(io: std.Io) void {
    if (legacy_sweep_attempted.swap(true, .monotonic)) return;
    const home = homeDir() orelse return;
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, env_rel }) catch return;

    // Never read the file: there is nothing in it we need, and reading would make one more
    // plaintext copy of the secret to have to scrub.
    if (removePlaintextKeyFile(io, path)) |removed| {
        if (removed) std.debug.print(
            "config: the login keychain holds the API key, so the retired {s} was removed — its plaintext copy is off disk.\n",
            .{path},
        );
    } else |failure| std.debug.print(
        "config: {s} still holds your API key in cleartext and could not be removed: {s} — delete it now: {s}\n",
        .{ path, @errorName(failure), path },
    );
}

/// Every word the migration says, in one place. The imperative on `file_stranded` is
/// deliberate: the old message told the user the file "can be deleted", which is how a live
/// key survives in cleartext for the life of a machine.
fn narrateMigration(outcome: Migration.Outcome, path: []const u8) void {
    switch (outcome) {
        .nothing_to_migrate => {},
        .unreadable => |failure| std.debug.print(
            "config: could not read {s}: {s}\n",
            .{ path, @errorName(failure) },
        ),
        .completed => std.debug.print(
            "config: migrated the API key from {s} into the login keychain and removed the file — its plaintext copy is off disk.\n",
            .{path},
        ),
        .file_stranded => |failure| std.debug.print(
            "config: migrated the API key from {s} into the login keychain, but could not remove the file: {s} — it still holds your key in cleartext. Delete it now: {s}\n",
            .{ path, @errorName(failure), path },
        ),
        .store_failed => |st| {
            var buf: [256]u8 = undefined;
            std.debug.print(
                "config: found the API key in {s} but storing it in the keychain failed: {s} — using it for this run; the file is left in place on purpose and migration will retry.\n",
                .{ path, keychain.describe(st, &buf) },
            );
        },
        .unverified => std.debug.print(
            "config: stored the API key from {s} in the keychain but could not read it back — the file is left in place on purpose and migration will retry.\n",
            .{path},
        ),
    }
}

fn apiKeyFromEnv(gpa: std.mem.Allocator) ?[:0]u8 {
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

// ============================================================================
// Live settings (wayfinder #32/#34): the snapshot store, the change diff, and
// the config.zon write path.
// ============================================================================

/// The immutable-snapshot pointer swap. One instance lives on the Daemon; the menu is
/// the only writer (main thread), every other thread reads via `current`. Snapshots
/// leak by design (see the module doc), so a reader may hold one indefinitely.
pub const Store = struct {
    ptr: std.atomic.Value(usize),

    pub fn init(first: *const Settings) Store {
        feedback.setLogTranscripts(first.log_transcripts);
        return .{ .ptr = std.atomic.Value(usize).init(@intFromPtr(first)) };
    }
    pub fn current(self: *Store) *const Settings {
        return @ptrFromInt(self.ptr.load(.acquire));
    }
    /// Publishes the log's redaction policy (#250) alongside the pointer, so `log_transcripts`
    /// binds through the one path every live snapshot already takes — no caller can swap in a
    /// snapshot and leave the log speaking the old policy. Published *before* the pointer, so a
    /// reader that can already see the new snapshot never logs under the old policy.
    pub fn swap(self: *Store, next: *const Settings) void {
        feedback.setLogTranscripts(next.log_transcripts);
        self.ptr.store(@intFromPtr(next), .release);
    }
};

/// What changed between two snapshots — drives what the swap must trigger: a
/// session-shaped change marks the Transcription Session dirty (idle reconnect), a
/// rebias change asks the warm OpenAI session for an idle keywords push (never a
/// cycle), an overlay change flips the HUD. Simple fields need nothing (read-at-use).
pub const Diff = struct {
    any: bool = false,
    backend_selection: bool = false,
    session_shaped: bool = false, // model / language / delay / noise_reduction
    /// vocabulary — read-at-use on both backends (never session-shaped), but the warm
    /// OpenAI session must re-bind its `keywords` via a session.update push at the next
    /// idle tick (openai-biasing-spec §1). The local path pins the list at press.
    rebias: bool = false,
    overlay: bool = false,
};

pub fn diffSettings(a: *const Settings, b: *const Settings) Diff {
    var d: Diff = .{};
    if (a.transcription_backend != b.transcription_backend) d.backend_selection = true;
    if (a.talk_key != b.talk_key) d.any = true;
    if (a.insertion != b.insertion) d.any = true;
    if (a.pre_paste_ms != b.pre_paste_ms) d.any = true;
    if (!std.mem.eql(u8, a.model, b.model)) d.session_shaped = true;
    if (!std.mem.eql(u8, a.language, b.language)) d.session_shaped = true;
    if (!std.mem.eql(u8, a.delay, b.delay)) d.session_shaped = true;
    if (a.noise_reduction != b.noise_reduction) d.session_shaped = true;
    if (a.overlay != b.overlay) d.overlay = true;
    if (a.backtrack != b.backtrack) d.any = true; // pinned at press with the Lease — read-at-use
    if (!vocabularyEql(a.vocabulary, b.vocabulary)) d.rebias = true; // never session-shaped: local reads at press, OpenAI re-binds via idle push
    if (a.log_transcripts != b.log_transcripts) d.any = true; // the swap itself republishes the log policy (#250)
    if (d.backend_selection or d.session_shaped or d.rebias or d.overlay) d.any = true;
    return d;
}

/// Element-wise string equality of two vocabulary lists (order-sensitive — the list is
/// flat with no weights, so order is meaningful and a reorder is a real change).
fn vocabularyEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Write one field into `config.zon` (wayfinder #32): read the file fresh (so a menu
/// write never clobbers a hand-edit elsewhere in it), patch just that field's value
/// textually, validate the result parses, and rename it into place. An absent or
/// malformed file — or a patch that somehow fails to validate — falls back to a full
/// re-serialize of `current` (which the caller has already updated with the new value).
/// Best-effort: failures are logged and the in-memory snapshot stays authoritative.
pub fn writeField(io: std.Io, gpa: std.mem.Allocator, field: []const u8, value: []const u8, current: Settings) bool {
    const home = homeDir() orelse return false;
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, config_rel }) catch return false;

    var text: ?[:0]const u8 = null;
    if (std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_file), .of(u8), 0)) |src| {
        if (patchZonField(gpa, src, field, value)) |patched| {
            if (zonValid(gpa, patched)) text = patched;
        }
    } else |_| {}
    if (text == null) {
        const full = serializeSettings(gpa, current) orelse return false;
        if (!zonValid(gpa, full)) {
            std.debug.print("config: refusing to write {s} — serialized settings did not validate\n", .{path});
            return false;
        }
        text = full;
    }
    if (!atomicWrite(io, path, text.?)) {
        std.debug.print("config: could not write {s} — the change applies live but is not persisted\n", .{path});
        return false;
    }
    return true;
}

/// Make sure `config.zon` exists (serializing the current snapshot if not) and return
/// its path in `buf` — the menu's "Open config file" needs a file to open on a
/// defaults-only install.
pub fn ensureConfigFile(io: std.Io, gpa: std.mem.Allocator, current: Settings, buf: []u8) ?[]const u8 {
    const home = homeDir() orelse return null;
    const path = std.fmt.bufPrint(buf, "{s}/{s}", .{ home, config_rel }) catch return null;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file))) |_| {
        return path;
    } else |_| {}
    const full = serializeSettings(gpa, current) orelse return null;
    if (!atomicWrite(io, path, full)) return null;
    return path;
}

const FieldSpan = struct { start: usize, end: usize };

/// Locate the value span of a top-level `.field = <value>` line. Comment lines are
/// skipped (the example file's header mentions field names in comments); a quoted value
/// ends at its closing quote (so a string holding a comma stays intact), anything else
/// ends before the `,` / a trailing `//` comment / end of line. The schema is a flat
/// struct of scalars, so line-granularity is the whole grammar this needs.
fn findZonField(src: []const u8, field: []const u8) ?FieldSpan {
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        defer offset += line.len + 1;
        const t = std.mem.trimStart(u8, line, " \t");
        if (t.len < 2 or t[0] != '.') continue; // blank, comment, brace, …
        const rest = t[1..];
        if (!std.mem.startsWith(u8, rest, field)) continue;
        const after = std.mem.trimStart(u8, rest[field.len..], " \t");
        if (after.len == 0 or after[0] != '=') continue; // a longer field name that merely prefixes ours

        const line_end = offset + line.len;
        // absolute index just past '='
        var vstart = line_end - after.len + 1;
        while (vstart < line_end and (src[vstart] == ' ' or src[vstart] == '\t')) vstart += 1;
        if (vstart >= line_end) return null; // value on the next line — not our flat schema
        var vend = vstart;
        if (src[vstart] == '"') {
            vend += 1;
            while (vend < line_end) : (vend += 1) {
                if (src[vend] == '\\') {
                    vend += 1;
                    continue;
                }
                if (src[vend] == '"') {
                    vend += 1;
                    break;
                }
            }
        } else if (src[vstart] == '.' and vstart + 1 < line_end and src[vstart + 1] == '{') {
            // Array literal `.{ ... }` (vocabulary, spec §1): scan to the matching '}'
            // on THIS line, tracking "…" so a string-internal comma or brace doesn't cut
            // the span. A multi-line hand-formatted array never closes on this line ⇒
            // return null ⇒ full re-serialize fallback (same as the next-line case above).
            vend += 2;
            var depth: usize = 1;
            var in_str = false;
            while (vend < line_end) : (vend += 1) {
                const c = src[vend];
                if (in_str) {
                    if (c == '\\') {
                        vend += 1;
                        continue;
                    }
                    if (c == '"') in_str = false;
                } else if (c == '"') {
                    in_str = true;
                } else if (c == '{') {
                    depth += 1;
                } else if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        vend += 1;
                        break;
                    }
                }
            }
            if (depth != 0) return null; // never closed on this line — multi-line array
        } else {
            while (vend < line_end) : (vend += 1) {
                const c = src[vend];
                if (c == ',') break;
                if (c == '/' and vend + 1 < line_end and src[vend + 1] == '/') break;
            }
            while (vend > vstart and (src[vend - 1] == ' ' or src[vend - 1] == '\t')) vend -= 1;
        }
        if (vend <= vstart) return null;
        return .{ .start = vstart, .end = vend };
    }
    return null;
}

/// Rewrite `.field`'s value to `value` in `src`, inserting `    .field = value,` before
/// the closing `}` when the field is absent. Everything else — comments, ordering,
/// hand-formatting — passes through byte-for-byte. Null when `src` has no top-level
/// struct to patch (the caller then falls back to a full re-serialize).
fn patchZonField(gpa: std.mem.Allocator, src: []const u8, field: []const u8, value: []const u8) ?[:0]u8 {
    if (findZonField(src, field)) |span| {
        const out = gpa.allocSentinel(u8, src.len - (span.end - span.start) + value.len, 0) catch return null;
        @memcpy(out[0..span.start], src[0..span.start]);
        @memcpy(out[span.start..][0..value.len], value);
        @memcpy(out[span.start + value.len ..], src[span.end..]);
        return out;
    }
    // Field absent: insert a fresh line before the line holding the final '}'.
    const close = std.mem.lastIndexOfScalar(u8, src, '}') orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..close], '\n')) |nl| nl + 1 else 0;
    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "    .{s} = {s},\n", .{ field, value }) catch return null;
    const out = gpa.allocSentinel(u8, src.len + line.len, 0) catch return null;
    @memcpy(out[0..line_start], src[0..line_start]);
    @memcpy(out[line_start..][0..line.len], line);
    @memcpy(out[line_start + line.len ..], src[line_start..]);
    return out;
}

/// The full-file fallback: every field from `s`, under a generated header naming the
/// accepted values (the file may be the user's first sight of the schema). Built
/// *allocatingly* — a maxed-out `vocabulary` (128 × ~100 chars ≈ 12.8 KB) overflows any
/// fixed stack buffer, which would `error.NoSpaceLeft` and null the whole serialize.
fn serializeSettings(gpa: std.mem.Allocator, s: Settings) ?[:0]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    const w = &out.writer;
    serializeInto(w, s) catch return null;
    return gpa.dupeSentinel(u8, out.written(), 0) catch null;
}

/// The shared writer body behind `serializeSettings`: header comment, then every field,
/// then the vocabulary array and the closing brace. Split out so it can stream into any
/// `std.Io.Writer` (the allocating one above).
fn serializeInto(w: *std.Io.Writer, s: Settings) std.Io.Writer.Error!void {
    try w.print(
        \\// type-wave settings. Hand-edit freely — the menu bar rewrites single fields in
        \\// place and picks hand-edits up when the menu opens (or on restart). This full
        \\// version was generated because the file was absent or malformed.
        \\//
        \\//   .talk_key        = .right_option | .left_option | .globe
        \\//   .transcription_backend = .openai | .local  (.local = pinned offline Whisper model)
        \\//   .model           = "<transcription model>"
        \\//   .language        = "<ISO code>"  ("" = auto-detect)
        \\//   .delay           = "minimal" | "low" | "medium" | "high" | "xhigh"
        \\//   .noise_reduction = .near_field | .far_field | .off
        \\//   .insertion       = .paste | .keystroke  (.paste transits the general pasteboard for ~300ms, readable session-wide; .keystroke never does — SECURITY.md)
        \\//   .pre_paste_ms    = <ms between the pasteboard write and Cmd-V; raise for a slow target>
        \\//   .overlay         = true | false
        \\//   .backtrack       = true | false  (rewrite self-corrections via OpenAI — transcript text leaves your Mac)
        \\//   .log_transcripts = true | false  (log the spoken words, not just that an Utterance resolved — off: the log is unrotated plaintext)
        \\//   .vocabulary      = .{{ "term", ... }}  (local-Whisper-only phrase biasing; empty = off)
        \\.{{
        \\    .transcription_backend = .{s},
        \\    .talk_key = .{s},
        \\    .model = "{s}",
        \\    .language = "{s}",
        \\    .delay = "{s}",
        \\    .noise_reduction = .{s},
        \\    .insertion = .{s},
        \\    .pre_paste_ms = {d},
        \\    .overlay = {},
        \\    .backtrack = {},
        \\    .log_transcripts = {},
        \\
    , .{
        @tagName(s.transcription_backend), @tagName(s.talk_key),  s.model,        s.language, s.delay,
        @tagName(s.noise_reduction),       @tagName(s.insertion), s.pre_paste_ms, s.overlay,
        s.backtrack,                       s.log_transcripts,
    });
    try serializeVocabulary(w, s.vocabulary);
    try w.writeAll("}\n");
}

/// Emit the vocabulary always on one line — `.vocabulary = .{},` when empty (keeps the
/// feature discoverable in the generated file), else `.vocabulary = .{ "a", "b" },`.
/// The single-line form is what `findZonField`'s quote-aware array patch expects.
fn serializeVocabulary(w: *std.Io.Writer, vocab: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("    .vocabulary = ");
    try writeVocabularyValue(w, vocab);
    try w.writeAll(",\n");
}

/// The array *value* alone — `.{}` when empty, else `.{ "a", "b" }` — with no field name,
/// indent, or trailing comma. The single-line, quote-aware shape `findZonField`'s array
/// patch expects. Shared by the full-file serializer above and the menu's field-patch.
fn writeVocabularyValue(w: *std.Io.Writer, vocab: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll(".{");
    for (vocab, 0..) |item, i| {
        try w.writeAll(if (i == 0) " " else ", ");
        try writeZonString(w, item);
    }
    try w.writeAll(if (vocab.len == 0) "}" else " }");
}

/// Serialize a vocabulary list to the ZON array value the menu hands `writeField` on Save
/// (spec §3) — `.{}` / `.{ "a", "b" }`, one line, escaped, caller-owned (NUL-terminated so
/// it drops straight into an ObjC string too). Null on OOM. Single-homes the value format
/// and escaping with the full-file serializer via `writeVocabularyValue`.
pub fn serializeVocabularyValue(gpa: std.mem.Allocator, vocab: []const []const u8) ?[:0]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    writeVocabularyValue(&out.writer, vocab) catch return null;
    return gpa.dupeSentinel(u8, out.written(), 0) catch null;
}

/// Write `s` as a ZON string literal, escaping so an item holding a quote, backslash or
/// control byte round-trips through the parser (the load-time clamp bounds length, not
/// content). Mirrors Zig string-literal escaping.
fn writeZonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\x{x:0>2}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Does this text parse back into `Settings`? The guard that keeps a bad patch (or a
/// pathological string value) from ever landing in the file.
fn zonValid(gpa: std.mem.Allocator, text: [:0]const u8) bool {
    var diag: std.zon.parse.Diagnostics = .{};
    _ = std.zon.parse.fromSliceAlloc(Settings, gpa, text, &diag, .{}) catch return false;
    return true;
}

/// Temp-file-then-rename in the same directory. Single writer (the main thread), so
/// the fixed temp name cannot race itself.
fn atomicWrite(io: std.Io, path: []const u8, data: []const u8) bool {
    var tmp_buf: [4096 + 8]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return false;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data }) catch return false;
    std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io) catch return false;
    return true;
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

// ---- env-file migration: the plaintext key comes off disk (#282) ---------------

const legacy_key = "sk-legacy-0123456789";

/// Stands in for the login keychain so every arm of the migration's decision table can be
/// driven from a test. `store_status` fails the store outright; `swallow` makes a store
/// report success while holding nothing — the arm where the report is a lie, and the one
/// that proves the delete follows the round-trip rather than the return code.
const FakeVault = struct {
    stored: ?[]u8 = null,
    store_status: keychain.OSStatus = keychain.errSecSuccess,
    swallow: bool = false,

    /// SecBase.h's errSecAllocate, the status keychain.zig reports for a failed copy.
    const alloc_failed: keychain.OSStatus = -108;

    fn deinit(self: *FakeVault) void {
        if (self.stored) |held| talloc.free(held);
        self.stored = null;
    }

    pub fn storeKey(self: *FakeVault, key: []const u8) keychain.OSStatus {
        if (self.store_status != keychain.errSecSuccess) return self.store_status;
        if (self.swallow) return keychain.errSecSuccess;
        self.deinit();
        self.stored = talloc.dupe(u8, key) catch return alloc_failed;
        return keychain.errSecSuccess;
    }

    pub fn readKey(self: *FakeVault, gpa: std.mem.Allocator) keychain.ReadResult {
        const held = self.stored orelse return .absent;
        return .{ .key = gpa.dupeSentinel(u8, held, 0) catch return .{ .err = alloc_failed } };
    }
};

/// Write `contents` to `<tmp>/env` and return its absolute path: the migration takes a path,
/// so none of this needs a real `$HOME` or the real keychain.
fn writeLegacyEnvFile(tmp: *std.testing.TmpDir, buf: []u8, contents: []const u8) ![]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "env", .data = contents });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    return std.fmt.bufPrint(buf, "{s}/env", .{root_buf[0..root_len]});
}

fn expectOutcome(want: std.meta.Tag(Migration.Outcome), attempt: Migration) !void {
    try std.testing.expectEqual(want, std.meta.activeTag(attempt.outcome));
}

test "a completed migration takes the plaintext key off disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeLegacyEnvFile(&tmp, &path_buf, "export OPENAI_API_KEY=" ++ legacy_key ++ "\n");
    var vault: FakeVault = .{};
    defer vault.deinit();

    const attempt = migrateEnvFileAt(FakeVault, &vault, std.testing.io, talloc, path);
    defer api_key.scrub(talloc, attempt.key.?);

    try expectOutcome(.completed, attempt);
    try std.testing.expectEqualStrings(legacy_key, attempt.key.?); // this run still works
    try std.testing.expectEqualStrings(legacy_key, vault.stored.?);
    // The whole point: the next poll takes the ordinary FileNotFound path, forever.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "env", .{}));
}

test "a failed store leaves the plaintext file exactly where it was" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original = "OPENAI_API_KEY=" ++ legacy_key ++ "\n";
    const path = try writeLegacyEnvFile(&tmp, &path_buf, original);
    // A locked keychain: the status that must never be read as a cue to change anything.
    var vault: FakeVault = .{ .store_status = keychain.errSecInteractionNotAllowed };
    defer vault.deinit();

    const attempt = migrateEnvFileAt(FakeVault, &vault, std.testing.io, talloc, path);
    defer api_key.scrub(talloc, attempt.key.?);

    try expectOutcome(.store_failed, attempt);
    try std.testing.expectEqualStrings(legacy_key, attempt.key.?); // the daemon works today
    var read_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(original, try tmp.dir.readFile(std.testing.io, "env", &read_buf));
}

test "a store that does not read back does not license the delete" {
    // The finding's inverse hazard: deleting the only copy we can prove exists, on the
    // strength of a return code. `storeKey` says success and the item is not there.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original = "OPENAI_API_KEY=" ++ legacy_key ++ "\n";
    const path = try writeLegacyEnvFile(&tmp, &path_buf, original);
    var vault: FakeVault = .{ .swallow = true };
    defer vault.deinit();

    const attempt = migrateEnvFileAt(FakeVault, &vault, std.testing.io, talloc, path);
    defer api_key.scrub(talloc, attempt.key.?);

    try expectOutcome(.unverified, attempt);
    var read_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(original, try tmp.dir.readFile(std.testing.io, "env", &read_buf));
}

test "a file that cannot be removed is reported as stranded, and its bytes are gone anyway" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root unlinks out of any directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeLegacyEnvFile(&tmp, &path_buf, "OPENAI_API_KEY=" ++ legacy_key ++ "\n");
    var vault: FakeVault = .{};
    defer vault.deinit();

    // An unlink needs write permission on the *directory*; the file itself stays writable, so
    // the overwrite lands and only the unlink fails. Restored before cleanup runs (LIFO).
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir_path = dir_buf[0..dir_len];
    try std.Io.Dir.cwd().setFilePermissions(std.testing.io, dir_path, .fromMode(0o500), .{});
    defer std.Io.Dir.cwd().setFilePermissions(std.testing.io, dir_path, .fromMode(0o700), .{}) catch {};

    const attempt = migrateEnvFileAt(FakeVault, &vault, std.testing.io, talloc, path);
    defer api_key.scrub(talloc, attempt.key.?);

    try expectOutcome(.file_stranded, attempt);
    try std.testing.expectEqualStrings(legacy_key, vault.stored.?); // the keychain copy is good
    // The overwrite is best effort against the storage layer, but it is not best effort
    // against `cat`: whatever is still at that path no longer reads as the key.
    var read_buf: [128]u8 = undefined;
    const left = try tmp.dir.readFile(std.testing.io, "env", &read_buf);
    try std.testing.expect(std.mem.indexOf(u8, left, legacy_key) == null);
    for (left) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a file with no key assignment in it is not ours to delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original = "# migrated long ago\nSOMETHING_ELSE=1\n";
    const path = try writeLegacyEnvFile(&tmp, &path_buf, original);
    var vault: FakeVault = .{};
    defer vault.deinit();

    const attempt = migrateEnvFileAt(FakeVault, &vault, std.testing.io, talloc, path);

    try expectOutcome(.nothing_to_migrate, attempt);
    try std.testing.expect(attempt.key == null);
    var read_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(original, try tmp.dir.readFile(std.testing.io, "env", &read_buf));
}

test "the migration stays one-time and idempotent: a missing file is the silent normal case" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/env", .{root_buf[0..root_len]});
    var vault: FakeVault = .{};
    defer vault.deinit();

    try expectOutcome(.nothing_to_migrate, migrateEnvFileAt(FakeVault, &vault, std.testing.io, talloc, path));
    // And the sweep that finishes an already-done migration says nothing when there is
    // nothing there — it runs on every start of every already-migrated machine.
    try std.testing.expect(!try removePlaintextKeyFile(std.testing.io, path));
}

test "the sweep removes a stranded file left beside a working keychain item" {
    // Everyone who migrated under the old code is in exactly this state: the keychain holds
    // the key, so `migrateEnvFile` never runs again, and the plaintext copy stays forever.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeLegacyEnvFile(&tmp, &path_buf, "OPENAI_API_KEY=" ++ legacy_key ++ "\n");

    try std.testing.expect(try removePlaintextKeyFile(std.testing.io, path));

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "env", .{}));
}

// ---- config.zon patcher tests (wayfinder #34) ---------------------------------

const talloc = std.testing.allocator;

fn expectPatch(src: []const u8, field: []const u8, value: []const u8, want: []const u8) !void {
    const got = patchZonField(talloc, src, field, value) orelse return error.PatchReturnedNull;
    defer talloc.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "patchZonField rewrites an enum value in place" {
    try expectPatch(
        ".{\n    .talk_key = .right_option,\n    .overlay = true,\n}\n",
        "talk_key",
        ".left_option",
        ".{\n    .talk_key = .left_option,\n    .overlay = true,\n}\n",
    );
}

test "patchZonField preserves comments — including ones naming other fields" {
    const src =
        \\// header: set .model = "gpt-4o-mini-transcribe" to A/B (comment must survive)
        \\.{
        \\    // which held key starts an Utterance
        \\    .talk_key = .right_option, // trailing note
        \\    .model = "gpt-realtime-whisper",
        \\}
        \\
    ;
    const want =
        \\// header: set .model = "gpt-4o-mini-transcribe" to A/B (comment must survive)
        \\.{
        \\    // which held key starts an Utterance
        \\    .talk_key = .right_option, // trailing note
        \\    .model = "gpt-4o-mini-transcribe",
        \\}
        \\
    ;
    try expectPatch(src, "model", "\"gpt-4o-mini-transcribe\"", want);
}

test "patchZonField handles a quoted value containing a comma" {
    try expectPatch(
        ".{\n    .language = \"en,sv\",\n}\n",
        "language",
        "\"en\"",
        ".{\n    .language = \"en\",\n}\n",
    );
}

test "patchZonField inserts an absent field before the closing brace" {
    try expectPatch(
        ".{\n    .talk_key = .right_option,\n}\n",
        "overlay",
        "false",
        ".{\n    .talk_key = .right_option,\n    .overlay = false,\n}\n",
    );
}

test "patchZonField does not confuse a longer field name for a prefix" {
    // patching "delay" must not touch a hypothetical ".delay_extra"
    try expectPatch(
        ".{\n    .delay_extra = \"x\",\n    .delay = \"low\",\n}\n",
        "delay",
        "\"high\"",
        ".{\n    .delay_extra = \"x\",\n    .delay = \"high\",\n}\n",
    );
}

test "serializeSettings round-trips through the ZON parser" {
    const s = Settings{ .transcription_backend = .local, .talk_key = .left_option, .language = "", .delay = "high", .overlay = false, .pre_paste_ms = 42, .backtrack = true, .log_transcripts = true };
    const text = serializeSettings(talloc, s) orelse return error.SerializeFailed;
    defer talloc.free(text);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(talloc);
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, talloc, text, &diag, .{});
    // free the parsed strings (all fields present in the file, so no static defaults)
    defer std.zon.parse.free(talloc, parsed);
    try std.testing.expectEqual(Settings.NoiseReduction.near_field, parsed.noise_reduction);
    try std.testing.expectEqual(@import("transcription_backend.zig").Backend.local, parsed.transcription_backend);
    try std.testing.expectEqual(tap.TalkKey.left_option, parsed.talk_key);
    try std.testing.expectEqualStrings("", parsed.language);
    try std.testing.expect(!parsed.overlay);
    try std.testing.expectEqual(@as(u32, 42), parsed.pre_paste_ms);
    try std.testing.expect(parsed.backtrack);
    try std.testing.expect(parsed.log_transcripts);
    // The generated header is where a hand-editor discovers a setting with no menu group.
    try std.testing.expect(std.mem.indexOf(u8, text, "//   .log_transcripts =") != null);
}

test "log_transcripts parses from config.zon and defaults to redacted when absent" {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(talloc);
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, talloc, ".{ .log_transcripts = true }", &diag, .{});
    try std.testing.expect(parsed.log_transcripts);
    try std.testing.expect(!(Settings{}).log_transcripts); // the log carries no words by default
}

test "a Store swap republishes the log's redaction policy (#250)" {
    const saved = feedback.logTranscripts();
    defer feedback.setLogTranscripts(saved);

    const quiet = Settings{};
    var store = Store.init(&quiet);
    try std.testing.expect(!feedback.logTranscripts()); // the first snapshot binds at init

    const verbose = Settings{ .log_transcripts = true };
    store.swap(&verbose);
    try std.testing.expect(feedback.logTranscripts()); // …and every later one binds at swap

    store.swap(&quiet);
    try std.testing.expect(!feedback.logTranscripts());
}

test "diffSettings flags a log_transcripts change as plain (the swap republishes it)" {
    const base = Settings{};
    var b = base;
    b.log_transcripts = true;
    const d = diffSettings(&base, &b);
    try std.testing.expect(d.any and !d.session_shaped and !d.overlay and !d.backend_selection and !d.rebias);
}

test "backtrack parses from config.zon and defaults off when absent" {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(talloc);
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, talloc, ".{ .backtrack = true }", &diag, .{});
    try std.testing.expect(parsed.backtrack);
    try std.testing.expect(!(Settings{}).backtrack);
}

test "diffSettings flags a backtrack change as plain (pinned at press with the Lease)" {
    const base = Settings{};
    var b = base;
    b.backtrack = true;
    const d = diffSettings(&base, &b);
    try std.testing.expect(d.any and !d.session_shaped and !d.overlay and !d.backend_selection and !d.rebias);
}

test "OpenAI is the default Transcription Backend when config omits selection" {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(talloc);
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, talloc, ".{}", &diag, .{});
    try std.testing.expectEqual(@import("transcription_backend.zig").Backend.openai, parsed.transcription_backend);
}

test "pre_paste_ms parses from config.zon and defaults when absent" {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(talloc);
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, talloc, ".{ .pre_paste_ms = 100 }", &diag, .{});
    try std.testing.expectEqual(@as(u32, 100), parsed.pre_paste_ms);
    try std.testing.expectEqual(insert.default_pre_paste_ms, (Settings{}).pre_paste_ms);
}

test "diffSettings flags a pre_paste_ms change as plain (read-at-use)" {
    const base = Settings{};
    var b = base;
    b.pre_paste_ms = base.pre_paste_ms + 10;
    const d = diffSettings(&base, &b);
    try std.testing.expect(d.any and !d.session_shaped and !d.overlay);
}

// ---- vocabulary: schema, load-time clamp, round-trip (wayfinder #171) ----------

/// Test helper: assert `text` parses back into `Settings`, freeing every allocation via
/// an arena. (`std.zon.parse.free` must not be called on a partial file — omitted fields
/// keep static-default string pointers that `free` would fault on; see the module doc.
/// `zonValid` leaks under the testing allocator for the same reason it leaks in prod.)
fn expectZonParses(text: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    _ = std.zon.parse.fromSliceAlloc(Settings, arena.allocator(), text, &diag, .{}) catch
        return error.ZonDidNotParse;
}

/// Test-only: a `[]const u8` of `n` copies of `c`, built at comptime (avoids the `**`
/// repeat operator, which this Zig's ast-check rejects on a string operand). The array
/// lives in a struct-const so it has static storage the returned slice can point at.
fn repeated(comptime c: u8, comptime n: usize) []const u8 {
    return &(struct {
        const arr = blk: {
            var b: [n]u8 = undefined;
            @memset(&b, c);
            break :blk b;
        };
    }).arr;
}

test "vocabulary parses from config.zon and defaults empty when absent" {
    var arena = std.heap.ArenaAllocator.init(talloc); // partial file → no manual free
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, arena.allocator(), ".{ .vocabulary = .{ \"type-wave\", \"whisper.cpp\" } }", &diag, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.vocabulary.len);
    try std.testing.expectEqualStrings("type-wave", parsed.vocabulary[0]);
    try std.testing.expectEqualStrings("whisper.cpp", parsed.vocabulary[1]);
    try std.testing.expectEqual(@as(usize, 0), (Settings{}).vocabulary.len);
}

test "clampVocabulary drops over-cap, blank and whitespace-only items; preserves order; no dedup" {
    const long = repeated('x', vocab_max_item_chars + 1);
    const ok = repeated('y', vocab_max_item_chars); // exactly at the cap survives
    const list = [_][]const u8{ "type-wave", long, "", "   \t", ok, "type-wave" };
    const clamped = clampVocabulary(talloc, &list) orelse return error.OutOfMemory;
    defer talloc.free(clamped);
    try std.testing.expectEqual(@as(usize, 3), clamped.len);
    try std.testing.expectEqualStrings("type-wave", clamped[0]);
    try std.testing.expectEqualStrings(ok, clamped[1]); // 100-char item kept intact
    try std.testing.expectEqualStrings("type-wave", clamped[2]); // duplicate kept — no dedup
}

test "clampVocabulary drops the overflow tail beyond the whole-list cap" {
    var backing: [vocab_max_items + 10][]const u8 = undefined;
    for (&backing, 0..) |*slot, i| slot.* = if (i % 2 == 0) "aa" else "bb";
    const clamped = clampVocabulary(talloc, &backing) orelse return error.OutOfMemory;
    defer talloc.free(clamped);
    try std.testing.expectEqual(@as(usize, vocab_max_items), clamped.len);
}

test "serializeVocabularyValue emits the bare array the menu patch feeds writeField" {
    const empty = serializeVocabularyValue(talloc, &.{}) orelse return error.SerializeFailed;
    defer talloc.free(empty);
    try std.testing.expectEqualStrings(".{}", empty);

    const populated = serializeVocabularyValue(talloc, &.{ "type-wave", "whisper.cpp" }) orelse return error.SerializeFailed;
    defer talloc.free(populated);
    try std.testing.expectEqualStrings(".{ \"type-wave\", \"whisper.cpp\" }", populated);

    // A value carrying a quote/backslash stays escaped so the patched file re-parses.
    const tricky = serializeVocabularyValue(talloc, &.{"a\"b\\c"}) orelse return error.SerializeFailed;
    defer talloc.free(tricky);
    try std.testing.expectEqualStrings(".{ \"a\\\"b\\\\c\" }", tricky);
}

test "serializeSettings writes an empty vocabulary explicitly and round-trips" {
    const text = serializeSettings(talloc, Settings{}) orelse return error.SerializeFailed;
    defer talloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".vocabulary = .{},") != null);
    try expectZonParses(text);
}

test "serializeSettings emits a populated vocabulary on one line and round-trips" {
    const s = Settings{ .vocabulary = &.{ "type-wave", "whisper.cpp" } };
    const text = serializeSettings(talloc, s) orelse return error.SerializeFailed;
    defer talloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".vocabulary = .{ \"type-wave\", \"whisper.cpp\" },") != null);
    try expectZonParses(text);
}

test "serializeSettings survives a maxed-out vocabulary (no fixed-buffer overflow)" {
    const item = repeated('z', vocab_max_item_chars);
    var backing: [vocab_max_items][]const u8 = undefined;
    for (&backing) |*slot| slot.* = item;
    const s = Settings{ .vocabulary = &backing };
    const text = serializeSettings(talloc, s) orelse return error.SerializeFailed;
    defer talloc.free(text);
    try std.testing.expect(text.len > 4096); // would have overflowed the old [4096]u8 buffer
    try expectZonParses(text);
}

test "writeZonString escapes quotes and backslashes so the item round-trips" {
    const s = Settings{ .vocabulary = &.{"a\"b\\c"} };
    const text = serializeSettings(talloc, s) orelse return error.SerializeFailed;
    defer talloc.free(text);
    var arena = std.heap.ArenaAllocator.init(talloc); // full file, but arena keeps it simple
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    const parsed = try std.zon.parse.fromSliceAlloc(Settings, arena.allocator(), text, &diag, .{});
    try std.testing.expectEqualStrings("a\"b\\c", parsed.vocabulary[0]);
}

test "patchZonField rewrites a single-line vocabulary array, preserving comments" {
    const src =
        \\// header comment must survive
        \\.{
        \\    .talk_key = .right_option,
        \\    .vocabulary = .{ "old" }, // trailing note survives
        \\    .overlay = true,
        \\}
        \\
    ;
    const want =
        \\// header comment must survive
        \\.{
        \\    .talk_key = .right_option,
        \\    .vocabulary = .{ "type-wave", "whisper.cpp" }, // trailing note survives
        \\    .overlay = true,
        \\}
        \\
    ;
    try expectPatch(src, "vocabulary", ".{ \"type-wave\", \"whisper.cpp\" }", want);
}

test "patchZonField: an array value's inner comma does not cut the span" {
    // A naive scan-to-first-comma would truncate after "a"; the quote-/brace-aware scan
    // must consume the whole `.{ ... }` before the `,`.
    try expectPatch(
        ".{\n    .vocabulary = .{ \"a\", \"b, c\" },\n    .overlay = true,\n}\n",
        "overlay",
        "false",
        ".{\n    .vocabulary = .{ \"a\", \"b, c\" },\n    .overlay = false,\n}\n",
    );
}

test "findZonField returns null on a multi-line vocabulary array (full re-serialize fallback)" {
    // The single-line patch deliberately cannot handle a hand-formatted multi-line array:
    // the value opens with `.{` but never closes on its line, so findZonField returns null
    // and writeField falls back to a full re-serialize instead of corrupting the file.
    const src =
        \\.{
        \\    .vocabulary = .{
        \\        "type-wave",
        \\        "whisper.cpp",
        \\    },
        \\}
        \\
    ;
    try std.testing.expect(findZonField(src, "vocabulary") == null);
}

test "diffSettings flags a vocabulary change as rebias (never session-shaped)" {
    const base = Settings{};
    var b = base;
    b.vocabulary = &.{"type-wave"};
    const d = diffSettings(&base, &b);
    try std.testing.expect(d.any and d.rebias and !d.session_shaped and !d.overlay and !d.backend_selection);
    // an identical list is not a change
    var c = base;
    c.vocabulary = &.{};
    try std.testing.expect(!diffSettings(&base, &c).any);
    // order matters — a reorder is a real change (the flat list has no weights)
    const e = Settings{ .vocabulary = &.{ "a", "b" } };
    const f = Settings{ .vocabulary = &.{ "b", "a" } };
    const g = diffSettings(&e, &f);
    try std.testing.expect(g.any and g.rebias);
}

test "diffSettings flags session-shaped and overlay changes" {
    const base = Settings{};
    var b = base;
    try std.testing.expect(!diffSettings(&base, &b).any);
    b.language = "sv";
    var d = diffSettings(&base, &b);
    try std.testing.expect(d.any and d.session_shaped and !d.overlay and !d.rebias);
    b = base;
    b.overlay = false;
    d = diffSettings(&base, &b);
    try std.testing.expect(d.any and !d.session_shaped and d.overlay and !d.rebias);
    b = base;
    b.transcription_backend = .local;
    d = diffSettings(&base, &b);
    try std.testing.expect(d.any and d.backend_selection and !d.session_shaped and !d.overlay and !d.rebias);
    b = base;
    b.talk_key = .globe;
    d = diffSettings(&base, &b);
    try std.testing.expect(d.any and !d.session_shaped and !d.overlay and !d.rebias);
}
