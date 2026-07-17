//! Explicit, authenticated Model Operations for the pinned KB Whisper installation.

const std = @import("std");

pub const pinned_manifest = Manifest{
    .repository = "KBLab/kb-whisper-small",
    .revision = "3564d61a42fc210ceaa55a22a96dd64478959c78",
    .artifact = "ggml-model.bin",
    .installation_id = "3564d61a42fc-f16",
    .url = "https://huggingface.co/KBLab/kb-whisper-small/resolve/3564d61a42fc210ceaa55a22a96dd64478959c78/ggml-model.bin",
    .size = 487_601_984,
    .sha256 = .{
        0xde, 0x69, 0x11, 0x33, 0x0c, 0xbd, 0xc1, 0x31,
        0x36, 0x2f, 0x7a, 0x95, 0x56, 0x82, 0xb6, 0x5c,
        0x8a, 0x5a, 0x23, 0x94, 0xca, 0xba, 0x73, 0xe7,
        0xea, 0x82, 0x1a, 0x98, 0x22, 0xef, 0xb8, 0xc6,
    },
};

pub const Manifest = struct {
    repository: []const u8,
    revision: []const u8,
    artifact: []const u8,
    installation_id: []const u8,
    url: []const u8,
    size: u64,
    sha256: [32]u8,
    runtime: []const u8 = "whisper.cpp-v1.9.1",
    installer_version: []const u8 = "0.0.0",

    fn forTest() Manifest {
        return .{
            .repository = "example/test-model",
            .revision = "test-revision",
            .artifact = "ggml-model.bin",
            .installation_id = "test-installation",
            .url = "https://huggingface.co/example/test-model/resolve/test-revision/ggml-model.bin",
            .size = test_bytes.len,
            .sha256 = .{
                0x12, 0xd4, 0xee, 0x57, 0x65, 0xd2, 0xf8, 0x28,
                0x53, 0x30, 0x67, 0x0a, 0xfc, 0xff, 0x0a, 0x8c,
                0xdb, 0x43, 0x44, 0x18, 0xd4, 0xc2, 0x33, 0x1b,
                0xa6, 0x81, 0xee, 0x4b, 0xc6, 0xaa, 0x5a, 0x79,
            },
        };
    }
};

pub fn Operation(comptime Transport: type, comptime Smoke: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        manifest: Manifest,
        transport: *Transport,
        smoke: *Smoke,

        const Self = @This();
        const PreparedInstallation = struct {
            stat: std.Io.File.Stat,
            runtime_sha256: [32]u8,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            root: []const u8,
            manifest: Manifest,
            transport: *Transport,
            smoke: *Smoke,
        ) Self {
            return .{ .allocator = allocator, .io = io, .root = root, .manifest = manifest, .transport = transport, .smoke = smoke };
        }

        /// One explicit Model Operation: acquire, verify, smoke-test, then publish.
        /// Nothing before the final receipt rename can replace the active installation.
        pub fn install(self: *Self, token: []const u8) !void {
            if (token.len == 0) return error.MissingHuggingFaceToken;
            if (!isHuggingFaceOrigin(self.manifest.url)) return error.UntrustedArtifactOrigin;

            try std.Io.Dir.cwd().createDirPath(self.io, self.root);
            const lock_path = try std.fmt.allocPrint(self.allocator, "{s}/.operation.lock", .{self.root});
            defer self.allocator.free(lock_path);
            var lock = try std.Io.Dir.cwd().createFile(self.io, lock_path, .{ .lock = .exclusive });
            defer lock.close(self.io);
            if (try activeInstallationPresent(self.io, self.root, self.manifest)) return;

            const stage_dir = try std.fmt.allocPrint(self.allocator, "{s}/staging-{s}", .{ self.root, self.manifest.installation_id });
            defer self.allocator.free(stage_dir);
            std.Io.Dir.cwd().deleteTree(self.io, stage_dir) catch |failure| if (failure != error.FileNotFound) return failure;
            try std.Io.Dir.cwd().createDirPath(self.io, stage_dir);

            const stage_model = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ stage_dir, self.manifest.artifact });
            defer self.allocator.free(stage_model);
            var file = try std.Io.Dir.cwd().createFile(self.io, stage_model, .{ .permissions = .fromMode(0o600) });
            {
                defer file.close(self.io);
                var buffer: [64 * 1024]u8 = undefined;
                var writer = file.writerStreaming(self.io, &buffer);
                try self.transport.download(self.manifest.url, token, &writer.interface);
                try writer.flush();
                try file.sync(self.io);
            }

            var prepared = try self.prepareInstallation(stage_model, stage_dir);

            const installations = try std.fmt.allocPrint(self.allocator, "{s}/installations", .{self.root});
            defer self.allocator.free(installations);
            try std.Io.Dir.cwd().createDirPath(self.io, installations);
            const final_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ installations, self.manifest.installation_id });
            defer self.allocator.free(final_dir);
            const final_exists = exists: {
                std.Io.Dir.cwd().access(self.io, final_dir, .{}) catch |failure| switch (failure) {
                    error.FileNotFound => break :exists false,
                    else => return failure,
                };
                break :exists true;
            };
            if (final_exists) {
                const final_model = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ final_dir, self.manifest.artifact });
                defer self.allocator.free(final_model);
                prepared = try self.prepareInstallation(final_model, final_dir);
                try std.Io.Dir.cwd().deleteTree(self.io, stage_dir);
            } else {
                try std.Io.Dir.renameAbsolute(stage_dir, final_dir, self.io);
            }

            try publishReceipt(self.io, self.root, self.manifest, prepared.runtime_sha256, prepared.stat);
        }

        fn prepareInstallation(self: *Self, model_path: []const u8, directory: []const u8) !PreparedInstallation {
            const stat = try verifyArtifact(self.io, model_path, self.manifest);
            const runtime_sha256 = try self.smoke.run(model_path);
            try writeProvenance(self.io, directory, self.manifest, runtime_sha256, stat);
            return .{ .stat = stat, .runtime_sha256 = runtime_sha256 };
        }
    };
}

fn verifyArtifact(io: std.Io, path: []const u8, manifest: Manifest) !std.Io.File.Stat {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size != manifest.size) return error.ModelSizeMismatch;
    const actual = try sha256File(io, path);
    if (!std.mem.eql(u8, &actual, &manifest.sha256)) return error.ModelDigestMismatch;
    return stat;
}

fn receipt(manifest: Manifest, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat, buffer: []u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(manifest.sha256, .lower);
    const runtime_hex = std.fmt.bytesToHex(runtime_sha256, .lower);
    return std.fmt.bufPrint(
        buffer,
        "schema=1\nrepository={s}\nrevision={s}\nruntime={s}\nruntime_sha256={s}\nartifact={s}\nsize={d}\nmodel_mtime_ns={d}\nsha256={s}\ninstalled_by=type-wave-v{s}\n",
        .{ manifest.repository, manifest.revision, manifest.runtime, &runtime_hex, manifest.artifact, manifest.size, model_stat.mtime.nanoseconds, &hex, manifest.installer_version },
    );
}

fn writeProvenance(io: std.Io, directory: []const u8, manifest: Manifest, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat) !void {
    var text_buffer: [1024]u8 = undefined;
    const text = try receipt(manifest, runtime_sha256, model_stat, &text_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/PROVENANCE", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
}

fn publishReceipt(io: std.Io, root: []const u8, manifest: Manifest, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat) !void {
    var text_buffer: [1024]u8 = undefined;
    const text = try receipt(manifest, runtime_sha256, model_stat, &text_buffer);
    var tmp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buffer, "{s}/active.receipt.tmp", .{root});
    var active_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const active = try std.fmt.bufPrint(&active_buffer, "{s}/active.receipt", .{root});
    var file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, text);
    try file.sync(io);
    try std.Io.Dir.renameAbsolute(tmp, active, io);
}

pub fn activeInstallationPresent(io: std.Io, root: []const u8, manifest: Manifest) !bool {
    var receipt_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buffer, "{s}/active.receipt", .{root});
    var actual_buffer: [1024]u8 = undefined;
    const actual = std.Io.Dir.cwd().readFile(io, receipt_path, &actual_buffer) catch |failure| switch (failure) {
        error.FileNotFound => return false,
        else => return failure,
    };
    var model_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = try std.fmt.bufPrint(&model_path_buffer, "{s}/installations/{s}/{s}", .{ root, manifest.installation_id, manifest.artifact });
    var model = std.Io.Dir.cwd().openFile(io, model_path, .{}) catch |failure| switch (failure) {
        error.FileNotFound => return false,
        else => return failure,
    };
    defer model.close(io);
    const stat = try model.stat(io);
    if (stat.size != manifest.size) return false;
    var installed_manifest = manifest;
    installed_manifest.installer_version = receiptValue(actual, "installed_by=type-wave-v") orelse return false;
    var expected_buffer: [1024]u8 = undefined;
    const expected = try receipt(installed_manifest, receiptRuntimeDigest(actual) orelse return false, stat, &expected_buffer);
    return std.mem.eql(u8, actual, expected);
}

fn receiptRuntimeDigest(receipt_text: []const u8) ?[32]u8 {
    const encoded = receiptValue(receipt_text, "runtime_sha256=") orelse return null;
    if (encoded.len != 64) return null;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return null;
    return digest;
}

fn receiptValue(receipt_text: []const u8, prefix: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, receipt_text, prefix) orelse return null) + prefix.len;
    const end_offset = std.mem.indexOfScalar(u8, receipt_text[start..], '\n') orelse return null;
    if (end_offset == 0) return null;
    return receipt_text[start .. start + end_offset];
}

pub fn sha256File(io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const count = reader.interface.readSliceShort(&chunk) catch |failure| switch (failure) {
            error.ReadFailed => return reader.err.?,
        };
        if (count == 0) break;
        digest.update(chunk[0..count]);
    }
    var value: [32]u8 = undefined;
    digest.final(&value);
    return value;
}

pub fn rootPath(home: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/Library/Application Support/type-wave/models", .{home});
}

pub fn activeModelPath(io: std.Io, root: []const u8, manifest: Manifest, buffer: []u8) !?[]const u8 {
    if (!try activeInstallationPresent(io, root, manifest)) return null;
    return try std.fmt.bufPrint(buffer, "{s}/installations/{s}/{s}", .{ root, manifest.installation_id, manifest.artifact });
}

pub fn isHuggingFaceOrigin(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return isHuggingFaceUri(uri);
}

fn isHuggingFaceUri(uri: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    if (uri.port != null and uri.port.? != 443) return false;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return false;
    return std.ascii.eqlIgnoreCase(host.bytes, "huggingface.co");
}

/// Policy helper used by the HTTP adapter: credentials exist only on the exact trusted
/// origin. The adapter resolves each redirect itself and calls this policy again.
pub fn authorizationFor(url: []const u8, token: []const u8, buffer: []u8) ?[]const u8 {
    if (!isHuggingFaceOrigin(url) or token.len == 0) return null;
    return std.fmt.bufPrint(buffer, "Bearer {s}", .{token}) catch null;
}

pub const HttpTransport = struct {
    client: *std.http.Client,

    pub fn download(self: *HttpTransport, url: []const u8, token: []const u8, writer: *std.Io.Writer) !void {
        var authorization_buffer: [4096]u8 = undefined;
        const authorization = authorizationFor(url, token, &authorization_buffer) orelse return error.UntrustedArtifactOrigin;
        const allocator = self.client.allocator;
        var owned_url: ?[]u8 = null;
        defer if (owned_url) |value| allocator.free(value);
        var current_url = url;

        var redirect_count: u8 = 0;
        while (redirect_count <= 5) : (redirect_count += 1) {
            const uri = try std.Uri.parse(current_url);
            const privileged_storage = [_]std.http.Header{.{ .name = "Authorization", .value = authorization }};
            const privileged: []const std.http.Header = if (isHuggingFaceUri(uri)) &privileged_storage else &.{};
            var request = try self.client.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                .headers = .{ .accept_encoding = .omit },
                .privileged_headers = privileged,
            });
            errdefer request.deinit();
            try request.sendBodiless();
            var response = try request.receiveHead(&.{});

            if (response.head.status.class() == .redirect) {
                const location = response.head.location orelse return error.ModelDownloadRedirectMissing;
                var resolve_buffer: [16 * 1024]u8 = undefined;
                if (location.len > resolve_buffer.len) return error.ModelDownloadRedirectTooLong;
                @memcpy(resolve_buffer[0..location.len], location);
                var resolve_slice: []u8 = &resolve_buffer;
                const next_uri = try uri.resolveInPlace(location.len, &resolve_slice);
                var discard_buffer: [1024]u8 = undefined;
                _ = try response.reader(&discard_buffer).discardRemaining();
                const next_url = try std.fmt.allocPrint(allocator, "{f}", .{next_uri});
                request.deinit();
                if (owned_url) |previous| allocator.free(previous);
                owned_url = next_url;
                current_url = next_url;
                continue;
            }

            if (response.head.status != .ok) {
                const status = response.head.status;
                return switch (status) {
                    .unauthorized, .forbidden => error.HuggingFaceAuthenticationFailed,
                    else => error.ModelDownloadFailed,
                };
            }
            var transfer_buffer: [64 * 1024]u8 = undefined;
            _ = try response.reader(&transfer_buffer).streamRemaining(writer);
            request.deinit();
            return;
        }
        return error.TooManyModelDownloadRedirects;
    }
};

test "Model Operation verifies and smoke-tests before publishing the active receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);

    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(
        std.testing.allocator,
        std.testing.io,
        root_buf[0..root_len],
        test_manifest,
        &transport,
        &smoke,
    );
    try operation.install("hf_secret");

    try std.testing.expect(smoke.called);
    try std.testing.expect(try activeInstallationPresent(std.testing.io, root_buf[0..root_len], test_manifest));
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root_buf[0..root_len]});
    var receipt_buf: [1024]u8 = undefined;
    const published = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &receipt_buf);
    try std.testing.expect(std.mem.indexOf(u8, published, "hf_secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, published, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, published, "runtime_sha256=5a5a5a5a") != null);
}

test "an interrupted receipt publish is recoverable and startup rejects changed model metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install("hf_secret");

    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    try std.Io.Dir.cwd().deleteFile(std.testing.io, receipt_path);
    try operation.install("hf_secret");
    try std.testing.expect(try activeInstallationPresent(std.testing.io, root, test_manifest));

    var model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = try std.fmt.bufPrint(&model_path_buf, "{s}/installations/{s}/{s}", .{ root, test_manifest.installation_id, test_manifest.artifact });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model_path, .data = "changed" });
    try std.testing.expect(!try activeInstallationPresent(std.testing.io, root, test_manifest));
}

test "failed verification or smoke test cannot replace the active receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = "previous installation\n" });

    var short_transport = ShortTransport{};
    var smoke = FakeSmoke{};
    var bad_size = Operation(ShortTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &short_transport, &smoke);
    try std.testing.expectError(error.ModelSizeMismatch, bad_size.install("hf_secret"));
    try std.testing.expect(!smoke.called);

    var actual_buf: [64]u8 = undefined;
    const after_digest_failure = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &actual_buf);
    try std.testing.expectEqualStrings("previous installation\n", after_digest_failure);

    var bad_transport = BadTransport{};
    var bad_digest = Operation(BadTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &bad_transport, &smoke);
    try std.testing.expectError(error.ModelDigestMismatch, bad_digest.install("hf_secret"));
    try std.testing.expect(!smoke.called);

    var transport = FakeTransport{};
    var failing_smoke = FailingSmoke{};
    var bad_smoke = Operation(FakeTransport, FailingSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &failing_smoke);
    try std.testing.expectError(error.HelperSmokeTestFailed, bad_smoke.install("hf_secret"));
    const after_smoke_failure = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &actual_buf);
    try std.testing.expectEqualStrings("previous installation\n", after_smoke_failure);
}

test "Hugging Face authorization is never constructed for a cross-origin request" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Bearer hf_secret", authorizationFor(test_manifest.url, "hf_secret", &buffer).?);
    try std.testing.expect(authorizationFor("https://cdn-lfs.hf.co/signed?secret=value", "hf_secret", &buffer) == null);
    try std.testing.expect(authorizationFor("https://huggingface.co.evil.example/model", "hf_secret", &buffer) == null);
}

const test_bytes = "pinned test model";
const test_manifest = Manifest.forTest();

const FakeTransport = struct {
    pub fn download(_: *FakeTransport, _: []const u8, _: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll(test_bytes);
    }
};

const FakeSmoke = struct {
    called: bool = false,
    pub fn run(self: *FakeSmoke, _: []const u8) ![32]u8 {
        self.called = true;
        return @splat(0x5a);
    }
};

const BadTransport = struct {
    pub fn download(_: *BadTransport, _: []const u8, _: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll("tinned test model");
    }
};

const ShortTransport = struct {
    pub fn download(_: *ShortTransport, _: []const u8, _: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll("wrong");
    }
};

const FailingSmoke = struct {
    pub fn run(_: *FailingSmoke, _: []const u8) ![32]u8 {
        return error.HelperSmokeTestFailed;
    }
};
