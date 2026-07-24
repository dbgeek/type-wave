const std = @import("std");
const ipc = @import("whisper_ipc.zig");

const RuntimeHandle = opaque {};

extern fn tw_whisper_create(model_fd: c_int) ?*RuntimeHandle;
extern fn tw_whisper_destroy(runtime: *RuntimeHandle) void;
extern fn tw_whisper_warm(runtime: *RuntimeHandle) bool;
extern fn tw_whisper_begin_inference(runtime: *RuntimeHandle) void;
extern fn tw_whisper_request_cancel(runtime: *RuntimeHandle) bool;
extern fn tw_whisper_transcribe(
    runtime: *RuntimeHandle,
    language: u8,
    prompt: [*:0]const u8,
    samples: [*]const f32,
    sample_count: usize,
    text: *?[*]const u8,
    text_len: *usize,
) c_int;

pub const Runtime = struct {
    model_fd: c_int,
    handle: ?*RuntimeHandle = null,

    pub fn init(model_fd: c_int) Runtime {
        return .{ .model_fd = model_fd };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.handle) |handle| tw_whisper_destroy(handle);
        self.handle = null;
    }

    pub fn load(self: *Runtime) !void {
        if (self.handle != null) self.deinit();
        self.handle = tw_whisper_create(self.model_fd) orelse return error.ModelLoadFailed;
    }

    pub fn warm(self: *Runtime) !void {
        if (!tw_whisper_warm(self.handle orelse return error.ModelNotLoaded)) return error.MetalPreparationFailed;
    }

    pub fn requestCancel(self: *Runtime) bool {
        return tw_whisper_request_cancel(self.handle orelse return false);
    }

    pub fn beginInference(self: *Runtime) void {
        tw_whisper_begin_inference(self.handle orelse return);
    }

    pub fn transcribe(
        self: *Runtime,
        allocator: std.mem.Allocator,
        language: ipc.Language,
        prompt: []const u8,
        samples: []const f32,
    ) ![]u8 {
        // The C ABI takes a NUL-terminated glossary next to `language`; a sentinel-terminated
        // copy is borrowed across the synchronous inference and freed here (spec §5). An empty
        // prompt sentinel-terminates to "", which the bridge maps to a null initial_prompt.
        const prompt_z = try allocator.dupeSentinel(u8, prompt, 0);
        defer allocator.free(prompt_z);
        var text: ?[*]const u8 = null;
        var text_len: usize = 0;
        const status = tw_whisper_transcribe(
            self.handle orelse return error.ModelNotLoaded,
            @intFromEnum(language),
            prompt_z.ptr,
            samples.ptr,
            samples.len,
            &text,
            &text_len,
        );
        return switch (status) {
            0 => allocator.dupe(u8, text.?[0..text_len]),
            3 => error.Cancelled,
            else => error.InferenceFailed,
        };
    }
};
