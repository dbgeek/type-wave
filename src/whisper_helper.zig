const std = @import("std");
const core = @import("whisper_helper_core.zig");
const ipc = @import("whisper_ipc.zig");
const artifact_identity = @import("artifact_identity.zig");
const WhisperRuntime = @import("whisper_runtime.zig").Runtime;

const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *WhisperRuntime,
    output_lock: std.Io.Mutex = .init,
    lifecycle_lock: std.Io.Mutex = .init,
    input_open: bool = true,
    gate: core.InferenceGate = .{},
    inference: ?std.Thread = null,

    fn write(self: *Server, frame: ipc.Frame) !void {
        self.output_lock.lockUncancelable(self.io);
        defer self.output_lock.unlock(self.io);
        try ipc.writeFd(self.allocator, 1, frame);
    }

    fn reap(self: *Server) void {
        if (!self.gate.isActive()) {
            if (self.inference) |thread| thread.join();
            self.inference = null;
        }
    }

    fn stop(self: *Server) void {
        if (self.gate.isActive()) _ = self.runtime.requestCancel();
        if (self.inference) |thread| thread.join();
        self.inference = null;
    }

    fn begin(self: *Server, request: ipc.Transcribe) !void {
        self.reap();
        try self.gate.begin(WhisperRuntime, self.runtime, request.id);
        errdefer self.gate.finish();
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .server = self, .request = request };
        self.inference = try std.Thread.spawn(.{}, Job.run, .{job});
    }

    fn cancel(self: *Server, id: u64) bool {
        return self.gate.cancel(WhisperRuntime, self.runtime, id);
    }

    /// Closes the command side under the same arbitration lock used to publish a
    /// terminal response. Returns true when EOF interrupted an active request.
    fn closeInput(self: *Server) bool {
        self.lifecycle_lock.lockUncancelable(self.io);
        defer self.lifecycle_lock.unlock(self.io);
        self.input_open = false;
        return self.gate.isActive();
    }
};

const Job = struct {
    server: *Server,
    request: ipc.Transcribe,

    fn run(self: *Job) void {
        const server = self.server;
        var gate_finished = false;
        defer {
            if (!gate_finished) server.gate.finish();
            server.allocator.free(self.request.pcm);
            server.allocator.destroy(self);
        }
        var response = core.runInferenceAlloc(WhisperRuntime, server.runtime, server.allocator, self.request) catch |failure| blk: {
            const message = server.allocator.dupe(u8, @errorName(failure)) catch return;
            break :blk ipc.Frame{ .failed = .{ .id = self.request.id, .code = 3, .message = message } };
        };
        defer response.deinit(server.allocator);
        server.lifecycle_lock.lockUncancelable(server.io);
        defer server.lifecycle_lock.unlock(server.io);
        defer {
            server.gate.finish();
            gate_finished = true;
        }
        if (server.input_open) {
            server.write(response) catch |failure| {
                std.debug.print("type-wave-whisper: response write failed: {s}\n", .{@errorName(failure)});
            };
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;
    const argv = init.args.vector;
    if (argv.len != 2) {
        std.debug.print("usage: type-wave-whisper VERIFIED_GGML_MODEL\n", .{});
        std.process.exit(2);
    }
    const model_path = std.mem.span(argv[1]);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expected = readArtifactIdentity(io, model_path) catch |failure| {
        try writeStartupFailure(allocator, 9, @errorName(failure));
        std.process.exit(1);
    };

    var inspected = inspectArtifact(io, model_path, expected) catch |failure| {
        try writeStartupFailure(allocator, 10, @errorName(failure));
        std.process.exit(1);
    };
    defer inspected.file.close(io);
    var runtime = WhisperRuntime.init(inspected.file.handle);
    defer runtime.deinit();
    var preparation = core.Preparation(WhisperRuntime).init(&runtime, expected);
    const digest = preparation.prepare(inspected.artifact) catch |failure| {
        try writeStartupFailure(allocator, 11, @errorName(failure));
        std.process.exit(1);
    };
    try ipc.writeFd(allocator, 1, .{ .ready = digest });

    var server = Server{ .allocator = allocator, .io = io, .runtime = &runtime };
    defer server.stop();
    while (true) {
        var frame = (ipc.readFd(allocator, 0) catch |failure| {
            std.debug.print("type-wave-whisper: protocol failure: {s}\n", .{@errorName(failure)});
            _ = server.closeInput();
            server.stop();
            std.process.exit(1);
        }) orelse {
            if (server.closeInput()) {
                std.debug.print("type-wave-whisper: unexpected EOF during inference\n", .{});
                server.stop();
                std.process.exit(1);
            }
            break;
        };
        switch (frame) {
            .transcribe => |request| {
                frame = undefined; // request PCM ownership moves to the inference job.
                server.begin(request) catch |failure| {
                    allocator.free(request.pcm);
                    const message = @errorName(failure);
                    try server.write(.{ .failed = .{ .id = request.id, .code = 4, .message = message } });
                };
            },
            .cancel => |id| {
                _ = server.cancel(id);
                frame.deinit(allocator);
            },
            else => {
                frame.deinit(allocator);
                std.debug.print("type-wave-whisper: unexpected frame direction\n", .{});
                std.process.exit(1);
            },
        }
    }
}

fn writeStartupFailure(allocator: std.mem.Allocator, code: u16, message: []const u8) !void {
    try ipc.writeFd(allocator, 1, .{ .startup_failed = .{ .code = code, .message = message } });
}

const InspectedArtifact = struct {
    file: std.Io.File,
    artifact: core.Artifact,
};

fn readArtifactIdentity(io: std.Io, model_path: []const u8) !core.Artifact {
    const directory = std.fs.path.dirname(model_path) orelse return error.InvalidModelPath;
    var manifest_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buffer, "{s}/MODEL_MANIFEST", .{directory});
    var provenance_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const provenance_path = try std.fmt.bufPrint(&provenance_path_buffer, "{s}/PROVENANCE", .{directory});
    var identity_buffer: [1024]u8 = undefined;
    const identity = std.Io.Dir.cwd().readFile(io, manifest_path, &identity_buffer) catch |failure| switch (failure) {
        error.FileNotFound => try std.Io.Dir.cwd().readFile(io, provenance_path, &identity_buffer),
        else => return failure,
    };
    return artifact_identity.parse(identity) catch return error.InvalidModelIdentity;
}

fn inspectArtifact(io: std.Io, path: []const u8, expected: core.Artifact) !InspectedArtifact {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.size != expected.size) return error.InvalidModelSize;

    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buffer: [1024 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const count = file_reader.interface.readSliceShort(&chunk) catch |failure| switch (failure) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (count == 0) break;
        digest.update(chunk[0..count]);
    }
    var sha256: [32]u8 = undefined;
    digest.final(&sha256);
    if (!std.mem.eql(u8, &sha256, &expected.sha256)) return error.InvalidModelDigest;
    return .{ .file = file, .artifact = .{ .size = stat.size, .sha256 = sha256 } };
}
