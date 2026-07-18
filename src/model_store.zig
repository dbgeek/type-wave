//! Explicit, credential-free Model Operations for the pinned local Whisper installation.

const std = @import("std");
const artifact_identity = @import("artifact_identity.zig");
const installation_identity = @import("installation_identity.zig");

const StatFs = extern struct {
    block_size: u32,
    io_size: i32,
    blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    files: u64,
    free_files: u64,
    fsid: [2]i32,
    owner: u32,
    fs_type: u32,
    flags: u32,
    subtype: u32,
    type_name: [16]u8,
    mounted_on: [std.fs.max_path_bytes]u8,
    mounted_from: [std.fs.max_path_bytes]u8,
    extended_flags: u32,
    reserved: [7]u32,
};

extern "c" fn statfs(path: [*:0]const u8, stats: *StatFs) c_int;
const staging_overhead_bytes: u64 = 16 * 1024 * 1024;

/// Bytes fetched per HTTP Range request during a Model Installation download, and the
/// resume checkpoint granularity. Each chunk is one request that re-resolves the
/// HuggingFace→CDN redirect, then fsyncs the file and rewrites `partial.meta` — so a
/// small chunk turns one download into thousands of serialized round-trips (the former
/// 1 MiB default made the ~1.6 GB pinned model ~1550 requests, ~10 min vs. under 1 min
/// for a single streamed GET). Larger coarsens resume: an interrupted download re-fetches
/// at most one chunk. 32 MiB keeps the pinned model near ~50 requests while re-downloading
/// at most 32 MiB on resume.
const default_chunk_size: u64 = 32 * 1024 * 1024;
const removal_intent_name = ".removal.pending";
const runtime_lock_name = ".runtime.lock";
const inference_lock_name = ".inference.lock";

pub const pinned_manifest = Manifest{
    .repository = "ggerganov/whisper.cpp",
    .revision = "98aa99a0a9db05ae2342309f5096248665f7cba3",
    .artifact = "ggml-large-v3-turbo.bin",
    .installation_id = "98aa99a0a9db-f16",
    .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo.bin",
    .size = 1_624_555_275,
    .sha256 = .{
        0x1f, 0xc7, 0x0f, 0x77, 0x4d, 0x38, 0xeb, 0x16,
        0x99, 0x93, 0xac, 0x39, 0x1e, 0xea, 0x35, 0x7e,
        0xf4, 0x7c, 0x88, 0x75, 0x7e, 0xf7, 0x2e, 0xe5,
        0x94, 0x38, 0x79, 0xb7, 0xe8, 0xe2, 0xbc, 0x69,
    },
};

/// Every release keeps manifests for still-supported older Model Installations here so
/// integrity verification can authenticate their receipts without treating an available
/// update as corruption.
pub const trusted_manifests = [_]Manifest{pinned_manifest};

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
    removing,
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

pub const ArtifactIdentity = artifact_identity.Identity;
pub const InstallationIdentity = installation_identity.Identity;

pub const Corruption = enum {
    invalid_receipt,
    identity_mismatch,
    missing_artifact,
    size_mismatch,
    digest_mismatch,
    provenance_mismatch,
    manifest_mismatch,
};

pub const InstallationIntegrity = union(enum) {
    absent,
    usable: ArtifactIdentity,
    corrupt: Corruption,
};

const ActivationPolicy = enum { preserve_existing, replace_invalid };

/// Repair always verifies offline first; the caller decides separately whether the
/// operation may fall back to re-downloading invalid artifact data.
pub const NetworkPolicy = enum { offline_only, allow_network };

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
    waiting_for_inference,
    activating,
    removing,
};

pub const Observer = struct {
    ctx: *anyopaque,
    on_event: *const fn (*anyopaque, OperationEvent) void,
};

/// A cross-process shared lease held only while one local Utterance is using the active
/// Model Installation. Replacement activation takes the exclusive side of the same lock.
const SharedFileLease = struct {
    io: std.Io,
    file: ?std.Io.File,

    fn acquire(io: std.Io, root: []const u8, lock_name: []const u8, intent_name: []const u8, blocked: anyerror) !SharedFileLease {
        try std.Io.Dir.cwd().createDirPath(io, root);
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, lock_name });
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .lock = .shared });
        var lease = SharedFileLease{ .io = io, .file = file };
        errdefer lease.release();
        if (intentFilePresent(io, root, intent_name)) return blocked;
        return lease;
    }

    fn release(self: *SharedFileLease) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }
};

pub const InferenceLease = struct {
    shared: SharedFileLease,

    pub fn acquire(io: std.Io, root: []const u8) !InferenceLease {
        return .{ .shared = try SharedFileLease.acquire(io, root, inference_lock_name, removal_intent_name, error.ModelRemovalInProgress) };
    }

    pub fn release(self: *InferenceLease) void {
        self.shared.release();
    }
};

/// Held for the complete lifetime of a warmed local helper. Removal takes the exclusive
/// side only after publishing its intent, so the daemon rejects new Utterances, drains the
/// active one, shuts the helper down, and only then lets model files disappear.
pub const RuntimeLease = struct {
    shared: SharedFileLease,

    pub fn acquire(io: std.Io, root: []const u8) !RuntimeLease {
        return .{ .shared = try SharedFileLease.acquire(io, root, runtime_lock_name, removal_intent_name, error.ModelRemovalInProgress) };
    }

    pub fn release(self: *RuntimeLease) void {
        self.shared.release();
    }

    pub fn take(self: *RuntimeLease) RuntimeLease {
        const moved = self.*;
        self.shared.file = null;
        return moved;
    }
};

pub fn modelRemovalPending(io: std.Io, root: []const u8) bool {
    return intentFilePresent(io, root, removal_intent_name);
}

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
        additional_trusted_manifests: ?[]const Manifest = null,
        retry_budget: u8 = 3,
        retry_delay_ms: u32 = 1000,
        chunk_size: u64 = default_chunk_size,

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

        fn beginLocked(self: *Self) !LockedOperation {
            try std.Io.Dir.cwd().createDirPath(self.io, self.root);
            const path = try std.fmt.allocPrint(self.allocator, "{s}/.operation.lock", .{self.root});
            errdefer self.allocator.free(path);
            const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .lock = .exclusive });
            return .{ .allocator = self.allocator, .io = self.io, .path = path, .file = file };
        }

        /// Acquisition is credential-free, but it may still only start at the exact
        /// trusted origin embedded in the pinned manifest.
        fn beginAcquisition(self: *Self) !LockedOperation {
            if (!isHuggingFaceOrigin(self.manifest.url)) return error.UntrustedArtifactOrigin;
            return self.beginLocked();
        }

        fn stagePaths(self: *Self) !StagePaths {
            const directory = try std.fmt.allocPrint(self.allocator, "{s}/staging-{s}", .{ self.root, self.manifest.installation_id });
            errdefer self.allocator.free(directory);
            const model = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory, self.manifest.artifact });
            return .{ .allocator = self.allocator, .directory = directory, .model = model };
        }

        /// One explicit Model Operation: acquire, verify, smoke-test, then publish.
        /// Nothing before the final receipt rename can replace the active installation.
        pub fn install(self: *Self) !void {
            const locked = try self.beginAcquisition();
            defer locked.deinit();
            if (try activeInstallationPresent(self.io, self.root, self.manifest)) return;

            if ((try loadPartial(self.io, self.root, self.manifest)) != null)
                return error.PartialRequiresExplicitResume;
            try self.preflightCapacity(self.manifest.size);

            const paths = try self.stagePaths();
            defer paths.deinit();
            try discardStage(self.io, paths.directory);
            try std.Io.Dir.cwd().createDirPath(self.io, paths.directory);
            var file = try std.Io.Dir.cwd().createFile(self.io, paths.model, .{ .read = true, .permissions = .fromMode(0o600) });
            defer file.close(self.io);
            try self.acquire(paths.directory, file, 0, null);
            try self.activate(paths.model, paths.directory, .preserve_existing);
        }

        pub fn resumePartial(self: *Self) !void {
            const locked = try self.beginAcquisition();
            defer locked.deinit();
            const partial = (try loadPartial(self.io, self.root, self.manifest)) orelse return error.NoResumablePartial;
            try self.preflightCapacity(self.manifest.size - partial.offset);
            const paths = try self.stagePaths();
            defer paths.deinit();
            var file = try std.Io.Dir.cwd().openFile(self.io, paths.model, .{ .mode = .read_write });
            defer file.close(self.io);
            self.acquire(paths.directory, file, partial.offset, partial.validator) catch |failure| {
                if (isIncompatibleResumeFailure(failure)) try discardStage(self.io, paths.directory);
                return failure;
            };
            try self.activate(paths.model, paths.directory, .preserve_existing);
        }

        /// Explicit, filesystem-only full verification of the active Model Installation.
        /// This deliberately performs no smoke test and cannot access the network:
        /// a verified artifact that still will not load is a runtime failure.
        pub fn verify(self: *Self) !InstallationIntegrity {
            const locked = try self.beginLocked();
            defer locked.deinit();
            return verifyActiveInstallationUnlocked(self.io, self.root, self.manifest, self.additional_trusted_manifests, &self.cancel, self.observer);
        }

        /// Repair always starts with the same full offline verification as Verify. A
        /// usable installation is left byte-for-byte untouched and needs no network.
        pub fn repair(self: *Self, network: NetworkPolicy) !void {
            const locked = try self.beginLocked();
            defer locked.deinit();
            const integrity = try verifyActiveInstallationUnlocked(self.io, self.root, self.manifest, self.additional_trusted_manifests, &self.cancel, self.observer);
            const desired_manifest = self.manifest;
            defer self.manifest = desired_manifest;
            var trusted_receipt_buffer: [1024]u8 = undefined;
            if (try activeReceipt(self.io, self.root, &trusted_receipt_buffer)) |actual| {
                if (trustedManifest(actual, desired_manifest, self.additional_trusted_manifests)) |active_manifest|
                    self.manifest = active_manifest;
            }
            const corruption = switch (integrity) {
                .usable => return,
                .absent => return error.NoModelInstallation,
                .corrupt => |reason| switch (reason) {
                    .provenance_mismatch, .manifest_mismatch => {
                        var receipt_buffer: [1024]u8 = undefined;
                        const active = (try activeReceipt(self.io, self.root, &receipt_buffer)) orelse return error.NoModelInstallation;
                        if (!receiptMatchesManifest(active, self.manifest)) return error.ModelInstallationIdentityMismatch;
                        const runtime_sha256 = receiptRuntimeDigest(active) orelse return error.ModelInstallationMetadataInvalid;
                        const parsed = parseActiveReceipt(active) orelse return error.ModelInstallationMetadataInvalid;
                        const physical_id = parsed.directory_id orelse self.manifest.installation_id;
                        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
                        const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/installations/{s}", .{ self.root, physical_id });
                        var model_buffer: [std.fs.max_path_bytes]u8 = undefined;
                        const model = try std.fmt.bufPrint(&model_buffer, "{s}/{s}", .{ directory, self.manifest.artifact });
                        const stat = try verifyArtifactCancelable(self.io, model, self.manifest, &self.cancel, self.observer);
                        try writeArtifactManifest(self.io, directory, self.manifest);
                        const generation = if (parsed.schema == .generation) physical_id else null;
                        try writeProvenanceForDirectory(self.io, directory, self.manifest, generation, runtime_sha256, stat);
                        try publishReceiptForDirectory(self.io, self.root, self.manifest, generation, runtime_sha256, stat);
                        return;
                    },
                    else => reason,
                },
            };
            if (corruption == .invalid_receipt) {
                self.rebuildKnownInstallationMetadata() catch |failure| switch (failure) {
                    error.FileNotFound, error.ModelSizeMismatch, error.ModelDigestMismatch => {},
                    else => return failure,
                };
                if ((try verifyActiveInstallationUnlocked(self.io, self.root, self.manifest, self.additional_trusted_manifests, &self.cancel, self.observer)) == .usable) return;
            }
            if (network == .offline_only) return error.ModelRepairRequiresNetwork;
            if (!isHuggingFaceOrigin(self.manifest.url)) return error.UntrustedArtifactOrigin;
            if (corruption != .invalid_receipt) {
                var receipt_buffer: [1024]u8 = undefined;
                const active = (try activeReceipt(self.io, self.root, &receipt_buffer)) orelse return error.NoModelInstallation;
                if (!receiptMatchesManifest(active, self.manifest)) return error.ModelInstallationIdentityMismatch;
            }

            const paths = try self.stagePaths();
            defer paths.deinit();
            if (try loadPartial(self.io, self.root, self.manifest)) |partial| {
                try self.preflightCapacity(self.manifest.size - partial.offset);
                var file = try std.Io.Dir.cwd().openFile(self.io, paths.model, .{ .mode = .read_write });
                defer file.close(self.io);
                self.acquire(paths.directory, file, partial.offset, partial.validator) catch |failure| {
                    if (isIncompatibleResumeFailure(failure)) try discardStage(self.io, paths.directory);
                    return failure;
                };
            } else {
                try self.preflightCapacity(self.manifest.size);
                try discardStage(self.io, paths.directory);
                try std.Io.Dir.cwd().createDirPath(self.io, paths.directory);
                var file = try std.Io.Dir.cwd().createFile(self.io, paths.model, .{ .read = true, .permissions = .fromMode(0o600) });
                defer file.close(self.io);
                try self.acquire(paths.directory, file, 0, null);
            }
            try self.activate(paths.model, paths.directory, .replace_invalid);
        }

        /// Confirmed removal is credential-free and serialized with every other Model
        /// Operation. The intent marker makes selected-local readiness unavailable before
        /// the exclusive runtime/inference gates allow any model bytes to be removed.
        pub fn remove(self: *Self) !void {
            const locked = try self.beginLocked();
            defer locked.deinit();
            try writeIntentFile(self.io, self.root, removal_intent_name);
            defer removeIntentFile(self.io, self.root, removal_intent_name);

            self.notify(.waiting_for_inference);
            var runtime = try waitForExclusiveLease(self.io, self.root, runtime_lock_name, &self.cancel);
            defer runtime.close(self.io);
            var inference = try waitForExclusiveLease(self.io, self.root, inference_lock_name, &self.cancel);
            defer inference.close(self.io);

            self.notify(.removing);
            try removeModelData(self.io, self.root);
        }

        fn rebuildKnownInstallationMetadata(self: *Self) !void {
            var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/installations/{s}", .{ self.root, self.manifest.installation_id });
            var model_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const model = try std.fmt.bufPrint(&model_buffer, "{s}/{s}", .{ directory, self.manifest.artifact });
            const stat = try verifyArtifactCancelable(self.io, model, self.manifest, &self.cancel, self.observer);
            self.notify(.smoke_testing);
            const runtime_sha256 = try self.smoke.run(model, &self.cancel);
            try writeArtifactManifest(self.io, directory, self.manifest);
            try writeProvenance(self.io, directory, self.manifest, runtime_sha256, stat);
            try publishReceipt(self.io, self.root, self.manifest, runtime_sha256, stat);
        }

        fn preflightCapacity(self: *Self, remaining_artifact_bytes: u64) !void {
            const path = try self.allocator.alloc(u8, self.root.len + 1);
            defer self.allocator.free(path);
            @memcpy(path[0..self.root.len], self.root);
            path[self.root.len] = 0;
            var stats: StatFs = undefined;
            if (statfs(@ptrCast(path.ptr), &stats) != 0) return error.ModelCapacityCheckFailed;
            if (!capacitySufficient(stats.block_size, stats.available_blocks, remaining_artifact_bytes))
                return error.InsufficientModelStorage;
        }

        fn acquire(self: *Self, stage_dir: []const u8, file: std.Io.File, starting_offset: u64, starting_validator: ?Validator) !void {
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
                    break self.transport.download(self.manifest.url, request, &writer) catch |failure| {
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

        fn activate(self: *Self, stage_model: []const u8, stage_dir: []const u8, policy: ActivationPolicy) !void {
            var prepared = self.prepareInstallation(stage_model, stage_dir) catch |failure| {
                if (failure == error.ModelSizeMismatch or failure == error.ModelDigestMismatch)
                    try discardStage(self.io, stage_dir);
                return failure;
            };
            if (self.cancel.isRequested()) return error.ModelOperationCancelled;
            self.notify(.waiting_for_inference);
            var activation_lock = try waitForInferenceDrain(self.io, self.root, &self.cancel);
            defer activation_lock.close(self.io);

            const installations = try std.fmt.allocPrint(self.allocator, "{s}/installations", .{self.root});
            defer self.allocator.free(installations);
            try std.Io.Dir.cwd().createDirPath(self.io, installations);
            if (policy == .replace_invalid) {
                const directory_id = try std.fmt.allocPrint(self.allocator, "{s}-repair-{d}", .{ self.manifest.installation_id, prepared.stat.mtime.nanoseconds });
                defer self.allocator.free(directory_id);
                const repaired_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ installations, directory_id });
                defer self.allocator.free(repaired_dir);
                try writeProvenanceForDirectory(self.io, stage_dir, self.manifest, directory_id, prepared.runtime_sha256, prepared.stat);
                var metadata_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const metadata_path = try std.fmt.bufPrint(&metadata_path_buffer, "{s}/partial.meta", .{stage_dir});
                std.Io.Dir.cwd().deleteFile(self.io, metadata_path) catch |failure| if (failure != error.FileNotFound) return failure;
                self.notify(.activating);
                try std.Io.Dir.renameAbsolute(stage_dir, repaired_dir, self.io);
                publishReceiptForDirectory(self.io, self.root, self.manifest, directory_id, prepared.runtime_sha256, prepared.stat) catch |failure| {
                    std.Io.Dir.renameAbsolute(repaired_dir, stage_dir, self.io) catch {};
                    return failure;
                };
                return;
            }
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
            try writeArtifactManifest(self.io, directory, self.manifest);
            self.notify(.smoke_testing);
            const runtime_sha256 = try self.smoke.run(model_path, &self.cancel);
            if (self.cancel.isRequested()) return error.ModelOperationCancelled;
            try writeProvenance(self.io, directory, self.manifest, runtime_sha256, stat);
            return .{ .stat = stat, .runtime_sha256 = runtime_sha256 };
        }
    };
}

fn capacitySufficient(block_size: u32, available_blocks: u64, remaining_artifact_bytes: u64) bool {
    const available = std.math.mul(u64, block_size, available_blocks) catch std.math.maxInt(u64);
    const required = std.math.add(u64, remaining_artifact_bytes, staging_overhead_bytes) catch return false;
    return available >= required;
}

fn waitForInferenceDrain(io: std.Io, root: []const u8, cancel: *const CancelToken) !std.Io.File {
    return waitForExclusiveLease(io, root, inference_lock_name, cancel);
}

fn waitForExclusiveLease(io: std.Io, root: []const u8, lock_name: []const u8, cancel: *const CancelToken) !std.Io.File {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, lock_name });
    while (true) {
        if (cancel.isRequested()) return error.ModelOperationCancelled;
        return std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive, .lock_nonblocking = true }) catch |failure| switch (failure) {
            error.WouldBlock => {
                try std.Io.sleep(io, .fromMilliseconds(50), .awake);
                continue;
            },
            else => return failure,
        };
    }
}

fn intentFilePresent(io: std.Io, root: []const u8, name: []const u8) bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, name }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeIntentFile(io: std.Io, root: []const u8, name: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, name });
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    file.close(io);
}

fn removeIntentFile(io: std.Io, root: []const u8, name: []const u8) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, name }) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn removeModelData(io: std.Io, root: []const u8) !void {
    var receipt_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buffer, "{s}/active.receipt", .{root});
    std.Io.Dir.cwd().deleteFile(io, receipt_path) catch |failure| if (failure != error.FileNotFound) return failure;
    var receipt_tmp_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_tmp = try std.fmt.bufPrint(&receipt_tmp_path_buffer, "{s}/active.receipt.tmp", .{root});
    std.Io.Dir.cwd().deleteFile(io, receipt_tmp) catch |failure| if (failure != error.FileNotFound) return failure;
    var installations_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const installations = try std.fmt.bufPrint(&installations_path_buffer, "{s}/installations", .{root});
    std.Io.Dir.cwd().deleteTree(io, installations) catch |failure| if (failure != error.FileNotFound) return failure;

    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    var entries = root_dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "staging-"))
            try root_dir.deleteTree(io, entry.name);
    }
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
    return receiptForDirectory(manifest, null, runtime_sha256, model_stat, buffer);
}

fn receiptForDirectory(manifest: Manifest, directory_id: ?[]const u8, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat, buffer: []u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(manifest.sha256, .lower);
    const runtime_hex = std.fmt.bytesToHex(runtime_sha256, .lower);
    if (directory_id) |physical| return std.fmt.bufPrint(
        buffer,
        "schema=3\nrepository={s}\nrevision={s}\nruntime={s}\nruntime_sha256={s}\nartifact={s}\ninstallation_id={s}\ndirectory_id={s}\nsize={d}\nmodel_mtime_ns={d}\nsha256={s}\ninstalled_by=type-wave-v{s}\n",
        .{ manifest.repository, manifest.revision, manifest.runtime, &runtime_hex, manifest.artifact, manifest.installation_id, physical, manifest.size, model_stat.mtime.nanoseconds, &hex, manifest.installer_version },
    );
    return std.fmt.bufPrint(
        buffer,
        "schema=2\nrepository={s}\nrevision={s}\nruntime={s}\nruntime_sha256={s}\nartifact={s}\ninstallation_id={s}\nsize={d}\nmodel_mtime_ns={d}\nsha256={s}\ninstalled_by=type-wave-v{s}\n",
        .{ manifest.repository, manifest.revision, manifest.runtime, &runtime_hex, manifest.artifact, manifest.installation_id, manifest.size, model_stat.mtime.nanoseconds, &hex, manifest.installer_version },
    );
}

fn writeProvenance(io: std.Io, directory: []const u8, manifest: Manifest, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat) !void {
    return writeProvenanceForDirectory(io, directory, manifest, null, runtime_sha256, model_stat);
}

fn writeProvenanceForDirectory(io: std.Io, directory: []const u8, manifest: Manifest, directory_id: ?[]const u8, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat) !void {
    var text_buffer: [1024]u8 = undefined;
    const text = try receiptForDirectory(manifest, directory_id, runtime_sha256, model_stat, &text_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/PROVENANCE", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
}

fn writeArtifactManifest(io: std.Io, directory: []const u8, manifest: Manifest) !void {
    const digest = std.fmt.bytesToHex(manifest.sha256, .lower);
    var text_buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buffer, "size={d}\nsha256={s}\n", .{ manifest.size, &digest });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/MODEL_MANIFEST", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
}

fn publishReceipt(io: std.Io, root: []const u8, manifest: Manifest, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat) !void {
    return publishReceiptForDirectory(io, root, manifest, null, runtime_sha256, model_stat);
}

fn publishReceiptForDirectory(io: std.Io, root: []const u8, manifest: Manifest, directory_id: ?[]const u8, runtime_sha256: [32]u8, model_stat: std.Io.File.Stat) !void {
    var text_buffer: [1024]u8 = undefined;
    const text = try receiptForDirectory(manifest, directory_id, runtime_sha256, model_stat, &text_buffer);
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
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if ((try activeModelPath(io, root, &path_buffer)) == null) return false;

    var receipt_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buffer, "{s}/active.receipt", .{root});
    var actual_buffer: [1024]u8 = undefined;
    const actual = std.Io.Dir.cwd().readFile(io, receipt_path, &actual_buffer) catch |failure| switch (failure) {
        error.FileNotFound => return false,
        else => return failure,
    };
    return receiptMatchesManifest(actual, manifest);
}

fn safePathComponent(value: []const u8) bool {
    return value.len > 0 and
        !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..") and
        std.mem.indexOfAny(u8, value, "/\\") == null;
}

const ReceiptSchema = enum { legacy, immutable, generation };

const ParsedReceipt = struct {
    schema: ReceiptSchema,
    artifact: []const u8,
    installation_id: ?[]const u8,
    directory_id: ?[]const u8,
    identity: ArtifactIdentity,
    mtime_ns: i96,
};

fn parseActiveReceipt(actual: []const u8) ?ParsedReceipt {
    const schema_text = receiptValue(actual, "schema=") orelse return null;
    const artifact = receiptValue(actual, "artifact=") orelse return null;
    if (!safePathComponent(artifact)) return null;
    const identity = receiptArtifact(actual) orelse return null;
    const mtime_ns = std.fmt.parseInt(i96, receiptValue(actual, "model_mtime_ns=") orelse return null, 10) catch return null;
    if (receiptRuntimeDigest(actual) == null) return null;
    if (std.mem.eql(u8, schema_text, "1")) return .{
        .schema = .legacy,
        .artifact = artifact,
        .installation_id = null,
        .directory_id = null,
        .identity = identity,
        .mtime_ns = mtime_ns,
    };
    const installation_id = receiptValue(actual, "installation_id=") orelse return null;
    if (!safePathComponent(installation_id)) return null;
    if (std.mem.eql(u8, schema_text, "2")) return .{
        .schema = .immutable,
        .artifact = artifact,
        .installation_id = installation_id,
        .directory_id = installation_id,
        .identity = identity,
        .mtime_ns = mtime_ns,
    };
    if (!std.mem.eql(u8, schema_text, "3")) return null;
    const directory_id = receiptValue(actual, "directory_id=") orelse return null;
    if (!safePathComponent(directory_id)) return null;
    return .{
        .schema = .generation,
        .artifact = artifact,
        .installation_id = installation_id,
        .directory_id = directory_id,
        .identity = identity,
        .mtime_ns = mtime_ns,
    };
}

fn receiptMatchesManifest(actual: []const u8, manifest: Manifest) bool {
    var size_buffer: [32]u8 = undefined;
    const expected_size = std.fmt.bufPrint(&size_buffer, "{d}", .{manifest.size}) catch return false;
    const expected_digest = std.fmt.bytesToHex(manifest.sha256, .lower);
    const parsed = parseActiveReceipt(actual) orelse return false;
    const installation_matches = parsed.schema == .legacy or std.mem.eql(u8, parsed.installation_id.?, manifest.installation_id);
    return installation_matches and
        std.mem.eql(u8, receiptValue(actual, "repository=") orelse return false, manifest.repository) and
        std.mem.eql(u8, receiptValue(actual, "revision=") orelse return false, manifest.revision) and
        std.mem.eql(u8, receiptValue(actual, "runtime=") orelse return false, manifest.runtime) and
        std.mem.eql(u8, receiptValue(actual, "artifact=") orelse return false, manifest.artifact) and
        std.mem.eql(u8, receiptValue(actual, "size=") orelse return false, expected_size) and
        std.mem.eql(u8, receiptValue(actual, "sha256=") orelse return false, &expected_digest);
}

fn trustedManifest(actual: []const u8, expected: Manifest, additional: ?[]const Manifest) ?Manifest {
    if (receiptMatchesManifest(actual, expected)) return expected;
    if (additional) |manifests| for (manifests) |manifest| {
        if (receiptMatchesManifest(actual, manifest)) return manifest;
    };
    return null;
}

fn activeReceipt(io: std.Io, root: []const u8, buffer: []u8) !?[]const u8 {
    var receipt_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buffer, "{s}/active.receipt", .{root});
    return std.Io.Dir.cwd().readFile(io, receipt_path, buffer) catch |failure| switch (failure) {
        error.FileNotFound => null,
        else => return failure,
    };
}

pub fn verifyActiveInstallation(
    io: std.Io,
    root: []const u8,
    expected: Manifest,
    additional_trusted: ?[]const Manifest,
    cancel: *const CancelToken,
    observer: ?Observer,
) !InstallationIntegrity {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var lock_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_path_buffer, "{s}/.operation.lock", .{root});
    var lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive });
    defer lock.close(io);
    return verifyActiveInstallationUnlocked(io, root, expected, additional_trusted, cancel, observer);
}

fn verifyActiveInstallationUnlocked(
    io: std.Io,
    root: []const u8,
    expected: Manifest,
    additional_trusted: ?[]const Manifest,
    cancel: *const CancelToken,
    observer: ?Observer,
) !InstallationIntegrity {
    var receipt_buffer: [1024]u8 = undefined;
    const actual = (try activeReceipt(io, root, &receipt_buffer)) orelse return .absent;
    const parsed = parseActiveReceipt(actual) orelse return .{ .corrupt = .invalid_receipt };

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (trustedManifest(actual, expected, additional_trusted) == null) return .{ .corrupt = .identity_mismatch };
    const path = if (parsed.directory_id) |directory_id|
        try std.fmt.bufPrint(&path_buffer, "{s}/installations/{s}/{s}", .{ root, directory_id, parsed.artifact })
    else
        (try activeModelPath(io, root, &path_buffer)) orelse return .{ .corrupt = .invalid_receipt };

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |failure| switch (failure) {
        error.FileNotFound => return .{ .corrupt = .missing_artifact },
        else => return failure,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size != parsed.identity.size) return .{ .corrupt = .size_mismatch };
    const digest = try sha256FileObserved(io, path, stat.size, cancel, observer);
    if (!std.mem.eql(u8, &digest, &parsed.identity.sha256)) return .{ .corrupt = .digest_mismatch };

    const installation_dir = std.fs.path.dirname(path) orelse return .{ .corrupt = .invalid_receipt };
    var provenance_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const provenance_path = try std.fmt.bufPrint(&provenance_path_buffer, "{s}/PROVENANCE", .{installation_dir});
    var provenance_buffer: [1024]u8 = undefined;
    const provenance = std.Io.Dir.cwd().readFile(io, provenance_path, &provenance_buffer) catch |failure| switch (failure) {
        error.FileNotFound => return .{ .corrupt = .provenance_mismatch },
        else => return failure,
    };
    if (!std.mem.eql(u8, actual, provenance)) return .{ .corrupt = .provenance_mismatch };
    var manifest_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buffer, "{s}/MODEL_MANIFEST", .{installation_dir});
    var installed_manifest_buffer: [256]u8 = undefined;
    const installed_manifest = std.Io.Dir.cwd().readFile(io, manifest_path, &installed_manifest_buffer) catch |failure| switch (failure) {
        error.FileNotFound => return .{ .corrupt = .manifest_mismatch },
        else => return failure,
    };
    var expected_manifest_buffer: [256]u8 = undefined;
    const expected_manifest = try std.fmt.bufPrint(
        &expected_manifest_buffer,
        "size={d}\nsha256={s}\n",
        .{ parsed.identity.size, &std.fmt.bytesToHex(parsed.identity.sha256, .lower) },
    );
    if (!std.mem.eql(u8, installed_manifest, expected_manifest)) return .{ .corrupt = .manifest_mismatch };
    return .{ .usable = parsed.identity };
}

fn receiptArtifact(actual: []const u8) ?ArtifactIdentity {
    return artifact_identity.parse(actual) catch null;
}

fn receiptRuntimeDigest(receipt_text: []const u8) ?[32]u8 {
    const encoded = receiptValue(receipt_text, "runtime_sha256=") orelse return null;
    if (encoded.len != 64) return null;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return null;
    return digest;
}

fn receiptValue(receipt_text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, receipt_text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const value = line[prefix.len..];
        return if (value.len == 0) null else value;
    }
    return null;
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

pub fn activeModelPath(io: std.Io, root: []const u8, buffer: []u8) !?[]const u8 {
    var receipt_buffer: [1024]u8 = undefined;
    const actual = (try activeReceipt(io, root, &receipt_buffer)) orelse return null;
    const parsed = parseActiveReceipt(actual) orelse return null;
    if (parsed.directory_id) |directory_id|
        return validateReceiptPath(io, root, actual, directory_id, parsed.artifact, parsed.identity.size, parsed.mtime_ns, buffer);

    var installations_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const installations_path = try std.fmt.bufPrint(&installations_path_buffer, "{s}/installations", .{root});
    var installations = std.Io.Dir.cwd().openDir(io, installations_path, .{ .iterate = true }) catch |failure| switch (failure) {
        error.FileNotFound => return null,
        else => return failure,
    };
    defer installations.close(io);
    var entries = installations.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory or !safePathComponent(entry.name)) continue;
        if (try validateReceiptPath(io, root, actual, entry.name, parsed.artifact, parsed.identity.size, parsed.mtime_ns, buffer)) |path| return path;
    }
    return null;
}

fn validateReceiptPath(
    io: std.Io,
    root: []const u8,
    actual: []const u8,
    installation_id: []const u8,
    artifact: []const u8,
    size: u64,
    mtime_ns: i96,
    buffer: []u8,
) !?[]const u8 {
    const path = try std.fmt.bufPrint(buffer, "{s}/installations/{s}/{s}", .{ root, installation_id, artifact });
    var model = std.Io.Dir.cwd().openFile(io, path, .{}) catch |failure| switch (failure) {
        error.FileNotFound => return null,
        else => return failure,
    };
    defer model.close(io);
    const stat = try model.stat(io);
    if (stat.size != size or stat.mtime.nanoseconds != mtime_ns) return null;
    var provenance_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const provenance_path = try std.fmt.bufPrint(&provenance_path_buffer, "{s}/installations/{s}/PROVENANCE", .{ root, installation_id });
    var provenance_buffer: [1024]u8 = undefined;
    const provenance = std.Io.Dir.cwd().readFile(io, provenance_path, &provenance_buffer) catch |failure| switch (failure) {
        error.FileNotFound => return null,
        else => return failure,
    };
    if (!std.mem.eql(u8, actual, provenance)) return null;
    return path;
}

/// Update availability is a comparison between the independently usable active receipt
/// and the complete identity embedded in this type-wave release.
pub fn updateAvailable(io: std.Io, root: []const u8, desired: Manifest) !bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if ((try activeModelPath(io, root, &path_buffer)) == null) return false;
    var receipt_buffer: [1024]u8 = undefined;
    const actual = (try activeReceipt(io, root, &receipt_buffer)) orelse return false;
    return !receiptMatchesManifest(actual, desired);
}

pub fn activeArtifact(io: std.Io, root: []const u8) !?ArtifactIdentity {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if ((try activeModelPath(io, root, &path_buffer)) == null) return null;
    var receipt_buffer: [1024]u8 = undefined;
    const actual = (try activeReceipt(io, root, &receipt_buffer)) orelse return null;
    return receiptArtifact(actual);
}

pub fn activeInstallationIdentity(io: std.Io, root: []const u8) !?InstallationIdentity {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if ((try activeModelPath(io, root, &path_buffer)) == null) return null;
    var receipt_buffer: [1024]u8 = undefined;
    const actual = (try activeReceipt(io, root, &receipt_buffer)) orelse return null;
    const parsed = parseActiveReceipt(actual) orelse return null;
    return .{
        .repository = installation_identity.Text.init(receiptValue(actual, "repository=") orelse return null) catch return null,
        .revision = installation_identity.Text.init(receiptValue(actual, "revision=") orelse return null) catch return null,
        .runtime = installation_identity.Text.init(receiptValue(actual, "runtime=") orelse return null) catch return null,
        .runtime_sha256 = receiptRuntimeDigest(actual) orelse return null,
        .artifact = installation_identity.Text.init(parsed.artifact) catch return null,
        .installation_id = if (parsed.installation_id) |value| installation_identity.Text.init(value) catch return null else null,
        .artifact_size = parsed.identity.size,
        .artifact_sha256 = parsed.identity.sha256,
        .installed_by = installation_identity.Text.init(receiptValue(actual, "installed_by=") orelse return null) catch return null,
    };
}

/// Retire superseded immutable installations after the old helper has drained and shut
/// down. The operation and inference locks make this safe against another process starting
/// maintenance or a late local Utterance.
pub fn removeInactiveInstallations(io: std.Io, root: []const u8) !usize {
    var operation_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const operation_path = try std.fmt.bufPrint(&operation_path_buffer, "{s}/.operation.lock", .{root});
    var operation_lock = std.Io.Dir.cwd().createFile(io, operation_path, .{ .lock = .exclusive, .lock_nonblocking = true }) catch |failure| switch (failure) {
        error.WouldBlock => return error.ModelOperationInProgress,
        else => return failure,
    };
    defer operation_lock.close(io);
    var inference_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const inference_path = try std.fmt.bufPrint(&inference_path_buffer, "{s}/.inference.lock", .{root});
    var inference_lock = std.Io.Dir.cwd().createFile(io, inference_path, .{ .lock = .exclusive, .lock_nonblocking = true }) catch |failure| switch (failure) {
        error.WouldBlock => return error.ModelInferenceActive,
        else => return failure,
    };
    defer inference_lock.close(io);

    var active_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const active_path = (try activeModelPath(io, root, &active_path_buffer)) orelse return 0;
    const active_directory = std.fs.path.dirname(active_path) orelse return error.InvalidModelPath;
    const active_id = std.fs.path.basename(active_directory);
    var installations_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const installations_path = try std.fmt.bufPrint(&installations_path_buffer, "{s}/installations", .{root});
    var installations = try std.Io.Dir.cwd().openDir(io, installations_path, .{ .iterate = true });
    defer installations.close(io);
    var removed: usize = 0;
    var entries = installations.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.eql(u8, entry.name, active_id)) continue;
        try installations.deleteTree(io, entry.name);
        removed += 1;
    }
    return removed;
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

pub const HttpTransport = struct {
    client: *std.http.Client,

    pub fn download(self: *HttpTransport, url: []const u8, download_request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        if (!isHuggingFaceOrigin(url)) return error.UntrustedArtifactOrigin;
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
                return error.ModelDownloadRejected;
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

test "the default chunk size keeps the pinned model download to a modest request count" {
    // Guards the regression this default was raised to fix: a 1 MiB chunk fetched the
    // ~1.6 GB pinned model as ~1550 serialized Range requests. Each chunk is one HTTP
    // round-trip (plus a redirect re-resolve, an fsync, and a checkpoint rewrite), so the
    // request count must stay small.
    const chunks = std.math.divCeil(u64, pinned_manifest.size, default_chunk_size) catch unreachable;
    try std.testing.expect(chunks <= 64);
    // …without coarsening resume so far that an interrupted download re-fetches a large
    // amount: a resume repeats at most one chunk.
    try std.testing.expect(default_chunk_size <= 64 * 1024 * 1024);
}

test "capacity preflight retains the working installation plus staging overhead" {
    const replacement = 500 * 1024 * 1024;
    try std.testing.expect(capacitySufficient(4096, (replacement + staging_overhead_bytes) / 4096, replacement));
    try std.testing.expect(!capacitySufficient(4096, replacement / 4096, replacement));
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
    try operation.install();

    try std.testing.expect(smoke.called);
    try std.testing.expect(try activeInstallationPresent(std.testing.io, root_buf[0..root_len], test_manifest));
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root_buf[0..root_len]});
    var receipt_buf: [1024]u8 = undefined;
    const published = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &receipt_buf);
    try std.testing.expect(std.mem.indexOf(u8, published, "hf_secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, published, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, published, "runtime_sha256=5a5a5a5a") != null);

    const identity = (try activeInstallationIdentity(std.testing.io, root_buf[0..root_len])).?;
    try std.testing.expectEqualStrings(test_manifest.repository, identity.repository.value());
    try std.testing.expectEqualStrings(test_manifest.revision, identity.revision.value());
    try std.testing.expectEqualStrings(test_manifest.runtime, identity.runtime.value());
    try std.testing.expectEqualStrings(test_manifest.artifact, identity.artifact.value());
    try std.testing.expectEqualStrings(test_manifest.installation_id, identity.installation_id.?.value());
    try std.testing.expectEqualStrings("type-wave-v0.0.0", identity.installed_by.value());
    try std.testing.expectEqual(@as(u8, 0x5a), identity.runtime_sha256[0]);
    try std.testing.expectEqual(test_manifest.size, identity.artifact_size);
}

test "explicit Verify reads every artifact byte and distinguishes usable from corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();

    try std.testing.expect((try operation.verify()) == .usable);
    var model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = (try activeModelPath(std.testing.io, root, &model_path_buf)).?;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model_path, .data = "binned test model" });

    const corrupt = try operation.verify();
    try std.testing.expectEqual(Corruption.digest_mismatch, corrupt.corrupt);
}

test "explicit Verify rejects self-consistent metadata outside the trusted manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    try installTestModel(root);
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    var provenance_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const provenance_path = try std.fmt.bufPrint(&provenance_path_buf, "{s}/installations/{s}/PROVENANCE", .{ root, test_manifest.installation_id });
    var receipt_buffer: [1024]u8 = undefined;
    const original = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &receipt_buffer);
    const forged = try std.mem.replaceOwned(u8, std.testing.allocator, original, "revision=test-revision", "revision=forged-revision");
    defer std.testing.allocator.free(forged);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = forged });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = provenance_path, .data = forged });
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);

    const integrity = try operation.verify();

    try std.testing.expectEqual(Corruption.identity_mismatch, integrity.corrupt);
}

test "Repair preserves a usable Model Installation without network access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();
    transport.calls = 0;

    try operation.repair(.offline_only);

    try std.testing.expectEqual(@as(usize, 0), transport.calls);
    try std.testing.expect((try operation.verify()) == .usable);
}

test "confirmed Repair replaces only an invalid artifact through authenticated acquisition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();
    var model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = (try activeModelPath(std.testing.io, root, &model_path_buf)).?;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model_path, .data = "binned test model" });
    transport.calls = 0;

    try operation.repair(.allow_network);

    try std.testing.expect(transport.calls > 0);
    try std.testing.expect((try operation.verify()) == .usable);
    var repaired_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repaired_path = (try activeModelPath(std.testing.io, root, &repaired_path_buf)).?;
    try std.testing.expect(std.mem.indexOf(u8, repaired_path, "test-installation-repair-") != null);
    var old_directory_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_directory = try std.fmt.bufPrint(&old_directory_buf, "{s}/installations/{s}", .{ root, test_manifest.installation_id });
    try std.Io.Dir.cwd().access(std.testing.io, old_directory, .{});

    const repaired_directory = std.fs.path.dirname(repaired_path).?;
    var repaired_manifest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repaired_manifest = try std.fmt.bufPrint(&repaired_manifest_buf, "{s}/MODEL_MANIFEST", .{repaired_directory});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = repaired_manifest, .data = "damaged metadata\n" });
    transport.calls = 0;
    try operation.repair(.offline_only);
    try std.testing.expectEqual(@as(usize, 0), transport.calls);
    try std.testing.expect((try operation.verify()) == .usable);
}

test "Model Operation transport observes only pinned artifact coordinates" {
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

    try operation.install();

    try std.testing.expect(transport.calls > 0);
    try std.testing.expectEqualStrings(test_manifest.url, transport.last_url.?);
    try std.testing.expect(transport.last_request != null);
    // DownloadRequest is deliberately an artifact-only type: it has byte range,
    // validator, and cancellation state, with no PCM or transcript field.
    try std.testing.expect(@hasField(DownloadRequest, "offset"));
    try std.testing.expect(!@hasField(DownloadRequest, "pcm"));
    try std.testing.expect(!@hasField(DownloadRequest, "transcript"));
}

test "Repair preserves and resumes validator-bound valid partial data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    try installTestModel(root);
    var model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = (try activeModelPath(std.testing.io, root, &model_path_buf)).?;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = model_path, .data = "binned test model" });
    try writeTestPartial(root, "pinned", "\"immutable-test\"");
    var transport = ResumingTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(ResumingTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);

    try operation.repair(.allow_network);

    try std.testing.expectEqual(@as(?u64, 6), transport.first_offset);
    try std.testing.expect((try operation.verify()) == .usable);
}

test "Repair rebuilds invalid installation metadata without network access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();
    var manifest_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/installations/{s}/MODEL_MANIFEST", .{ root, test_manifest.installation_id });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = "damaged metadata\n" });
    transport.calls = 0;

    try operation.repair(.offline_only);

    try std.testing.expectEqual(@as(usize, 0), transport.calls);
    try std.testing.expect((try operation.verify()) == .usable);
}

test "Repair reconstructs an invalid receipt from verified pinned local data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = "invalid receipt\n" });
    transport.calls = 0;
    smoke.called = false;

    try operation.repair(.offline_only);

    try std.testing.expectEqual(@as(usize, 0), transport.calls);
    try std.testing.expect(smoke.called);
    try std.testing.expect((try operation.verify()) == .usable);
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
    try operation.install();

    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    try std.Io.Dir.cwd().deleteFile(std.testing.io, receipt_path);
    try operation.install();
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
    try std.testing.expectError(error.ModelDownloadTruncated, bad_size.install());
    try std.testing.expect(!smoke.called);

    var actual_buf: [64]u8 = undefined;
    const after_digest_failure = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &actual_buf);
    try std.testing.expectEqualStrings("previous installation\n", after_digest_failure);

    var bad_transport = BadTransport{};
    var bad_digest = Operation(BadTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &bad_transport, &smoke);
    try std.testing.expectError(error.ModelDigestMismatch, bad_digest.install());
    try std.testing.expect(!smoke.called);
    try std.testing.expectEqual(OperationPhase.idle, (try bad_digest.recover()).phase);

    var transport = FakeTransport{};
    var failing_smoke = FailingSmoke{};
    var bad_smoke = Operation(FakeTransport, FailingSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &failing_smoke);
    try std.testing.expectError(error.HelperSmokeTestFailed, bad_smoke.install());
    const after_smoke_failure = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &actual_buf);
    try std.testing.expectEqualStrings("previous installation\n", after_smoke_failure);
}

test "a working older Model Installation remains active when the embedded identity changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    try installTestModel(root);
    const desired = replacementManifest();

    try std.testing.expect(try updateAvailable(std.testing.io, root, desired));
    var active_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const active_path = (try activeModelPath(std.testing.io, root, &active_path_buf)).?;
    try std.testing.expect(std.mem.endsWith(u8, active_path, "/installations/test-installation/ggml-model.bin"));

    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var verifier = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, desired, &transport, &smoke);
    verifier.additional_trusted_manifests = &.{test_manifest};
    try std.testing.expect((try verifier.verify()) == .usable);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = active_path, .data = "binned test model" });
    try verifier.repair(.allow_network);
    try std.testing.expect((try verifier.verify()) == .usable);
    try std.testing.expect(try updateAvailable(std.testing.io, root, desired));
}

test "a schema-one receipt remains usable and reports an embedded replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();

    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}/active.receipt", .{root});
    var provenance_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const provenance_path = try std.fmt.bufPrint(&provenance_path_buf, "{s}/installations/{s}/PROVENANCE", .{ root, test_manifest.installation_id });
    var receipt_buf: [1024]u8 = undefined;
    const current = try std.Io.Dir.cwd().readFile(std.testing.io, receipt_path, &receipt_buf);
    const old_schema = try std.mem.replaceOwned(u8, std.testing.allocator, current, "schema=2", "schema=1");
    defer std.testing.allocator.free(old_schema);
    const old_receipt = try std.mem.replaceOwned(u8, std.testing.allocator, old_schema, "installation_id=test-installation\n", "");
    defer std.testing.allocator.free(old_receipt);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = old_receipt });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = provenance_path, .data = old_receipt });

    const desired = replacementManifest();
    try std.testing.expect(try updateAvailable(std.testing.io, root, desired));
    var active_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect((try activeModelPath(std.testing.io, root, &active_path_buf)) != null);
}

test "a failed replacement leaves the working Model Installation unchanged and usable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    try installTestModel(root);
    const desired = replacementManifest();
    var replacement_transport = FakeTransport{};
    var failing_smoke = FailingSmoke{};
    var replacement = Operation(FakeTransport, FailingSmoke).init(std.testing.allocator, std.testing.io, root, desired, &replacement_transport, &failing_smoke);

    try std.testing.expectError(error.HelperSmokeTestFailed, replacement.install());
    try std.testing.expect(try updateAvailable(std.testing.io, root, desired));
    var active_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const active_path = (try activeModelPath(std.testing.io, root, &active_path_buf)).?;
    try std.testing.expect(std.mem.endsWith(u8, active_path, "/installations/test-installation/ggml-model.bin"));
}

test "replacement activation waits for the active inference lease to drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    try installTestModel(root);
    const desired = replacementManifest();
    var lease = try InferenceLease.acquire(std.testing.io, root);
    var drain = ActivationDrainLog{ .lease = &lease };
    var replacement_transport = FakeTransport{};
    var replacement_smoke = FakeSmoke{};
    var replacement = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, desired, &replacement_transport, &replacement_smoke);
    replacement.observer = .{ .ctx = &drain, .on_event = ActivationDrainLog.record };

    try replacement.install();

    try std.testing.expect(drain.released);
    try std.testing.expectEqual(@as(usize, 1), drain.waits);
    try std.testing.expect(!try updateAvailable(std.testing.io, root, desired));
    try std.testing.expect(try activeInstallationPresent(std.testing.io, root, desired));
    var previous_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const previous_path = try std.fmt.bufPrint(&previous_path_buf, "{s}/installations/{s}", .{ root, test_manifest.installation_id });
    try std.Io.Dir.cwd().access(std.testing.io, previous_path, .{});
    try std.testing.expectEqual(@as(usize, 1), try removeInactiveInstallations(std.testing.io, root));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, previous_path, .{}));
}

test "confirmed removal rejects new local Utterances, drains the helper, and removes the Model Installation and staged Model Operation data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    try installTestModel(root);
    try writeTestPartial(root, "pinned", "\"immutable-test\"");
    var runtime = try RuntimeLease.acquire(std.testing.io, root);
    var drain = RemovalDrainLog{ .root = root, .runtime = &runtime };
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    operation.observer = .{ .ctx = &drain, .on_event = RemovalDrainLog.record };

    try operation.remove();

    try std.testing.expect(drain.rejected_new_inference);
    try std.testing.expect(drain.released_runtime);
    try std.testing.expectEqual(@as(usize, 1), drain.removing_events);
    var model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect((try activeModelPath(std.testing.io, root, &model_path_buf)) == null);
    var installations_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const installations = try std.fmt.bufPrint(&installations_path_buf, "{s}/installations", .{root});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, installations, .{}));
    var stage_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stage = try std.fmt.bufPrint(&stage_path_buf, "{s}/staging-{s}", .{ root, test_manifest.installation_id });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, stage, .{}));
}

test "acquisition starts only at the exact trusted artifact origin" {
    try std.testing.expect(isHuggingFaceOrigin(test_manifest.url));
    try std.testing.expect(isHuggingFaceOrigin(pinned_manifest.url));
    try std.testing.expect(!isHuggingFaceOrigin("https://cdn-lfs.hf.co/signed?secret=value"));
    try std.testing.expect(!isHuggingFaceOrigin("https://huggingface.co.evil.example/model"));
    try std.testing.expect(!isHuggingFaceOrigin("http://huggingface.co/model"));
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
    try operation.resumePartial();

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
    try std.testing.expectError(error.ResumeResponseMismatch, operation.resumePartial());
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
    try std.testing.expectError(error.ModelDownloadRangeMismatch, operation.resumePartial());
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
    try std.testing.expectError(error.InvalidModelValidator, operation.resumePartial());
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

    try std.testing.expectError(error.ModelDownloadRetryBudgetExhausted, operation.install());
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

    try std.testing.expectError(error.ModelDownloadRetryBudgetExhausted, operation.install());
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

    try operation.install();
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

    try std.testing.expectError(error.ModelOperationCancelled, operation.install());
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

    try std.testing.expectError(error.ModelOperationCancelled, operation.install());
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

    try std.testing.expectError(error.ModelOperationCancelled, operation.install());
    try std.testing.expectEqual(OperationPhase.paused, (try operation.recover()).phase);
    try std.testing.expect(!try activeInstallationPresent(std.testing.io, root, test_manifest));
}

const test_bytes = "pinned test model";
const test_manifest = Manifest.forTest();

fn installTestModel(root: []const u8) !void {
    var transport = FakeTransport{};
    var smoke = FakeSmoke{};
    var operation = Operation(FakeTransport, FakeSmoke).init(std.testing.allocator, std.testing.io, root, test_manifest, &transport, &smoke);
    try operation.install();
}

fn replacementManifest() Manifest {
    var desired = test_manifest;
    desired.revision = "replacement-revision";
    desired.installation_id = "replacement-installation";
    desired.url = "https://huggingface.co/example/test-model/resolve/replacement-revision/ggml-model.bin";
    return desired;
}

const FakeTransport = struct {
    calls: usize = 0,
    last_url: ?[]const u8 = null,
    last_request: ?DownloadRequest = null,

    pub fn download(self: *FakeTransport, url: []const u8, request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        self.calls += 1;
        self.last_url = url;
        self.last_request = request;
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const CountingTransport = struct {
    requests: usize = 0,
};

const AlwaysTransientTransport = struct {
    requests: usize = 0,

    pub fn download(self: *AlwaysTransientTransport, _: []const u8,_: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
        self.requests += 1;
        return error.ModelDownloadFailed;
    }
};

const IntermittentTransport = struct {
    requests: usize = 0,

    pub fn download(self: *IntermittentTransport, _: []const u8,request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        self.requests += 1;
        if (self.requests % 2 == 1) return error.ModelDownloadFailed;
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const TruncatedThenSuccessTransport = struct {
    requests: usize = 0,

    pub fn download(self: *TruncatedThenSuccessTransport, _: []const u8,request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        self.requests += 1;
        if (self.requests == 1) return error.ModelDownloadTruncated;
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const CancellingTransport = struct {
    pub fn download(_: *CancellingTransport, _: []const u8,request: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
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

const ActivationDrainLog = struct {
    lease: *InferenceLease,
    waits: usize = 0,
    released: bool = false,

    fn record(ctx: *anyopaque, event: OperationEvent) void {
        const self: *ActivationDrainLog = @ptrCast(@alignCast(ctx));
        if (event != .waiting_for_inference) return;
        self.waits += 1;
        self.lease.release();
        self.released = true;
    }
};

const RemovalDrainLog = struct {
    root: []const u8,
    runtime: *RuntimeLease,
    rejected_new_inference: bool = false,
    released_runtime: bool = false,
    removing_events: usize = 0,

    fn record(ctx: *anyopaque, event: OperationEvent) void {
        const self: *RemovalDrainLog = @ptrCast(@alignCast(ctx));
        switch (event) {
            .waiting_for_inference => {
                if (InferenceLease.acquire(std.testing.io, self.root)) |lease_value| {
                    var lease = lease_value;
                    lease.release();
                } else |failure| {
                    self.rejected_new_inference = failure == error.ModelRemovalInProgress;
                }
                self.runtime.release();
                self.released_runtime = true;
            },
            .removing => self.removing_events += 1,
            else => {},
        }
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

    pub fn download(self: *ResumingTransport, _: []const u8,request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        if (self.first_offset == null) {
            self.first_offset = request.offset;
            self.if_range = request.validator.?;
        }
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const MismatchedResumeTransport = struct {
    pub fn download(_: *MismatchedResumeTransport, _: []const u8,request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        try writer.writeAll(test_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"different\"");
    }
};

const IncompatibleRangeTransport = struct {
    pub fn download(_: *IncompatibleRangeTransport, _: []const u8,_: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
        return error.ModelDownloadRangeMismatch;
    }
};

const MalformedValidatorTransport = struct {
    pub fn download(_: *MalformedValidatorTransport, _: []const u8,_: DownloadRequest, _: *std.Io.Writer) !DownloadResult {
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
    pub fn download(_: *BadTransport, _: []const u8,request: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
        const bad_bytes = "tinned test model";
        try writer.writeAll(bad_bytes[@intCast(request.offset)..@intCast(request.end + 1)]);
        return DownloadResult.fromValidator(.etag, "\"immutable-test\"");
    }
};

const ShortTransport = struct {
    pub fn download(_: *ShortTransport, _: []const u8,_: DownloadRequest, writer: *std.Io.Writer) !DownloadResult {
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
