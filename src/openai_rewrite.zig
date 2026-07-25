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
//! text. Policy (when to rewrite, the raw-transcript fallback, the ~3 s budget) lives in
//! the Utterance Coordinator and rewrite_adapter.zig. The pure halves
//! (`buildRequestBody`, `extractOutputText`) are exercised by tests with canned JSON —
//! no network.
//!
//! The one piece of self-protection that does live here is `call_deadline_ms`: a bound on
//! how long *one call* may occupy the Rewrite worker. It is not the Coordinator's budget
//! and does not replace it — see the constant.

const std = @import("std");

pub const model = "gpt-5.4-mini";
pub const endpoint = "https://api.openai.com/v1/responses";

/// How long one Rewrite call may occupy the Rewrite worker, connect through read.
///
/// This is **not** the Coordinator's ~3 s rewrite budget (`coordinator.rewrite_deadline`)
/// and does not do its job. That budget decides when to stop *waiting* and insert the raw
/// Final Transcript — it protects the Utterance, which is why dictation keeps working
/// through a slow rewrite. It never unblocks this worker. The Rewrite adapter runs a
/// single worker that claims its next job only when the current call returns, so an
/// endpoint (or any middlebox) that accepts the request and then answers nothing parks
/// that worker for the process's life: every later Utterance stages a Rewrite nobody
/// claims, and Backtrack is silently gone until the daemon restarts.
///
/// 5 s is the 3 s budget plus a 2 s margin. Nothing below the budget is at risk — by 3 s
/// the Coordinator has already inserted the raw transcript and will stale-reject whatever
/// this call eventually says, so a late answer is worth nothing to its own Utterance and
/// the only thing the extra 2 s buys is not tearing down a warm pooled connection over a
/// merely slow answer (#141 measured a fat tail: ~10% of warm calls exceed 2.5 s, with
/// rare ~10 s and ~15 s outliers). Above it, the cost is the *next* Utterance's Backtrack,
/// so the margin stays small: the worker is free again ~2 s after the stalled Utterance
/// resolved, well before a user can speak the next one.
///
/// Consequence worth naming: because 5 s sits above the budget, the user never experiences
/// this deadline as the fallback — the budget always fires first and the raw transcript is
/// already in. Cutting a call off is about the *feature surviving*, not this Utterance.
pub const call_deadline_ms: i64 = 5_000;

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

/// One rewrite call, bounded by `call_deadline_ms`. Runs on the Rewrite worker thread —
/// never under the Coordinator mutex. The connection pool inside `client` keeps the HTTPS
/// connection warm across Utterances (the daemon owns one long-lived client for this).
pub fn rewrite(
    io: std.Io,
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    utterance: []const u8,
    out: []u8,
) anyerror![]const u8 {
    return rewriteWithin(io, client, gpa, api_key, utterance, out, endpoint, call_deadline_ms);
}

/// `rewrite` with the endpoint and the deadline spelled out — the seam the deadline test
/// drives against a local transport that accepts the request and then answers nothing.
///
/// The call runs as a concurrent `Io` task raced against a sleeper; whichever finishes
/// first wins and the loser is canceled. Cancellation is what makes the bound real rather
/// than advisory: `Io.Threaded` signals a canceled task's thread, so the call's blocked
/// read returns instead of parking the worker forever.
///
/// This does not return until *both* tasks have finished — `cancelDiscard` waits — so
/// every slice the call borrows (`api_key` above all, which the caller scrubs and frees
/// on the way out) is still alive for as long as the call can touch it.
pub fn rewriteWithin(
    io: std.Io,
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    utterance: []const u8,
    out: []u8,
    url: []const u8,
    deadline_ms: i64,
) anyerror![]const u8 {
    const Outcome = union(enum) {
        answered: anyerror![]const u8,
        deadline: std.Io.Cancelable!void,
    };
    var call: Call = .{
        .client = client,
        .gpa = gpa,
        .api_key = api_key,
        .utterance = utterance,
        .out = out,
        .url = url,
    };
    var slots: [2]Outcome = undefined;
    var race = std.Io.Select(Outcome).init(io, &slots);
    defer race.cancelDiscard(); // cancels the loser, and waits for it to actually stop
    race.concurrent(.answered, Call.run, .{&call}) catch return error.RewriteConcurrencyUnavailable;
    race.concurrent(.deadline, sleepMs, .{ io, deadline_ms }) catch return error.RewriteConcurrencyUnavailable;
    return switch (race.await() catch return error.RewriteCanceled) {
        .answered => |answer| answer,
        .deadline => error.RewriteTimedOut,
    };
}

fn sleepMs(io: std.Io, ms: i64) std.Io.Cancelable!void {
    return std.Io.sleep(io, .fromMilliseconds(ms), .awake);
}

/// The rewrite call's arguments, boxed so the racing task can carry one pointer.
const Call = struct {
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    utterance: []const u8,
    out: []u8,
    url: []const u8,

    fn run(c: *Call) anyerror![]const u8 {
        return callOnce(c.client, c.gpa, c.api_key, c.utterance, c.out, c.url);
    }
};

/// The unbounded call itself — only ever reached from `Call.run`, i.e. on a cancelable
/// task, never on the Rewrite worker directly.
fn callOnce(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    utterance: []const u8,
    out: []u8,
    url: []const u8,
) ![]const u8 {
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    try buildRequestBody(&body.writer, utterance);

    var auth_buf: [512]u8 = undefined;
    // The one stack copy of the key on this path: zeroed on the way out, whether the call
    // succeeded or threw, so the secret does not sit in this frame's stack memory for a
    // crash report or a core dump to pick up (#254).
    defer std.crypto.secureZero(u8, &auth_buf);
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch
        return error.RewriteKeyTooLong;

    var request = try client.request(.POST, try std.Uri.parse(url), .{
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

test "the call deadline sits above the Coordinator's rewrite budget" {
    // The budget decides when to insert raw; the call deadline only frees the worker. If
    // the deadline ever dropped below the budget it would start killing calls that could
    // still have landed inside their Utterance — a different, worse feature.
    const coord = @import("coordinator.zig");
    try std.testing.expect(call_deadline_ms > coord.rewrite_deadline.final_ms);
}

test "a transport that accepts the request and never answers is cut off by the deadline" {
    var threaded = std.Io.Threaded.init(talloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Loopback, ephemeral-ish: the port only has to be free, not predictable.
    var port: u16 = 45871;
    var server = while (port < 45900) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        break addr.listen(io, .{ .mode = .stream }) catch continue;
    } else return error.SkipZigTest;
    defer server.deinit(io);

    // The silent endpoint: completes the TCP handshake, reads nothing, replies nothing,
    // and holds the connection open — the exact shape that used to park the worker.
    const Silent = struct {
        fn serve(s: *std.Io.net.Server, silent_io: std.Io) void {
            var stream = s.accept(silent_io) catch return;
            defer stream.close(silent_io);
            std.Io.sleep(silent_io, .fromSeconds(60), .awake) catch {};
        }
    };
    var silent = io.concurrent(Silent.serve, .{ &server, io }) catch return error.SkipZigTest;
    defer _ = silent.cancel(io);

    var client: std.http.Client = .{ .allocator = talloc, .io = io };
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/responses", .{port});

    var out: [256]u8 = undefined;
    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    try std.testing.expectError(
        error.RewriteTimedOut,
        rewriteWithin(io, &client, talloc, "sk-test", "at 20:00 no 18:00", &out, url, 300),
    );
    // Generous: the assertion that matters is "bounded at all", not the exact latency.
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - started, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 10_000);
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
