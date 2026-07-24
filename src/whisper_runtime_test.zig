//! Exercises the *real* Whisper runtime wrapper (`whisper_runtime.zig`) — the C-ABI marshaling
//! the Whisper Helper uses — against a fake bridge whose `tw_whisper_*` symbols are `export`ed
//! only into the test binary. The production symbols live in `whisper_bridge.cpp` + the pinned
//! whisper.cpp archive and are linked solely by the `type-wave-whisper` executable; here nothing
//! links that archive or Metal/Accelerate.
//!
//! This closes the coverage gap behind #207: the helper's own unit tests drive a `FakeRuntime`
//! that never touches the sentinel-copy path, so std-library API drift inside the real wrapper
//! (e.g. the removed `Allocator.dupeZ`) was invisible to `zig build test` and only surfaced at
//! `install-agent`. Pulling the real wrapper into the test binary forces full semantic analysis
//! of every `Runtime` method against the pinned std, and asserts the sentinel-terminated glossary
//! contract (spec §5) through the public `transcribe` entry point rather than the specific std call.

const std = @import("std");
const ipc = @import("whisper_ipc.zig");
const Runtime = @import("whisper_runtime.zig").Runtime;

/// State captured by the fake bridge on the far side of the C ABI, so a test can inspect exactly
/// what the wrapper handed across for a given `transcribe` / lifecycle call.
const Bridge = struct {
    var prompt: [512]u8 = undefined;
    var prompt_len: usize = 0;
    var sentinel: u8 = 0xAA; // the byte the wrapper placed one past the glossary; must be NUL
    var language: u8 = 0xFF;
    var text: [:0]const u8 = "";
    var status: c_int = 0;
    var began: usize = 0;
    var cancels: usize = 0;

    fn reset() void {
        prompt = undefined;
        prompt_len = 0;
        sentinel = 0xAA;
        language = 0xFF;
        text = "";
        status = 0;
        began = 0;
        cancels = 0;
    }
};

// The wrapper's `extern fn` set, resolved at link time by these `export fn` stubs in the test
// binary only. Pointer types are `*anyopaque` — the C ABI matches the wrapper's opaque handle by
// symbol name and calling convention, not by Zig type.
export fn tw_whisper_create(model_fd: c_int) ?*anyopaque {
    _ = model_fd;
    return @ptrFromInt(0x7715); // any non-null handle; the wrapper only checks for null
}
export fn tw_whisper_destroy(runtime: *anyopaque) void {
    _ = runtime;
}
export fn tw_whisper_warm(runtime: *anyopaque) bool {
    _ = runtime;
    return true;
}
export fn tw_whisper_begin_inference(runtime: *anyopaque) void {
    _ = runtime;
    Bridge.began += 1;
}
export fn tw_whisper_request_cancel(runtime: *anyopaque) bool {
    _ = runtime;
    Bridge.cancels += 1;
    return true;
}
export fn tw_whisper_transcribe(
    runtime: *anyopaque,
    language: u8,
    prompt: [*:0]const u8,
    samples: [*]const f32,
    sample_count: usize,
    text: *?[*]const u8,
    text_len: *usize,
) c_int {
    _ = runtime;
    _ = samples;
    _ = sample_count;
    Bridge.language = language;
    // Reading the sentinel-terminated glossary proves the wrapper handed us a NUL-terminated copy;
    // capturing the byte one past its end lets the test assert the terminator explicitly.
    const glossary = std.mem.span(prompt);
    std.debug.assert(glossary.len <= Bridge.prompt.len); // fail loudly, don't corrupt, on an oversized test prompt
    Bridge.prompt_len = glossary.len;
    @memcpy(Bridge.prompt[0..glossary.len], glossary);
    Bridge.sentinel = prompt[glossary.len];
    text.* = Bridge.text.ptr;
    text_len.* = Bridge.text.len;
    return Bridge.status;
}

test "transcribe hands a non-empty prompt across the C ABI as a NUL-terminated glossary" {
    Bridge.reset();
    Bridge.text = "verbatim";
    var runtime = Runtime.init(-1);
    try runtime.load();
    defer runtime.deinit();

    const samples = [_]f32{ 0.0, 0.1, -0.1, 0.2 };
    const out = try runtime.transcribe(std.testing.allocator, .english, "glossary: Kubernetes, kubectl", &samples);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("verbatim", out);
    try std.testing.expectEqualStrings("glossary: Kubernetes, kubectl", Bridge.prompt[0..Bridge.prompt_len]);
    try std.testing.expectEqual(@as(u8, 0), Bridge.sentinel);
    try std.testing.expectEqual(@intFromEnum(ipc.Language.english), Bridge.language);
}

test "transcribe maps an empty prompt to the bridge's no-initial-prompt case (empty, NUL-terminated)" {
    Bridge.reset();
    Bridge.text = "ok";
    var runtime = Runtime.init(-1);
    try runtime.load();
    defer runtime.deinit();

    const out = try runtime.transcribe(std.testing.allocator, .auto_detect, "", &.{});
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), Bridge.prompt_len);
    try std.testing.expectEqual(@as(u8, 0), Bridge.sentinel);
    try std.testing.expectEqual(@intFromEnum(ipc.Language.auto_detect), Bridge.language);
}

test "transcribe maps runtime status codes to Cancelled / InferenceFailed, and lifecycle drives the C ABI" {
    Bridge.reset();
    var runtime = Runtime.init(7);
    try runtime.load();
    defer runtime.deinit();
    try runtime.warm();

    runtime.beginInference();
    try std.testing.expectEqual(@as(usize, 1), Bridge.began);
    try std.testing.expect(runtime.requestCancel());
    try std.testing.expectEqual(@as(usize, 1), Bridge.cancels);

    Bridge.status = 3;
    try std.testing.expectError(error.Cancelled, runtime.transcribe(std.testing.allocator, .english, "p", &.{}));
    Bridge.status = 9;
    try std.testing.expectError(error.InferenceFailed, runtime.transcribe(std.testing.allocator, .english, "p", &.{}));
}
