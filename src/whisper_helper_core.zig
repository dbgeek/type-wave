const std = @import("std");
const ipc = @import("whisper_ipc.zig");
const artifact_identity = @import("artifact_identity.zig");

pub const pinned_model_bytes: u64 = 1_624_555_275;
pub const pinned_model_sha256: [32]u8 = .{
    0x1f, 0xc7, 0x0f, 0x77, 0x4d, 0x38, 0xeb, 0x16,
    0x99, 0x93, 0xac, 0x39, 0x1e, 0xea, 0x35, 0x7e,
    0xf4, 0x7c, 0x88, 0x75, 0x7e, 0xf7, 0x2e, 0xe5,
    0x94, 0x38, 0x79, 0xb7, 0xe8, 0xe2, 0xbc, 0x69,
};
/// Per-**Segment** ceiling on 24 kHz s16 Capture bytes handed to one inference (ADR-0003).
/// A long local Utterance is cut into Segments; the local Adapter force-cuts at a 25 s hard
/// max, so this bound only has to clear that plus one 50 ms buffer of slop — 26 s here. It
/// is no longer a per-Utterance cap (that ceiling is gone). Stays well under the 2 MiB IPC
/// frame payload cap: 26 s · 48 kB/s = 1.25 MiB.
pub const max_pcm_len: usize = 24_000 * 2 * 26;

pub const Artifact = artifact_identity.Identity;

pub fn pinnedArtifact() Artifact {
    return .{ .size = pinned_model_bytes, .sha256 = pinned_model_sha256 };
}

pub fn Preparation(comptime Runtime: type) type {
    return struct {
        const Self = @This();

        runtime: *Runtime,
        expected: Artifact,
        ready: bool = false,

        pub fn init(runtime: *Runtime, expected: Artifact) Self {
            return .{ .runtime = runtime, .expected = expected };
        }

        pub fn prepare(self: *Self, artifact: Artifact) ![32]u8 {
            self.ready = false;
            if (artifact.size != self.expected.size or !std.mem.eql(u8, &artifact.sha256, &self.expected.sha256)) {
                return error.InvalidModelArtifact;
            }
            try self.runtime.load();
            errdefer self.ready = false;
            try self.runtime.warm();
            self.ready = true;
            return self.expected.sha256;
        }

        pub fn isReady(self: *const Self) bool {
            return self.ready;
        }
    };
}

pub const InferenceGate = struct {
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn begin(self: *InferenceGate, comptime Runtime: type, runtime: *Runtime, id: u64) !void {
        if (self.active.swap(true, .acq_rel)) return error.InferenceBusy;
        runtime.beginInference();
        self.active_id.store(id, .release);
    }

    pub fn cancel(self: *InferenceGate, comptime Runtime: type, runtime: *Runtime, id: u64) bool {
        if (!self.active.load(.acquire)) return false;
        if (self.active_id.load(.acquire) != id) return false;
        return runtime.requestCancel();
    }

    pub fn finish(self: *InferenceGate) void {
        self.active.store(false, .release);
    }

    pub fn isActive(self: *const InferenceGate) bool {
        return self.active.load(.acquire);
    }
};

pub fn runInferenceAlloc(
    comptime Runtime: type,
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    request: ipc.Transcribe,
) !ipc.Frame {
    const samples = try resample24To16Alloc(allocator, request.pcm);
    defer allocator.free(samples);
    const text = runtime.transcribe(allocator, request.language, request.prompt, samples) catch |failure| {
        const message = try allocator.dupe(u8, @errorName(failure));
        return .{ .failed = .{ .id = request.id, .code = 1, .message = message } };
    };
    if (!std.unicode.utf8ValidateSlice(text)) {
        allocator.free(text);
        const message = try allocator.dupe(u8, "runtime returned invalid UTF-8");
        return .{ .failed = .{ .id = request.id, .code = 2, .message = message } };
    }
    return .{ .final = .{ .id = request.id, .text = text } };
}

pub fn resample24To16Alloc(allocator: std.mem.Allocator, pcm: []const u8) ![]f32 {
    if (pcm.len == 0) return error.EmptyPcm;
    if (pcm.len % 2 != 0) return error.OddPcmLength;
    if (pcm.len > max_pcm_len) return error.PcmTooLarge;
    const input_len = pcm.len / 2;
    const output_len = (input_len * 2) / 3;
    if (output_len == 0) return error.EmptyPcm;
    const output = try allocator.alloc(f32, output_len);
    errdefer allocator.free(output);
    for (output, 0..) |*sample, index| {
        const position = index * 3;
        const left_index = position / 2;
        const left = pcmSample(pcm, left_index);
        sample.* = if (position % 2 == 0)
            left
        else
            (left + pcmSample(pcm, @min(left_index + 1, input_len - 1))) * 0.5;
    }
    return output;
}

fn pcmSample(pcm: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(u16, pcm[index * 2 ..][0..2], .little);
    const signed: i16 = @bitCast(bits);
    return @as(f32, @floatFromInt(signed)) / 32768.0;
}

test "helper declares readiness only after exact artifact load and warm-up" {
    var fake = FakeRuntime{};
    var helper = Preparation(FakeRuntime).init(&fake, pinnedArtifact());

    try std.testing.expectError(error.InvalidModelArtifact, helper.prepare(.{ .size = pinned_model_bytes - 1, .sha256 = pinned_model_sha256 }));
    try std.testing.expect(!helper.isReady());
    try std.testing.expectEqual(@as(usize, 0), fake.load_count);

    fake.warm_error = error.MetalPreparationFailed;
    try std.testing.expectError(error.MetalPreparationFailed, helper.prepare(pinnedArtifact()));
    try std.testing.expect(!helper.isReady());
    try std.testing.expectEqual(@as(usize, 1), fake.load_count);
    try std.testing.expectEqual(@as(usize, 1), fake.warm_count);

    fake.warm_error = null;
    const ready = try helper.prepare(pinnedArtifact());
    try std.testing.expect(helper.isReady());
    try std.testing.expectEqualSlices(u8, &pinned_model_sha256, &ready);
}

test "helper preparation accepts the verified active receipt identity during an update handoff" {
    var fake = FakeRuntime{};
    const expected = Artifact{ .size = 17, .sha256 = @splat(0xab) };
    var helper = Preparation(FakeRuntime).init(&fake, expected);

    const ready = try helper.prepare(expected);

    try std.testing.expectEqualSlices(u8, &expected.sha256, &ready);
    try std.testing.expect(helper.isReady());
}

test "helper keeps one identity-tagged inference active and cancels only its identity" {
    var fake = FakeRuntime{};
    var gate = InferenceGate{};

    const pcm = [_]u8{ 0, 0, 0, 0, 0, 0 };
    try gate.begin(FakeRuntime, &fake, 41);
    try std.testing.expectError(error.InferenceBusy, gate.begin(FakeRuntime, &fake, 42));
    try std.testing.expect(!gate.cancel(FakeRuntime, &fake, 42));
    try std.testing.expect(!fake.cancelled.load(.acquire));
    try std.testing.expect(gate.cancel(FakeRuntime, &fake, 41));
    try std.testing.expect(fake.cancelled.load(.acquire));
    try std.testing.expect(!gate.cancel(FakeRuntime, &fake, 41));

    var cancelled = try runInferenceAlloc(FakeRuntime, &fake, std.testing.allocator, .{ .id = 41, .language = .english, .prompt = "", .pcm = &pcm });
    defer cancelled.deinit(std.testing.allocator);
    gate.finish();
    try std.testing.expectEqual(@as(u64, 41), cancelled.failed.id);
    try std.testing.expectEqualStrings("Cancelled", cancelled.failed.message);

    try gate.begin(FakeRuntime, &fake, 43);
    var completed = try runInferenceAlloc(FakeRuntime, &fake, std.testing.allocator, .{ .id = 43, .language = .auto_detect, .prompt = "", .pcm = &pcm });
    defer completed.deinit(std.testing.allocator);
    gate.finish();
    try std.testing.expectEqual(@as(u64, 43), completed.final.id);
    try std.testing.expectEqualStrings("transcribed", completed.final.text);
}

test "helper converts signed 24 kHz PCM to bounded 16 kHz float samples" {
    const pcm = [_]u8{
        0x00, 0x80, // -32768
        0x00, 0x00, // 0
        0xff, 0x7f, // 32767
        0x00, 0x40, // 16384
        0x00, 0xc0, // -16384
        0x00, 0x00, // 0
    };
    const samples = try resample24To16Alloc(std.testing.allocator, &pcm);
    defer std.testing.allocator.free(samples);

    try std.testing.expectEqual(@as(usize, 4), samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), samples[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), samples[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), samples[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), samples[3], 0.0001);
    try std.testing.expectError(error.OddPcmLength, resample24To16Alloc(std.testing.allocator, pcm[0..5]));
    try std.testing.expectError(error.EmptyPcm, resample24To16Alloc(std.testing.allocator, &.{}));
}

const FakeRuntime = struct {
    load_count: usize = 0,
    warm_count: usize = 0,
    warm_error: ?anyerror = null,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn load(self: *@This()) !void {
        self.load_count += 1;
    }

    fn warm(self: *@This()) !void {
        self.warm_count += 1;
        if (self.warm_error) |failure| return failure;
    }

    fn requestCancel(self: *@This()) bool {
        return !self.cancelled.swap(true, .acq_rel);
    }

    fn beginInference(self: *@This()) void {
        self.cancelled.store(false, .release);
    }

    fn transcribe(self: *@This(), allocator: std.mem.Allocator, language: ipc.Language, prompt: []const u8, samples: []const f32) ![]u8 {
        _ = language;
        _ = prompt;
        _ = samples;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        return allocator.dupe(u8, "transcribed");
    }
};
