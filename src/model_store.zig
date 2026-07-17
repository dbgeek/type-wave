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

pub const OperationPhase = enum {
    idle,
    downloading,
    paused,
    verifying,
    smoke_testing,
    activating,
    failed,
};

pub const ByteProgress = struct {
    completed: u64,
    total: u64,
};

pub const Recovery = struct {
    phase: OperationPhase,
    bytes: ByteProgress,
};

pub const ValidatorKind = enum { etag, last_modified };

pub const Validator = struct {
    kind: ValidatorKind,
    bytes: [512]u8 = undefined,
    len: u16,

    pub fn init(kind: ValidatorKind, value_bytes: []const u8) !Validator {
        if (value_bytes.len == 0 or value_bytes.len > 512) return error.InvalidModelValidator;
        if (kind == .etag and (value_bytes.len < 2 or value_bytes[0] != '"' or value_bytes[value_bytes.len - 1] != '"'))
            return error.InvalidModelValidator;
        var result = Validator{ .kind = kind, .len = @intCast(value_bytes.len) };
        @memcpy(result.bytes[0..value_bytes.len], value_bytes);
        return result;
    }

    pub fn value(self: *const Validator) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: Validator, b: Validator) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.value(), b.value());
    }
};

pub const CancelToken = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn request(self: *CancelToken) void {
        self.requested.store(true, .release);
    }

    pub fn isRequested(self: *const CancelToken) bool {
        return self.requested.load(.acquire);
    }

    pub fn signalFlag(self: *const CancelToken) *const std.atomic.Value(bool) {
        return &self.requested;
    }
};

pub const DownloadRequest = struct {
    offset: u64,
    end: u64,
    total: u64,
    validator: ?Validator,
    cancel: *CancelToken,
};

pub const DownloadResult = struct {
    validator: Validator,

    pub fn fromValidator(kind: ValidatorKind, value: []const u8) DownloadResult {
        return .{ .validator = Validator.init(kind, value) catch unreachable };
    }
};

pub const RetryProgress = struct {
    attempt: u8,
    budget: u8,
    delay_ms: u32,
    bytes: ByteProgress,
};

pub const OperationEvent = union(enum) {
    downloading: ByteProgress,
    retrying: RetryProgress,
    verifying: ByteProgress,
    smoke_testing,
    activating,
};

pub const Observer = struct {
    ctx: *anyopaque,
    on_event: *const fn (*anyopaque, OperationEvent) void,
};

pub fn Operation(comptime Transport: type, comptime Smoke: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        manifest: Manifest,
        transport: *Transport,
        smoke: *Smoke,
        cancel: CancelToken = .{},
        observer: ?Observer = null,
        retry_budget: u8 = 3,
        retry_delay_ms: u32 = 1000,
        chunk_size: u64 = 1024 * 1024,

        const Self = @This();
        const PreparedInstallation = struct {
            stat: std.Io.File.Stat,
            runtime_sha256: [32]u8,
        };
        const LockedOperation = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []u8,
            file: std.Io.File,

            fn deinit(locked: LockedOperation) void {
                locked.file.close(locked.io);
                locked.allocator.free(locked.path);
            }
        };
        const StagePaths = struct {
            allocator: std.mem.Allocator,
            directory: []u8,
            model: []u8,

            fn deinit(paths: StagePaths) void {
                paths.allocator.free(paths.model);
                paths.allocator.free(paths.directory);
            }
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

        /// Inspect durable incomplete work after restart. This is deliberately filesystem-only:
        /// resuming network activity always requires a separate explicit user action.
        pub fn recover(self: *Self) !Recovery {
            return recoveryState(self.io, self.root, self.manifest);
        }

        pub fn cancellationSignal(self: *Self) *std.atomic.Value(bool) {
            return @constCast(self.cancel.signalFlag());
        }

        pub fn discardPartial(self: *Self) !void {
            try discardIncomplete(self.io, self.root, self.manifest);
        }

        fn notify(self: *Self, event: OperationEvent) void {
            if (self.observer) |observer| observer.on_event(observer.ctx, event);
        }

        fn beginLocked(self: *Self, token: []const u8) !LockedOperation {
            if (token.len == 0) return error.MissingHuggingFaceToken;
            if (!isHuggingFaceOrigin(self.manifest.url)) return error.UntrustedArtifactOrigin;
            try std.Io.Dir.cwd().createDirPath(self.io, self.root);
            const path = try std.fmt.allocPrint(self.allocator, "{s}/.operation.lock", .{self.root});
            errdefer self.allocator.free(path);
            const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .lock = .exclusive });
            return .{ .allocator = self.allocator, .io = self.io, .path = path, .file = file };
        }

        fn stagePaths(self: *Self) !StagePaths {
            const directory = try std.fmt.allocPrint(self.allocator, "{s}/staging-{s}", .{ self.root, self.manifest.installation_id });
            errdefer self.allocator.free(directory);
            const model = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory, self.manifest.artifact });
            return .{ .allocator = self.allocator, .directory = directory, .model = model };
        }

        /// One explicit Model Operation: acquire, verify, smoke-test, then publish.
        /// Nothing before the final receipt rename can replace the active installation.
        pub fn install(self: *Self, token: []const u8) !void {
            const locked = try self.beginLocked(token);
            defer locked.deinit();
            if (try activeInstallationPresent(self.io, self.root, self.manifest)) return;

            if ((try loadPartial(self.io, self.root, self.manifest)) != null)
                return error.PartialRequiresExplicitResume;

            const paths = try self.stagePaths();
            defer paths.deinit();
            try discardStage(self.io, paths.directory);
            try std.Io.Dir.cwd().createDirPath(self.io, paths.directory);
            var file = try std.Io.Dir.cwd().createFile(self.io, paths.model, .{ .read = true, .permissions = .fromMode(0o600) });
            defer file.close(self.io);
            try self.acquire(token, paths.directory, file, 0, null);
            try self.activate(paths.model, paths.directory);
        }

        pub fn resumePartial(self: *Self, token: []const u8) !void {
            const locked = try self.beginLocked(token);
            defer locked.deinit();
            const partial = (try loadPartial(self.io, self.root, self.manifest)) orelse return error.NoResumablePartial;
            const paths = try self.stagePaths();
            defer paths.deinit();
            var file = try std.Io.Dir.cwd().openFile(self.io, paths.model, .{ .mode = .read_write });
            defer file.close(self.io);
            self.acquire(token, paths.directory, file, partial.offset, partial.validator) catch |failure| {
                if (isIncompatibleResumeFailure(failure)) try discardStage(self.io, paths.directory);
                return failure;
            };
            try self.activate(paths.model, paths.directory);
        }

        fn acquire(self: *Self, token: []const u8, stage_dir: []const u8, file: std.Io.File, starting_offset: u64, starting_validator: ?Validator) !void {
            if (self.chunk_size == 0) return error.InvalidModelChunkSize;
            var offset = starting_offset;
            var validator = starting_validator;
            var retries: u8 = 0;
            const chunk_storage = try self.allocator.alloc(u8, @intCast(@min(self.chunk_size, self.manifest.size)));
            defer self.allocator.free(chunk_storage);
            while (offset < self.manifest.size) {
                if (self.cancel.isRequested()) return error.ModelOperationCancelled;
                const end = @min(offset + self.chunk_size, self.manifest.size) - 1;
                const count: usize = @intCast(end - offset + 1);
                var writer = std.Io.Writer.fixed(chunk_storage[0..count]);
                const request: DownloadRequest = .{
                    .offset = offset,
                    .end = end,
                    .total = self.manifest.size,
                    .validator = validator,
                    .cancel = &self.cancel,
                };
                const result = while (true) {
                    break self.transport.download(self.manifest.url, token, request, &writer) catch |failure| {
                        if (failure == error.ModelOperationCancelled) return failure;
                        if (!isTransientDownloadFailure(failure)) return failure;
                        if (retries == self.retry_budget) return error.ModelDownloadRetryBudgetExhausted;
                        retries += 1;
                        const delay_ms = self.retry_delay_ms * (@as(u32, 1) << @intCast(retries - 1));
                        self.notify(.{ .retrying = .{
                            .attempt = retries,
                            .budget = self.retry_budget,
                            .delay_ms = delay_ms,
                            .bytes = .{ .completed = offset, .total = self.manifest.size },
                        } });
                        var waited: u32 = 0;
                        while (waited < delay_ms) {
                            if (self.cancel.isRequested()) return error.ModelOperationCancelled;
                            const interval = @min(@as(u32, 50), delay_ms - waited);
                            try std.Io.sleep(self.io, .fromMilliseconds(interval), .awake);
                            waited += interval;
                        }
                        writer.end = 0;
                        continue;
                    };
                };
                if (writer.end != count) return error.ModelDownloadTruncated;
                if (validator) |expected| {
                    if (!Validator.eql(expected, result.validator)) return error.ResumeResponseMismatch;
                }
                validator = result.validator;
                try file.writePositionalAll(self.io, chunk_storage[0..count], offset);
                try file.sync(self.io);
                offset = end + 1;
                try writePartialMetadata(self.io, stage_dir, self.manifest, offset, validator.?);
                self.notify(.{ .downloading = .{ .completed = offset, .total = self.manifest.size } });
            }
        }

        fn activate(self: *Self, stage_model: []const u8, stage_dir: []const u8) !void {
            var prepared = self.prepareInstallation(stage_model, stage_dir) catch |failure| {
                if (failure == error.ModelSizeMismatch or failure == error.ModelDigestMismatch)
                    try discardStage(self.io, stage_dir);
                return failure;
            };
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
            }

            if (self.cancel.isRequested()) return error.ModelOperationCancelled;
            self.notify(.activating);
            if (final_exists) {
                try std.Io.Dir.cwd().deleteTree(self.io, stage_dir);
            } else {
                var metadata_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const metadata_path = try std.fmt.bufPrint(&metadata_path_buffer, "{s}/partial.meta", .{stage_dir});
                std.Io.Dir.cwd().deleteFile(self.io, metadata_path) catch |failure| if (failure != error.FileNotFound) return failure;
                try std.Io.Dir.renameAbsolute(stage_dir, final_dir, self.io);
            }

            try publishReceipt(self.io, self.root, self.manifest, prepared.runtime_sha256, prepared.stat);
        }

        fn prepareInstallation(self: *Self, model_path: []const u8, directory: []const u8) !PreparedInstallation {
            const stat = try verifyArtifactCancelable(self.io, model_path, self.manifest, &self.cancel, self.observer);
            if (self.cancel.isRequested()) return error.ModelOperationCancelled;
            self.notify(.smoke_testing);
            const runtime_sha256 = try self.smoke.run(model_path, &self.cancel);
            if (self.cancel.isRequested()) return error.ModelOperationCancelled;
            try writeProvenance(self.io, directory, self.manifest, runtime_sha256, stat);
            return .{ .stat = stat, .runtime_sha256 = runtime_sha256 };
        }
    };
}

fn isTransientDownloadFailure(failure: anyerror) bool {
    return failure == error.ModelDownloadFailed or failure == error.ModelDownloadTruncated or failure == error.ReadFailed or failure == error.ConnectionRefused or failure == error.ConnectionResetByPeer or failure == error.ConnectionTimedOut;
}

fn isIncompatibleResumeFailure(failure: anyerror) bool {
    return failure == error.ResumeResponseMismatch or failure == error.ModelDownloadRangeMismatch or failure == error.ModelValidatorMissing or failure == error.InvalidModelValidator;
}

fn recoverPartial(io: std.Io, root: []const u8, manifest: Manifest) !Recovery {
    const partial = try loadPartial(io, root, manifest);
    return if (partial) |valid|
        .{ .phase = .paused, .bytes = .{ .completed = valid.offset, .total = manifest.size } }
    else
        .{ .phase = .idle, .bytes = .{ .completed = 0, .total = manifest.size } };
}

pub fn recoveryState(io: std.Io, root: []const u8, manifest: Manifest) !Recovery {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var lock_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_path_buffer, "{s}/.operation.lock", .{root});
    var lock = std.Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true }) catch |failure| switch (failure) {
        error.WouldBlock => return .{ .phase = .downloading, .bytes = .{ .completed = 0, .total = manifest.size } },
        else => return failure,
    };
    defer lock.close(io);
    try discardStaleStages(io, root, manifest);
    return recoverPartial(io, root, manifest);
}

fn discardStaleStages(io: std.Io, root: []const u8, manifest: Manifest) !void {
    var desired_buffer: [std.fs.max_name_bytes]u8 = undefined;
    const desired = try std.fmt.bufPrint(&desired_buffer, "staging-{s}", .{manifest.installation_id});
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    var entries = root_dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "staging-") or std.mem.eql(u8, entry.name, desired)) continue;
        try root_dir.deleteTree(io, entry.name);
    }
}

pub fn discardIncomplete(io: std.Io, root: []const u8, manifest: Manifest) !void {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var lock_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_path_buffer, "{s}/.operation.lock", .{root});
    var lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive });
    defer lock.close(io);
    var stage_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const stage = try std.fmt.bufPrint(&stage_buffer, "{s}/staging-{s}", .{ root, manifest.installation_id });
    try discardStage(io, stage);
}

const Partial = struct {
    offset: u64,
    validator: Validator,
};

fn loadPartial(io: std.Io, root: []const u8, manifest: Manifest) !?Partial {
    var stage_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const stage = try std.fmt.bufPrint(&stage_buffer, "{s}/staging-{s}", .{ root, manifest.installation_id });
    var metadata_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const metadata_path = try std.fmt.bufPrint(&metadata_path_buffer, "{s}/partial.meta", .{stage});
    var metadata_buffer: [4096]u8 = undefined;
    const metadata = std.Io.Dir.cwd().readFile(io, metadata_path, &metadata_buffer) catch |failure| switch (failure) {
        error.FileNotFound => {
            try discardStage(io, stage);
            return null;
        },
        else => return failure,
    };
    const offset_text = receiptValue(metadata, "offset=") orelse return discardInvalidPartial(io, stage);
    const offset = std.fmt.parseInt(u64, offset_text, 10) catch return discardInvalidPartial(io, stage);
    const expected_digest = std.fmt.bytesToHex(manifest.sha256, .lower);
    var size_buffer: [32]u8 = undefined;
    const expected_size = try std.fmt.bufPrint(&size_buffer, "{d}", .{manifest.size});
    const identity_matches = std.mem.eql(u8, receiptValue(metadata, "schema=") orelse "", "1") and
        std.mem.eql(u8, receiptValue(metadata, "repository=") orelse "", manifest.repository) and
        std.mem.eql(u8, receiptValue(metadata, "revision=") orelse "", manifest.revision) and
        std.mem.eql(u8, receiptValue(metadata, "runtime=") orelse "", manifest.runtime) and
        std.mem.eql(u8, receiptValue(metadata, "artifact=") orelse "", manifest.artifact) and
        std.mem.eql(u8, receiptValue(metadata, "installation_id=") orelse "", manifest.installation_id) and
        std.mem.eql(u8, receiptValue(metadata, "size=") orelse "", expected_size) and
        std.mem.eql(u8, receiptValue(metadata, "sha256=") orelse "", &expected_digest);
    const validator = if (receiptValue(metadata, "etag=")) |etag|
        Validator.init(.etag, etag) catch return discardInvalidPartial(io, stage)
    else if (receiptValue(metadata, "last_modified=")) |last_modified|
        Validator.init(.last_modified, last_modified) catch return discardInvalidPartial(io, stage)
    else
        return discardInvalidPartial(io, stage);
    if (!identity_matches or offset == 0 or offset > manifest.size)
        return discardInvalidPartial(io, stage);

    var model_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = try std.fmt.bufPrint(&model_path_buffer, "{s}/{s}", .{ stage, manifest.artifact });
    var model = std.Io.Dir.cwd().openFile(io, model_path, .{}) catch return discardInvalidPartial(io, stage);
    defer model.close(io);
    const stat = model.stat(io) catch return discardInvalidPartial(io, stage);
    if (stat.size != offset) return discardInvalidPartial(io, stage);
    return .{ .offset = offset, .validator = validator };
}

fn discardInvalidPartial(io: std.Io, stage: []const u8) !?Partial {
    try discardStage(io, stage);
    return null;
}

fn writePartialMetadata(io: std.Io, stage: []const u8, manifest: Manifest, offset: u64, validator: Validator) !void {
    const digest = std.fmt.bytesToHex(manifest.sha256, .lower);
    const etag = if (validator.kind == .etag) validator.value() else "";
    const last_modified = if (validator.kind == .last_modified) validator.value() else "";
    var text_buffer: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &text_buffer,
        "schema=1\nrepository={s}\nrevision={s}\nruntime={s}\nartifact={s}\ninstallation_id={s}\nsize={d}\nsha256={s}\noffset={d}\netag={s}\nlast_modified={s}\n",
        .{ manifest.repository, manifest.revision, manifest.runtime, manifest.artifact, manifest.installation_id, manifest.size, &digest, offset, etag, last_modified },
    );
    var tmp_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buffer, "{s}/partial.meta.tmp", .{stage});
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/partial.meta", .{stage});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

fn discardStage(io: std.Io, stage: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, stage) catch |failure| if (failure != error.FileNotFound) return failure;
}

fn verifyArtifactCancelable(io: std.Io, path: []const u8, manifest: Manifest, cancel: *const CancelToken, observer: ?Observer) !std.Io.File.Stat {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size != manifest.size) return error.ModelSizeMismatch;
    const actual = try sha256FileObserved(io, path, stat.size, cancel, observer);
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
    const never_cancelled = CancelToken{};
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return sha256FileObserved(io, path, stat.size, &never_cancelled, null);
}

fn sha256FileObserved(io: std.Io, path: []const u8, total: u64, cancel: *const CancelToken, observer: ?Observer) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var completed: u64 = 0;
    while (true) {
        if (cancel.isRequested()) return error.ModelOperationCancelled;
        var chunk: [64 * 1024]u8 = undefined;
        const count = reader.interface.readSliceShort(&chunk) catch |failure| switch (failure) {
            error.ReadFailed => return reader.err.?,
        };
        if (count == 0) break;
        digest.update(chunk[0..count]);
        completed += count;
        if (observer) |sink| sink.on_event(sink.ctx, .{ .verifying = .{ .completed = completed, .total = total } });
    }
    if (cancel.isRequested()) return error.ModelOperationCancelled;
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

    pub fn download(self: *HttpTransport, url: []const u8, token: []const u8, download_request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        var authorization_buffer: [4096]u8 = undefined;
        const authorization = authorizationFor(url, token, &authorization_buffer) orelse return error.UntrustedArtifactOrigin;
        var range_buffer: [128]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buffer, "bytes={d}-{d}", .{ download_request.offset, download_request.end });
        const allocator = self.client.allocator;
        var owned_url: ?[]u8 = null;
        defer if (owned_url) |value| allocator.free(value);
        var current_url = url;

        var redirect_count: u8 = 0;
        while (redirect_count <= 5) : (redirect_count += 1) {
            if (download_request.cancel.isRequested()) return error.ModelOperationCancelled;
            const uri = try std.Uri.parse(current_url);
            const privileged_storage = [_]std.http.Header{.{ .name = "Authorization", .value = authorization }};
            const privileged: []const std.http.Header = if (isHuggingFaceUri(uri)) &privileged_storage else &.{};
            var range_headers: [2]std.http.Header = undefined;
            range_headers[0] = .{ .name = "Range", .value = range };
            var range_header_count: usize = 1;
            if (download_request.validator) |validator| {
                range_headers[1] = .{ .name = "If-Range", .value = validator.value() };
                range_header_count = 2;
            }
            var request = try self.client.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                .headers = .{ .accept_encoding = .omit },
                .privileged_headers = privileged,
                .extra_headers = range_headers[0..range_header_count],
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

            if (response.head.status == .unauthorized or response.head.status == .forbidden)
                return error.HuggingFaceAuthenticationFailed;
            const response_validator = try validateRangeResponse(response.head, download_request);
            const expected_count = download_request.end - download_request.offset + 1;
            var transfer_buffer: [64 * 1024]u8 = undefined;
            var reader = response.reader(&transfer_buffer);
            var transferred: u64 = 0;
            while (true) {
                if (download_request.cancel.isRequested()) return error.ModelOperationCancelled;
                var chunk: [64 * 1024]u8 = undefined;
                const count = try reader.readSliceShort(&chunk);
                if (count == 0) break;
                try writer.writeAll(chunk[0..count]);
                transferred += count;
            }
            if (transferred != expected_count) return error.ModelDownloadTruncated;
            request.deinit();
            return .{ .validator = response_validator };
        }
        return error.TooManyModelDownloadRedirects;
    }
};

fn validateRangeResponse(head: std.http.Client.Response.Head, request: DownloadRequest) !Validator {
    if (head.status != .partial_content) {
        if (head.status.class() == .server_error or head.status == .request_timeout or head.status == .too_many_requests)
            return error.ModelDownloadFailed;
        if (request.validator != null or head.status == .range_not_satisfiable)
            return error.ResumeResponseMismatch;
        return error.ModelDownloadFailed;
    }
    const expected_count = request.end - request.offset + 1;
    if (head.content_length != null and head.content_length.? != expected_count)
        return error.ModelDownloadRangeMismatch;
    var expected_range_buffer: [160]u8 = undefined;
    const expected_range = try std.fmt.bufPrint(
        &expected_range_buffer,
        "bytes {d}-{d}/{d}",
        .{ request.offset, request.end, request.total },
    );
    const content_range = headerValue(head, "content-range") orelse return error.ModelDownloadRangeMismatch;
    if (!std.mem.eql(u8, content_range, expected_range)) return error.ModelDownloadRangeMismatch;
    const response_validator = validator: {
        if (request.validator) |expected| switch (expected.kind) {
            .etag => if (headerValue(head, "etag")) |etag| break :validator try Validator.init(.etag, etag),
            .last_modified => if (headerValue(head, "last-modified")) |last_modified| break :validator try Validator.init(.last_modified, last_modified),
        };
        if (headerValue(head, "etag")) |etag| {
            if (Validator.init(.etag, etag)) |strong| break :validator strong else |_| {}
        }
        if (headerValue(head, "last-modified")) |last_modified|
            break :validator try Validator.init(.last_modified, last_modified);
        return error.ModelValidatorMissing;
    };
    if (request.validator) |expected_validator| {
        if (!Validator.eql(expected_validator, response_validator)) return error.ResumeResponseMismatch;
    }
    return response_validator;
}

fn headerValue(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

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
    try std.testing.expectError(error.ModelDownloadTruncated, bad_size.install("hf_secret"));
    try std.testing.expect(!smoke.called);

    var actual_buf: [64]u8 = undefined;
    const after_digest_failure = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &actual_buf);
    try std.testing.expectEqualStrings("previous installation\n", after_digest_failure);

    var bad_transport = BadTransport{};
    var bad_digest = Operation(BadTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &bad_transport, &smoke);
    try std.testing.expectError(error.ModelDigestMismatch, bad_digest.install("hf_secret"));
    try std.testing.expect(!smoke.called);
    try std.testing.expectEqual(OperationPhase.idle, (try bad_digest.recover()).phase);

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

test "restart exposes a validator-bound partial as paused without network activity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const stage = try std.fmt.allocPrint(std.testing.allocator, "{s}/staging-{s}", .{ root, test_manifest.installation_id });
    defer std.testing.allocator.free(stage);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, stage);
    const model = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ stage, test_manifest.artifact });
    defer std.testing.allocator.free(model);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model, .data = "pinned" });
    const metadata = try std.fmt.allocPrint(
        std.testing.allocator,
        "schema=1\nrepository={s}\nrevision={s}\nruntime={s}\nartifact={s}\ninstallation_id={s}\nsize={d}\nsha256={s}\noffset=6\netag=\"immutable-test\"\nlast_modified=\n",
        .{
            test_manifest.repository,
            test_manifest.revision,
            test_manifest.runtime,
            test_manifest.artifact,
            test_manifest.installation_id,
            test_manifest.size,
            &std.fmt.bytesToHex(test_manifest.sha256, .lower),
        },
    );
    defer std.testing.allocator.free(metadata);
    const metadata_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/partial.meta", .{stage});
    defer std.testing.allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = metadata_path, .data = metadata });

    var transport = CountingTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(CountingTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    const recovery = try operation.recover();

    try std.testing.expectEqual(OperationPhase.paused, recovery.phase);
    try std.testing.expectEqual(@as(u64, 6), recovery.bytes.completed);
    try std.testing.expectEqual(test_manifest.size, recovery.bytes.total);
    try std.testing.expectEqual(@as(usize, 0), transport.requests);
}

test "restart discards a partial whose immutable identity no longer matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const stage = try std.fmt.allocPrint(std.testing.allocator, "{s}/staging-{s}", .{ root, test_manifest.installation_id });
    defer std.testing.allocator.free(stage);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, stage);
    const model = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ stage, test_manifest.artifact });
    defer std.testing.allocator.free(model);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model, .data = "pinned" });
    const metadata_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/partial.meta", .{stage});
    defer std.testing.allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = metadata_path, .data = "schema=1\nrevision=obsolete\noffset=6\netag=\"old\"\n" });

    var transport = CountingTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(CountingTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    const recovery = try operation.recover();

    try std.testing.expectEqual(OperationPhase.idle, recovery.phase);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, stage, .{}));
    try std.testing.expectEqual(@as(usize, 0), transport.requests);
}

test "restart discards staging directories for obsolete immutable identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const obsolete = try std.fmt.allocPrint(std.testing.allocator, "{s}/staging-obsolete-installation", .{root});
    defer std.testing.allocator.free(obsolete);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, obsolete);
    const obsolete_model = try std.fmt.allocPrint(std.testing.allocator, "{s}/ggml-model.bin", .{obsolete});
    defer std.testing.allocator.free(obsolete_model);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = obsolete_model, .data = "old" });

    _ = try recoveryState(std.testing.io, root, test_manifest);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, obsolete, .{}));
}

test "explicit resume appends only a matching validated 206 range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    try writeTestPartial(root, "pinned", "\"immutable-test\"");

    var transport = ResumingTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(ResumingTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.resumePartial("hf_secret");

    try std.testing.expectEqual(@as(u64, 6), transport.first_offset.?);
    try std.testing.expectEqualStrings("\"immutable-test\"", transport.if_range.?.value());
    try std.testing.expect(try activeInstallationPresent(std.testing.io, root, test_manifest));
}

test "resume discards a partial when the server validator does not match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    try writeTestPartial(root, "pinned", "\"immutable-test\"");

    var transport = MismatchedResumeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(MismatchedResumeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try std.testing.expectError(error.ResumeResponseMismatch, operation.resumePartial("hf_secret"));
    try std.testing.expectEqual(OperationPhase.idle, (try operation.recover()).phase);
    try std.testing.expect(!smoke.called);
}

test "resume discards a partial when the server range is incompatible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    try writeTestPartial(root, "pinned", "\"immutable-test\"");

    var transport = IncompatibleRangeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(IncompatibleRangeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try std.testing.expectError(error.ModelDownloadRangeMismatch, operation.resumePartial("hf_secret"));
    try std.testing.expectEqual(OperationPhase.idle, (try operation.recover()).phase);
}

test "resume discards a partial when the server validator is malformed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    try writeTestPartial(root, "pinned", "\"immutable-test\"");

    var transport = MalformedValidatorTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(MalformedValidatorTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try std.testing.expectError(error.InvalidModelValidator, operation.resumePartial("hf_secret"));
    try std.testing.expectEqual(OperationPhase.idle, (try operation.recover()).phase);
}

test "range response validation requires exact 206 identity validator and byte interval" {
    const expected_validator = try Validator.init(.etag, "\"immutable-test\"");
    const request = DownloadRequest{
        .offset = 6,
        .end = 16,
        .total = 17,
        .validator = expected_validator,
        .cancel = undefined,
    };
    const valid = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 11\r\nContent-Range: bytes 6-16/17\r\nETag: \"immutable-test\"\r\n\r\n",
    );
    try std.testing.expect(Validator.eql(expected_validator, try validateRangeResponse(valid, request)));

    const full_response = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Length: 17\r\nETag: \"immutable-test\"\r\n\r\n",
    );
    try std.testing.expectError(error.ResumeResponseMismatch, validateRangeResponse(full_response, request));

    const wrong_range = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 11\r\nContent-Range: bytes 0-10/17\r\nETag: \"immutable-test\"\r\n\r\n",
    );
    try std.testing.expectError(error.ModelDownloadRangeMismatch, validateRangeResponse(wrong_range, request));

    const transient = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n",
    );
    try std.testing.expectError(error.ModelDownloadFailed, validateRangeResponse(transient, request));

    const weak = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 11\r\nContent-Range: bytes 6-16/17\r\nETag: W/\"immutable-test\"\r\n\r\n",
    );
    try std.testing.expectError(error.InvalidModelValidator, validateRangeResponse(weak, request));

    var fresh_request = request;
    fresh_request.validator = null;
    const last_modified_fallback = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 11\r\nContent-Range: bytes 6-16/17\r\nETag: W/\"immutable-test\"\r\nLast-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\n\r\n",
    );
    try std.testing.expectEqual(
        ValidatorKind.last_modified,
        (try validateRangeResponse(last_modified_fallback, fresh_request)).kind,
    );
}

test "transient download retries stop at a bounded visible budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var transport = AlwaysTransientTransport{};
    var smoke = FakeSmoke{};
    var events = EventLog{};
    var operation = Operation(AlwaysTransientTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root_buf[0..root_len], test_manifest, &transport, &smoke);
    operation.retry_delay_ms = 0;
    operation.observer = .{ .ctx = &events, .on_event = EventLog.record };

    try std.testing.expectError(error.ModelDownloadRetryBudgetExhausted, operation.install("hf_secret"));
    try std.testing.expectEqual(@as(usize, 4), transport.requests);
    try std.testing.expectEqual(@as(usize, 3), events.retries);
    try std.testing.expect(!smoke.called);
}

test "retry budget is bounded across the complete multi-chunk operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var transport = IntermittentTransport{};
    var smoke = FakeSmoke{};
    var events = EventLog{};
    var operation = Operation(IntermittentTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root_buf[0..root_len], test_manifest, &transport, &smoke);
    operation.chunk_size = 4;
    operation.retry_delay_ms = 0;
    operation.observer = .{ .ctx = &events, .on_event = EventLog.record };

    try std.testing.expectError(error.ModelDownloadRetryBudgetExhausted, operation.install("hf_secret"));
    try std.testing.expectEqual(@as(usize, 7), transport.requests);
    try std.testing.expectEqual(@as(usize, 3), events.retries);
}

test "a truncated transfer is retried visibly before installation continues" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var transport = TruncatedThenSuccessTransport{};
    var smoke = FakeSmoke{};
    var events = EventLog{};
    var operation = Operation(TruncatedThenSuccessTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root_buf[0..root_len], test_manifest, &transport, &smoke);
    operation.retry_delay_ms = 0;
    operation.observer = .{ .ctx = &events, .on_event = EventLog.record };

    try operation.install("hf_secret");
    try std.testing.expectEqual(@as(usize, 2), transport.requests);
    try std.testing.expectEqual(@as(usize, 1), events.retries);
}

test "cancellation during hashing preserves the active installation boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = "previous installation\n" });
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var cancel_on_hash = CancelOnHash{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    cancel_on_hash.cancel = &operation.cancel;
    operation.observer = .{ .ctx = &cancel_on_hash, .on_event = CancelOnHash.record };

    try std.testing.expectError(error.ModelOperationCancelled, operation.install("hf_secret"));
    var receipt_buf: [64]u8 = undefined;
    const receipt_text = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &receipt_buf);
    try std.testing.expectEqualStrings("previous installation\n", receipt_text);
    try std.testing.expect(!smoke.called);
    const recovery = try operation.recover();
    try std.testing.expectEqual(OperationPhase.paused, recovery.phase);
    try std.testing.expectEqual(test_manifest.size, recovery.bytes.completed);
}

test "cancellation during transfer leaves the working receipt untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = "working\n" });
    var transport = CancellingTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(CancellingTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);

    try std.testing.expectError(error.ModelOperationCancelled, operation.install("hf_secret"));
    var receipt_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("working\n", try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &receipt_buf));
    try std.testing.expect(!smoke.called);
}

test "cancellation during smoke testing pauses the verified download before activation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = CancellingSmoke{};
    var operation = Operation(FakeTransport, CancellingSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);

    try std.testing.expectError(error.ModelOperationCancelled, operation.install("hf_secret"));
    try std.testing.expectEqual(OperationPhase.paused, (try operation.recover()).phase);
    try std.testing.expect(!try activeInstallationPresent(std.testing.io, root, test_manifest));
}

const test_bytes = "pinned test model";
const test_manifest = Manifest.forTest();

const FakeTransport = struct {
    pub fn download(_: *FakeTransport, _: []const u8, _: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const CountingTransport = struct {
    requests: usize = 0,
};

const AlwaysTransientTransport = struct {
    requests: usize = 0,

    pub fn download(self: *AlwaysTransientTransport, _: []const u8, _: []const u8, _: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
        self.requests += 1;
        return error.ModelDownloadFailed;
    }
};

const IntermittentTransport = struct {
    requests: usize = 0,

    pub fn download(self: *IntermittentTransport, _: []const u8, _: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        self.requests += 1;
        if (self.requests % 2 == 1) return error.ModelDownloadFailed;
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const TruncatedThenSuccessTransport = struct {
    requests: usize = 0,

    pub fn download(self: *TruncatedThenSuccessTransport, _: []const u8, _: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        self.requests += 1;
        if (self.requests == 1) return error.ModelDownloadTruncated;
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const CancellingTransport = struct {
    pub fn download(_: *CancellingTransport, _: []const u8, _: []const u8, request: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
        request.cancel.request();
        return error.ModelOperationCancelled;
    }
};

const EventLog = struct {
    retries: usize = 0,

    fn record(ctx: *anyopaque, event: OperationEvent) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        if (event == .retrying) self.retries += 1;
    }
};

const CancelOnHash = struct {
    cancel: *CancelToken = undefined,

    fn record(ctx: *anyopaque, event: OperationEvent) void {
        const self: *CancelOnHash = @ptrCast(@alignCast(ctx));
        if (event == .verifying) self.cancel.request();
    }
};

const ResumingTransport = struct {
    first_offset: ?u64 = null,
    if_range: ?Validator = null,

    pub fn download(self: *ResumingTransport, _: []const u8, _: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        if (self.first_offset == null) {
            self.first_offset = request.offset;
            self.if_range = request.validator.?;
        }
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const MismatchedResumeTransport = struct {
    pub fn download(_: *MismatchedResumeTransport, _: []const u8, _: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"different\"");
    }
};

const IncompatibleRangeTransport = struct {
    pub fn download(_: *IncompatibleRangeTransport, _: []const u8, _: []const u8, _: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
        return error.ModelDownloadRangeMismatch;
    }
};

const MalformedValidatorTransport = struct {
    pub fn download(_: *MalformedValidatorTransport, _: []const u8, _: []const u8, _: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
        return error.InvalidModelValidator;
    }
};

fn writeTestPartial(root: []const u8, bytes: []const u8, etag: []const u8) !void {
    const stage = try std.fmt.allocPrint(std.testing.allocator, "{s}/staging-{s}", .{ root, test_manifest.installation_id });
    defer std.testing.allocator.free(stage);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, stage);
    const model = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ stage, test_manifest.artifact });
    defer std.testing.allocator.free(model);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model, .data = bytes });
    const metadata = try std.fmt.allocPrint(
        std.testing.allocator,
        "schema=1\nrepository={s}\nrevision={s}\nruntime={s}\nartifact={s}\ninstallation_id={s}\nsize={d}\nsha256={s}\noffset={d}\netag={s}\nlast_modified=\n",
        .{ test_manifest.repository, test_manifest.revision, test_manifest.runtime, test_manifest.artifact, test_manifest.installation_id, test_manifest.size, &std.fmt.bytesToHex(test_manifest.sha256, .lower), bytes.len, etag },
    );
    defer std.testing.allocator.free(metadata);
    const metadata_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/partial.meta", .{stage});
    defer std.testing.allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = metadata_path, .data = metadata });
}

const FakeSmoke = struct {
    called: bool = false,
    pub fn run(self: *FakeSmoke, _: []const u8, cancel: *const CancelToken) ![32]u8 {
        if (cancel.isRequested()) return error.ModelOperationCancelled;
        self.called = true;
        return @splat(0x5a);
    }
};

const BadTransport = struct {
    pub fn download(_: *BadTransport, _: []const u8, _: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        const bad_bytes = "tinned test model";
        try writer.writeAll(bad_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const ShortTransport = struct {
    pub fn download(_: *ShortTransport, _: []const u8, _: []const u8, _: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        try writer.writeAll("wrong");
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const FailingSmoke = struct {
    pub fn run(_: *FailingSmoke, _: []const u8, _: *const CancelToken) ![32]u8 {
        return error.HelperSmokeTestFailed;
    }
};

const CancellingSmoke = struct {
    pub fn run(_: *CancellingSmoke, _: []const u8, cancel: *const CancelToken) ![32]u8 {
        @constCast(cancel).request();
        return error.ModelOperationCancelled;
    }
};
