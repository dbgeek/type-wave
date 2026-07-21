//! receipt.zig — the Installation Receipt codec.
//!
//! Pure, allocation-free serialization of a Model Installation's on-disk identity-and-
//! provenance record. It owns three sibling formats that share one `key=value\n` line
//! grammar:
//!
//!   - the Installation Receipt (`active.receipt`, mirrored byte-for-byte in `PROVENANCE`):
//!     schema 2 (immutable) / schema 3 (generation) on write, schema 1 (legacy) parse-only,
//!   - `MODEL_MANIFEST` (size + sha256): reuses `artifact_identity`,
//!   - `partial.meta` (the resume record): its own, unrelated `schema=1`.
//!
//! Records borrow their string fields from the caller's text buffer; `encode` writes into a
//! caller-provided buffer. No allocator and no I/O cross this seam — model_store owns every
//! readFile/writeFile/rename/sync, the `Manifest -> Identity` mapping, the resume `Validator`
//! selection, and the trust-list policy (`which of my trusted manifests does this match?`).

const std = @import("std");
const artifact_identity = @import("artifact_identity.zig");

pub const ArtifactIdentity = artifact_identity.Identity;

/// A complete model identity, built by model_store from a `Manifest` at the seam. It is the
/// expected side of every match — every field is present.
pub const Identity = struct {
    repository: []const u8,
    revision: []const u8,
    runtime: []const u8,
    artifact: []const u8,
    installation_id: []const u8,
    size: u64,
    sha256: [32]u8,
};

pub const Schema = enum { legacy, immutable, generation };

/// A parsed Installation Receipt. String fields borrow from the text passed to `parse`.
pub const Receipt = struct {
    schema: Schema,
    repository: ?[]const u8,
    revision: ?[]const u8,
    runtime: ?[]const u8,
    artifact: []const u8,
    installation_id: ?[]const u8,
    directory_id: ?[]const u8,
    identity: ArtifactIdentity,
    runtime_sha256: [32]u8,
    mtime_ns: i96,
    installed_by: ?[]const u8,

    /// Read a receipt. Requires `schema`, `artifact` (safe), the size/sha256 identity, a
    /// `model_mtime_ns`, and a valid `runtime_sha256`; schema >= 2 also requires a safe
    /// `installation_id`, schema 3 a safe `directory_id`. `repository`/`revision`/`runtime`/
    /// `installed_by` are captured when present but never gate the parse — `matches` and the
    /// identity readers decide what a missing one means, exactly as the field-by-field inline
    /// reads did before.
    pub fn parse(text: []const u8) ?Receipt {
        const schema_text = value(text, "schema=") orelse return null;
        const artifact = value(text, "artifact=") orelse return null;
        if (!safePathComponent(artifact)) return null;
        const identity = artifact_identity.parse(text) catch return null;
        const mtime_ns = std.fmt.parseInt(i96, value(text, "model_mtime_ns=") orelse return null, 10) catch return null;
        const runtime_sha256 = runtimeDigest(text) orelse return null;
        const repository = value(text, "repository=");
        const revision = value(text, "revision=");
        const runtime = value(text, "runtime=");
        const installed_by = value(text, "installed_by=");
        if (std.mem.eql(u8, schema_text, "1")) return .{
            .schema = .legacy,
            .repository = repository,
            .revision = revision,
            .runtime = runtime,
            .artifact = artifact,
            .installation_id = null,
            .directory_id = null,
            .identity = identity,
            .runtime_sha256 = runtime_sha256,
            .mtime_ns = mtime_ns,
            .installed_by = installed_by,
        };
        const installation_id = value(text, "installation_id=") orelse return null;
        if (!safePathComponent(installation_id)) return null;
        if (std.mem.eql(u8, schema_text, "2")) return .{
            .schema = .immutable,
            .repository = repository,
            .revision = revision,
            .runtime = runtime,
            .artifact = artifact,
            .installation_id = installation_id,
            .directory_id = installation_id,
            .identity = identity,
            .runtime_sha256 = runtime_sha256,
            .mtime_ns = mtime_ns,
            .installed_by = installed_by,
        };
        if (!std.mem.eql(u8, schema_text, "3")) return null;
        const directory_id = value(text, "directory_id=") orelse return null;
        if (!safePathComponent(directory_id)) return null;
        return .{
            .schema = .generation,
            .repository = repository,
            .revision = revision,
            .runtime = runtime,
            .artifact = artifact,
            .installation_id = installation_id,
            .directory_id = directory_id,
            .identity = identity,
            .runtime_sha256 = runtime_sha256,
            .mtime_ns = mtime_ns,
            .installed_by = installed_by,
        };
    }

    /// Does this receipt authenticate against `expected`? A legacy receipt has no
    /// `installation_id` and matches on the rest; a missing `repository`/`revision`/`runtime`
    /// is a non-match. Size and digest compare by value.
    pub fn matches(self: Receipt, expected: Identity) bool {
        const installation_ok = self.schema == .legacy or
            (self.installation_id != null and std.mem.eql(u8, self.installation_id.?, expected.installation_id));
        return installation_ok and
            presentEql(self.repository, expected.repository) and
            presentEql(self.revision, expected.revision) and
            presentEql(self.runtime, expected.runtime) and
            std.mem.eql(u8, self.artifact, expected.artifact) and
            self.identity.size == expected.size and
            std.mem.eql(u8, &self.identity.sha256, &expected.sha256);
    }
};

/// The write side of the Installation Receipt: the inputs needed to serialize `active.receipt`
/// / `PROVENANCE`. A present `directory_id` selects schema 3, its absence schema 2 (legacy
/// schema 1 is never emitted).
pub const Provenance = struct {
    identity: Identity,
    directory_id: ?[]const u8,
    runtime_sha256: [32]u8,
    mtime_ns: i96,
    installer_version: []const u8,

    pub fn encode(self: Provenance, buffer: []u8) ![]const u8 {
        const hex = std.fmt.bytesToHex(self.identity.sha256, .lower);
        const runtime_hex = std.fmt.bytesToHex(self.runtime_sha256, .lower);
        if (self.directory_id) |physical| return std.fmt.bufPrint(
            buffer,
            "schema=3\nrepository={s}\nrevision={s}\nruntime={s}\nruntime_sha256={s}\nartifact={s}\ninstallation_id={s}\ndirectory_id={s}\nsize={d}\nmodel_mtime_ns={d}\nsha256={s}\ninstalled_by=type-wave-v{s}\n",
            .{ self.identity.repository, self.identity.revision, self.identity.runtime, &runtime_hex, self.identity.artifact, self.identity.installation_id, physical, self.identity.size, self.mtime_ns, &hex, self.installer_version },
        );
        return std.fmt.bufPrint(
            buffer,
            "schema=2\nrepository={s}\nrevision={s}\nruntime={s}\nruntime_sha256={s}\nartifact={s}\ninstallation_id={s}\nsize={d}\nmodel_mtime_ns={d}\nsha256={s}\ninstalled_by=type-wave-v{s}\n",
            .{ self.identity.repository, self.identity.revision, self.identity.runtime, &runtime_hex, self.identity.artifact, self.identity.installation_id, self.identity.size, self.mtime_ns, &hex, self.installer_version },
        );
    }
};

/// A parsed `partial.meta` resume record. String fields borrow from the text passed to
/// `parse`. Only `offset` gates the parse; identity fields are validated by `matches`, and
/// the `etag`/`last_modified` resume validator is selected by model_store.
pub const Partial = struct {
    schema: ?[]const u8,
    repository: ?[]const u8,
    revision: ?[]const u8,
    runtime: ?[]const u8,
    artifact: ?[]const u8,
    installation_id: ?[]const u8,
    size: ?[]const u8,
    sha256: ?[]const u8,
    offset: u64,
    etag: ?[]const u8,
    last_modified: ?[]const u8,

    pub fn parse(text: []const u8) ?Partial {
        const offset = std.fmt.parseInt(u64, value(text, "offset=") orelse return null, 10) catch return null;
        return .{
            .schema = value(text, "schema="),
            .repository = value(text, "repository="),
            .revision = value(text, "revision="),
            .runtime = value(text, "runtime="),
            .artifact = value(text, "artifact="),
            .installation_id = value(text, "installation_id="),
            .size = value(text, "size="),
            .sha256 = value(text, "sha256="),
            .offset = offset,
            .etag = value(text, "etag="),
            .last_modified = value(text, "last_modified="),
        };
    }

    /// Does this partial belong to `expected`? A partial must be `schema=1` and carry the full
    /// identity — no legacy exception. Fields compare textually, so a missing one is a
    /// non-match.
    pub fn matches(self: Partial, expected: Identity) bool {
        var size_buffer: [32]u8 = undefined;
        const expected_size = std.fmt.bufPrint(&size_buffer, "{d}", .{expected.size}) catch return false;
        const expected_digest = std.fmt.bytesToHex(expected.sha256, .lower);
        return textEql(self.schema, "1") and
            textEql(self.repository, expected.repository) and
            textEql(self.revision, expected.revision) and
            textEql(self.runtime, expected.runtime) and
            textEql(self.artifact, expected.artifact) and
            textEql(self.installation_id, expected.installation_id) and
            textEql(self.size, expected_size) and
            textEql(self.sha256, &expected_digest);
    }
};

/// The write side of `partial.meta`. `etag`/`last_modified` are empty strings when unused.
pub const PartialWrite = struct {
    identity: Identity,
    offset: u64,
    etag: []const u8,
    last_modified: []const u8,

    pub fn encode(self: PartialWrite, buffer: []u8) ![]const u8 {
        const digest = std.fmt.bytesToHex(self.identity.sha256, .lower);
        return std.fmt.bufPrint(
            buffer,
            "schema=1\nrepository={s}\nrevision={s}\nruntime={s}\nartifact={s}\ninstallation_id={s}\nsize={d}\nsha256={s}\noffset={d}\netag={s}\nlast_modified={s}\n",
            .{ self.identity.repository, self.identity.revision, self.identity.runtime, self.identity.artifact, self.identity.installation_id, self.identity.size, &digest, self.offset, self.etag, self.last_modified },
        );
    }
};

/// A path component that is safe to join under the models root: non-empty, not `.`/`..`, and
/// free of separators. Shared by the receipt parse and model_store's installation-directory
/// scan.
pub fn safePathComponent(component: []const u8) bool {
    return component.len > 0 and
        !std.mem.eql(u8, component, ".") and
        !std.mem.eql(u8, component, "..") and
        std.mem.indexOfAny(u8, component, "/\\") == null;
}

fn runtimeDigest(text: []const u8) ?[32]u8 {
    const encoded = value(text, "runtime_sha256=") orelse return null;
    if (encoded.len != 64) return null;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return null;
    return digest;
}

/// Read the value of the first `prefix`-keyed line. An empty value reads as absent.
fn value(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const found = line[prefix.len..];
        return if (found.len == 0) null else found;
    }
    return null;
}

fn presentEql(actual: ?[]const u8, expected: []const u8) bool {
    return actual != null and std.mem.eql(u8, actual.?, expected);
}

fn textEql(actual: ?[]const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual orelse "", expected);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────

const test_identity = Identity{
    .repository = "example/test-model",
    .revision = "test-revision",
    .runtime = "whisper.cpp-v1.9.1",
    .artifact = "ggml-model.bin",
    .installation_id = "test-installation",
    .size = 17,
    .sha256 = @splat(0xab),
};

fn testProvenance(directory_id: ?[]const u8) Provenance {
    return .{
        .identity = test_identity,
        .directory_id = directory_id,
        .runtime_sha256 = @splat(0xcd),
        .mtime_ns = 123456789,
        .installer_version = "0.0.0",
    };
}

test "receipt round-trips through schema 2 (immutable)" {
    var buffer: [1024]u8 = undefined;
    const text = try testProvenance(null).encode(&buffer);
    const parsed = Receipt.parse(text) orelse return error.ParseFailed;
    try std.testing.expectEqual(Schema.immutable, parsed.schema);
    try std.testing.expectEqualStrings("ggml-model.bin", parsed.artifact);
    try std.testing.expectEqualStrings("test-installation", parsed.installation_id.?);
    // schema 2 resolves its directory_id from installation_id
    try std.testing.expectEqualStrings("test-installation", parsed.directory_id.?);
    try std.testing.expectEqual(@as(u64, 17), parsed.identity.size);
    try std.testing.expectEqual(@as(i96, 123456789), parsed.mtime_ns);
    try std.testing.expectEqual(@as(u8, 0xcd), parsed.runtime_sha256[0]);
    try std.testing.expectEqualStrings("type-wave-v0.0.0", parsed.installed_by.?);
    try std.testing.expect(parsed.matches(test_identity));
}

test "receipt round-trips through schema 3 (generation)" {
    var buffer: [1024]u8 = undefined;
    const text = try testProvenance("test-installation-g2").encode(&buffer);
    const parsed = Receipt.parse(text) orelse return error.ParseFailed;
    try std.testing.expectEqual(Schema.generation, parsed.schema);
    try std.testing.expectEqualStrings("test-installation-g2", parsed.directory_id.?);
    try std.testing.expectEqualStrings("test-installation", parsed.installation_id.?);
    try std.testing.expect(parsed.matches(test_identity));
}

test "legacy schema 1 receipt is parse-only and has no installation_id" {
    const runtime_hex = std.fmt.bytesToHex(@as([32]u8, @splat(0xcd)), .lower);
    const digest_hex = std.fmt.bytesToHex(@as([32]u8, @splat(0xab)), .lower);
    var buffer: [1024]u8 = undefined;
    const legacy = try std.fmt.bufPrint(
        &buffer,
        "schema=1\nrepository=example/test-model\nrevision=test-revision\nruntime=whisper.cpp-v1.9.1\n" ++
            "runtime_sha256={s}\nartifact=ggml-model.bin\nsize=17\nmodel_mtime_ns=123456789\n" ++
            "sha256={s}\ninstalled_by=type-wave-v0.0.0\n",
        .{ &runtime_hex, &digest_hex },
    );
    const parsed = Receipt.parse(legacy) orelse return error.ParseFailed;
    try std.testing.expectEqual(Schema.legacy, parsed.schema);
    try std.testing.expect(parsed.installation_id == null);
    try std.testing.expect(parsed.directory_id == null);
    // legacy matches on identity without an installation_id
    try std.testing.expect(parsed.matches(test_identity));
}

test "receipt parse rejects malformed and unsafe input" {
    try std.testing.expect(Receipt.parse("nonsense") == null);
    var buffer: [1024]u8 = undefined;
    const good = try testProvenance(null).encode(&buffer);
    // strip the required model_mtime_ns line
    const without_mtime = try std.mem.replaceOwned(u8, std.testing.allocator, good, "model_mtime_ns=123456789\n", "");
    defer std.testing.allocator.free(without_mtime);
    try std.testing.expect(Receipt.parse(without_mtime) == null);
    // unsafe artifact path
    const unsafe = try std.mem.replaceOwned(u8, std.testing.allocator, good, "artifact=ggml-model.bin", "artifact=../escape");
    defer std.testing.allocator.free(unsafe);
    try std.testing.expect(Receipt.parse(unsafe) == null);
}

test "receipt matches fails on each identity field" {
    var buffer: [1024]u8 = undefined;
    const parsed = Receipt.parse(try testProvenance(null).encode(&buffer)) orelse return error.ParseFailed;
    var other = test_identity;
    other.repository = "someone/else";
    try std.testing.expect(!parsed.matches(other));
    other = test_identity;
    other.installation_id = "different";
    try std.testing.expect(!parsed.matches(other));
    other = test_identity;
    other.size = 18;
    try std.testing.expect(!parsed.matches(other));
    other = test_identity;
    other.sha256 = @splat(0x00);
    try std.testing.expect(!parsed.matches(other));
}

test "partial round-trips and matches its identity" {
    var buffer: [1024]u8 = undefined;
    const write = PartialWrite{ .identity = test_identity, .offset = 8, .etag = "\"abc\"", .last_modified = "" };
    const text = try write.encode(&buffer);
    const parsed = Partial.parse(text) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u64, 8), parsed.offset);
    try std.testing.expectEqualStrings("\"abc\"", parsed.etag.?);
    try std.testing.expect(parsed.last_modified == null);
    try std.testing.expect(parsed.matches(test_identity));
}

test "partial parse requires a parseable offset" {
    try std.testing.expect(Partial.parse("schema=1\nrepository=example/test-model\n") == null);
    try std.testing.expect(Partial.parse("schema=1\noffset=not-a-number\n") == null);
}

test "partial matches rejects a mismatched identity or non-1 schema" {
    var buffer: [1024]u8 = undefined;
    const parsed = Partial.parse(try (PartialWrite{ .identity = test_identity, .offset = 8, .etag = "\"abc\"", .last_modified = "" }).encode(&buffer)) orelse return error.ParseFailed;
    var other = test_identity;
    other.revision = "other-revision";
    try std.testing.expect(!parsed.matches(other));
    // a partial-shaped record with a foreign schema does not match
    const wrong_schema = Partial.parse("schema=2\noffset=8\n") orelse return error.ParseFailed;
    try std.testing.expect(!wrong_schema.matches(test_identity));
}

test "MODEL_MANIFEST encodes and parses through artifact_identity" {
    var buffer: [256]u8 = undefined;
    const text = try artifact_identity.encode(.{ .size = 17, .sha256 = @splat(0xab) }, &buffer);
    const digest_hex = std.fmt.bytesToHex(@as([32]u8, @splat(0xab)), .lower);
    var expected_buffer: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "size=17\nsha256={s}\n", .{&digest_hex});
    try std.testing.expectEqualStrings(expected, text);
    const parsed = try artifact_identity.parse(text);
    try std.testing.expectEqual(@as(u64, 17), parsed.size);
}

test "safePathComponent rejects traversal and separators" {
    try std.testing.expect(safePathComponent("ok-name"));
    try std.testing.expect(!safePathComponent(""));
    try std.testing.expect(!safePathComponent("."));
    try std.testing.expect(!safePathComponent(".."));
    try std.testing.expect(!safePathComponent("a/b"));
}
