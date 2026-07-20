//! openai_rewrite.zig — the Backtrack Rewrite mechanism: one OpenAI Responses API call
//! (docs/backtrack-spec.md §Model, API & prompt).
//!
//! The locked configuration, verbatim from the spec: `gpt-5.4-mini` on the Responses
//! API, non-streaming, `reasoning: {effort: "none"}` (the dominant latency knob — it is
//! honored on Responses, not Chat Completions), `temperature: 0` (load-bearing: it turned
//! run-to-run wobble on correction-scope cases into byte-identical determinism), standard
//! service tier, Bearer key. The prompt is v6 from the `prototype/backtrack-prompt`
//! validation (27/27, zero false triggers across ~190 calls) — embedded from
//! `backtrack_prompt.txt`, which `prototypes/backtrack-prompt/run.py` re-validates
//! against the live API.
//!
//! This module is mechanism only: build the request, make the call, extract the output
//! text. Policy (when to rewrite, the raw-transcript fallback, the coming ~3 s timeout)
//! lives in the Utterance Coordinator and rewrite_adapter.zig. The pure halves
//! (`buildRequestBody`, `extractOutputText`) are exercised by tests with canned JSON —
//! no network.

const std = @import("std");

pub const model = "gpt-5.4-mini";
pub const endpoint = "https://api.openai.com/v1/responses";

/// Prompt v6 — corrections + filler removal in one shot. Keep byte-identical with what
/// `prototypes/backtrack-prompt/run.py` tests (it reads this same file).
pub const prompt: []const u8 = @embedFile("backtrack_prompt.txt");

/// The Responses API request for one rewrite. JSON-escaping matters only for the two
/// string payloads (the prompt and the spoken utterance); everything else is fixed.
pub fn buildRequestBody(w: *std.Io.Writer, utterance: []const u8) !void {
    try w.writeAll("{\"model\":\"" ++ model ++ "\",\"instructions\":");
    try std.json.Stringify.encodeJsonString(prompt, .{}, w);
    try w.writeAll(",\"input\":");
    try std.json.Stringify.encodeJsonString(utterance, .{}, w);
    // "service_tier":"default" pins the spec's standard tier explicitly (OpenAI's
    // "auto" would resolve there today, but the locked config should not be implicit;
    // "priority" is the spec's named 2× tail-latency escape hatch if ever needed).
    // max_output_tokens matches the 8 KiB transcript bound — a cost cap, never hit by
    // a sane rewrite since the output is about as long as the input.
    try w.writeAll(",\"reasoning\":{\"effort\":\"none\"},\"temperature\":0,\"service_tier\":\"default\",\"max_output_tokens\":8192}");
}

/// Pull the message text out of a Responses API body: the concatenated `output_text`
/// content of every `message` output item, whitespace-trimmed, copied into `out`.
/// Anything unusable — an error payload, no message text, an empty rewrite, text that
/// cannot fit `out` — is an error; the caller falls back to the raw transcript.
pub fn extractOutputText(gpa: std.mem.Allocator, body: []const u8, out: []u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return error.RewriteResponseUnparseable;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.RewriteResponseUnparseable;
    if (root.object.get("error")) |err| {
        if (err != .null) return error.RewriteRejected;
    }
    const output = root.object.get("output") orelse return error.RewriteResponseShape;
    if (output != .array) return error.RewriteResponseShape;

    var len: usize = 0;
    for (output.array.items) |item| {
        if (item != .object) continue;
        const item_type = getStr(item, "type") orelse continue;
        if (!std.mem.eql(u8, item_type, "message")) continue;
        const content = item.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            const part_type = getStr(part, "type") orelse continue;
            if (!std.mem.eql(u8, part_type, "output_text")) continue;
            const text = getStr(part, "text") orelse continue;
            if (len + text.len > out.len) return error.RewriteTooLong;
            @memcpy(out[len..][0..text.len], text);
            len += text.len;
        }
    }
    const trimmed = std.mem.trim(u8, out[0..len], " \t\r\n");
    if (trimmed.len == 0) return error.RewriteEmpty;
    return trimmed;
}

/// One blocking rewrite call. Runs on the Rewrite worker thread — never under the
/// Coordinator mutex. The connection pool inside `client` keeps the HTTPS connection
/// warm across Utterances (the daemon owns one long-lived client for this).
pub fn rewrite(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    utterance: []const u8,
    out: []u8,
) ![]const u8 {
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    try buildRequestBody(&body.writer, utterance);

    var auth_buf: [512]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch
        return error.RewriteKeyTooLong;

    var request = try client.request(.POST, try std.Uri.parse(endpoint), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
            // Plain identity body: `response.reader` does not decompress, and a few KB
            // of JSON is not worth the decompressing reader (same call as model_store).
            .accept_encoding = .omit,
        },
    });
    defer request.deinit();
    try request.sendBodyComplete(body.written());
    var response = try request.receiveHead(&.{});

    switch (response.head.status) {
        .ok => {},
        .unauthorized, .forbidden => return error.RewriteUnauthorized,
        .too_many_requests => return error.RewriteRateLimited,
        else => return error.RewriteHttpFailure,
    }
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const response_body = reader.allocRemaining(gpa, .limited(1024 * 1024)) catch
        return error.RewriteResponseUnreadable;
    defer gpa.free(response_body);
    return extractOutputText(gpa, response_body, out);
}

// ---- tests: the pure halves against canned JSON --------------------------------

const talloc = std.testing.allocator;

test "buildRequestBody emits the locked call config with the utterance JSON-escaped" {
    var body = std.Io.Writer.Allocating.init(talloc);
    defer body.deinit();
    try buildRequestBody(&body.writer, "säg \"hej\"\nno wait");

    const parsed = try std.json.parseFromSlice(std.json.Value, talloc, body.written(), .{});
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expectEqualStrings(model, root.object.get("model").?.string);
    try std.testing.expectEqualStrings(prompt, root.object.get("instructions").?.string);
    try std.testing.expectEqualStrings("säg \"hej\"\nno wait", root.object.get("input").?.string);
    try std.testing.expectEqualStrings("none", root.object.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqual(@as(i64, 0), root.object.get("temperature").?.integer);
    try std.testing.expectEqualStrings("default", root.object.get("service_tier").?.string);
}

test "the embedded prompt is v6: corrections and filler removal in one pass" {
    // Guards against the prompt file being emptied or swapped for a stub — the specific
    // rules validated by the prototype suite must be present.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "self-corrections") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "replaces only the specific words it revises") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Remove filler sounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Output only the cleaned text") != null);
}

test "extractOutputText joins message output_text parts and trims" {
    const body =
        \\{"id":"resp_1","status":"completed","output":[
        \\  {"type":"reasoning","summary":[]},
        \\  {"type":"message","status":"completed","content":[
        \\    {"type":"output_text","annotations":[],"text":"  Book a meeting at 18:00"}]},
        \\  {"type":"message","content":[{"type":"output_text","text":"\n"}]}
        \\]}
    ;
    var out: [256]u8 = undefined;
    const text = try extractOutputText(talloc, body, &out);
    try std.testing.expectEqualStrings("Book a meeting at 18:00", text);
}

test "extractOutputText rejects error payloads, missing text, and empty rewrites" {
    var out: [256]u8 = undefined;
    try std.testing.expectError(
        error.RewriteRejected,
        extractOutputText(talloc, "{\"error\":{\"message\":\"rate limit\"},\"output\":[]}", &out),
    );
    try std.testing.expectError(
        error.RewriteResponseShape,
        extractOutputText(talloc, "{\"id\":\"resp\"}", &out),
    );
    try std.testing.expectError(
        error.RewriteEmpty,
        extractOutputText(talloc, "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"  \\n\"}]}]}", &out),
    );
    try std.testing.expectError(
        error.RewriteResponseUnparseable,
        extractOutputText(talloc, "not json", &out),
    );
}

test "extractOutputText refuses text that cannot fit the caller's buffer" {
    const body = "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"0123456789\"}]}]}";
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.RewriteTooLong, extractOutputText(talloc, body, &tiny));
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
