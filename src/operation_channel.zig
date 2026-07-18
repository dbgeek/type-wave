//! operation_channel.zig — the typed Model Operation observation wire between the
//! daemon-spawned CLI child (its stdout) and the daemon's menu-facing observation.
//!
//! The child's stderr stays human prose — the daemon log and the direct-CLI surface.
//! This channel is the machine truth: one versioned line per event, emitted only when
//! the daemon's spawn environment sets `env_var`, so a terminal run never sees it.
//! Emitter and decoder ship in the same binary (the daemon spawns its own executable),
//! so there is no version-skew path; `decode` still rejects anything unrecognized
//! rather than guessing, and the daemon skips undecodable lines.

const std = @import("std");
const model_store = @import("model_store.zig");

/// Present (any value) in the child's environment only when the daemon spawned it.
pub const env_var = "TYPE_WAVE_OPERATION_CHANNEL";

const prefix = "tw-op1 ";

pub const Event = union(enum) {
    operation: model_store.OperationEvent,
    /// Terminal failure: the error name the Status Item shows. The decoded payload
    /// borrows the input line — copy it before the line's buffer is reused.
    failed: []const u8,
};

pub fn encode(buffer: []u8, event: Event) ![]const u8 {
    return switch (event) {
        .operation => |op| switch (op) {
            .downloading => |bytes| std.fmt.bufPrint(buffer, prefix ++ "downloading {d} {d}", .{ bytes.completed, bytes.total }),
            .retrying => |retry| std.fmt.bufPrint(
                buffer,
                prefix ++ "retrying {d} {d} {d} {d} {d}",
                .{ retry.attempt, retry.budget, retry.delay_ms, retry.bytes.completed, retry.bytes.total },
            ),
            .verifying => |bytes| std.fmt.bufPrint(buffer, prefix ++ "verifying {d} {d}", .{ bytes.completed, bytes.total }),
            .smoke_testing => std.fmt.bufPrint(buffer, prefix ++ "smoke_testing", .{}),
            .waiting_for_inference => std.fmt.bufPrint(buffer, prefix ++ "waiting_for_inference", .{}),
            .activating => std.fmt.bufPrint(buffer, prefix ++ "activating", .{}),
            .removing => std.fmt.bufPrint(buffer, prefix ++ "removing", .{}),
        },
        .failed => |name| std.fmt.bufPrint(buffer, prefix ++ "failed {s}", .{name}),
    };
}

/// Null = not a channel line (prose, corruption, or an unknown variant) — skip it.
pub fn decode(line: []const u8) ?Event {
    const trimmed = std.mem.trimEnd(u8, line, "\r\n \t");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var fields = std.mem.tokenizeScalar(u8, trimmed[prefix.len..], ' ');
    const tag = fields.next() orelse return null;
    if (std.mem.eql(u8, tag, "downloading")) {
        const bytes = takeBytes(&fields) orelse return null;
        return doneWith(&fields, .{ .operation = .{ .downloading = bytes } });
    }
    if (std.mem.eql(u8, tag, "retrying")) {
        const attempt = takeInt(u8, &fields) orelse return null;
        const budget = takeInt(u8, &fields) orelse return null;
        const delay_ms = takeInt(u32, &fields) orelse return null;
        const bytes = takeBytes(&fields) orelse return null;
        return doneWith(&fields, .{ .operation = .{ .retrying = .{
            .attempt = attempt,
            .budget = budget,
            .delay_ms = delay_ms,
            .bytes = bytes,
        } } });
    }
    if (std.mem.eql(u8, tag, "verifying")) {
        const bytes = takeBytes(&fields) orelse return null;
        return doneWith(&fields, .{ .operation = .{ .verifying = bytes } });
    }
    if (std.mem.eql(u8, tag, "smoke_testing")) return doneWith(&fields, .{ .operation = .smoke_testing });
    if (std.mem.eql(u8, tag, "waiting_for_inference")) return doneWith(&fields, .{ .operation = .waiting_for_inference });
    if (std.mem.eql(u8, tag, "activating")) return doneWith(&fields, .{ .operation = .activating });
    if (std.mem.eql(u8, tag, "removing")) return doneWith(&fields, .{ .operation = .removing });
    if (std.mem.eql(u8, tag, "failed")) {
        const name = fields.next() orelse return null;
        return doneWith(&fields, .{ .failed = name });
    }
    return null;
}

fn doneWith(fields: *std.mem.TokenIterator(u8, .scalar), event: Event) ?Event {
    if (fields.next() != null) return null; // trailing garbage is corruption, not an event
    return event;
}

fn takeInt(comptime T: type, fields: *std.mem.TokenIterator(u8, .scalar)) ?T {
    const field = fields.next() orelse return null;
    return std.fmt.parseInt(T, field, 10) catch null;
}

fn takeBytes(fields: *std.mem.TokenIterator(u8, .scalar)) ?model_store.ByteProgress {
    const completed = takeInt(u64, fields) orelse return null;
    const total = takeInt(u64, fields) orelse return null;
    return .{ .completed = completed, .total = total };
}

test "every Model Operation event round-trips the wire" {
    const events = [_]Event{
        .{ .operation = .{ .downloading = .{ .completed = 12_345, .total = 67_890 } } },
        .{ .operation = .{ .retrying = .{ .attempt = 2, .budget = 5, .delay_ms = 4_000, .bytes = .{ .completed = 12_345, .total = 67_890 } } } },
        .{ .operation = .{ .verifying = .{ .completed = 67_890, .total = 67_890 } } },
        .{ .operation = .smoke_testing },
        .{ .operation = .waiting_for_inference },
        .{ .operation = .activating },
        .{ .operation = .removing },
        .{ .failed = "ModelDownloadRejected" },
    };
    for (events) |event| {
        var buffer: [256]u8 = undefined;
        const line = try encode(&buffer, event);
        try std.testing.expectEqualDeep(event, decode(line).?);
    }
}

test "prose, corruption, and unknown variants never decode" {
    const rejected = [_][]const u8{
        "Model Operation: downloading 1/2 bytes", // stderr prose
        "",
        "tw-op1",
        "tw-op1 ",
        "tw-op1 warp_drive", // unknown variant
        "tw-op1 downloading", // missing fields
        "tw-op1 downloading 12", // missing total
        "tw-op1 downloading twelve 13", // non-numeric
        "tw-op1 downloading 12 13 14", // trailing garbage
        "tw-op1 retrying 2 5 4000 12345", // truncated
        "tw-op1 smoke_testing extra",
        "tw-op1 failed",
        "tw-op2 downloading 12 13", // a future wire version is not this one
    };
    for (rejected) |line| try std.testing.expect(decode(line) == null);
}

test "decoding tolerates the reader's line endings" {
    try std.testing.expectEqualDeep(
        Event{ .operation = .{ .downloading = .{ .completed = 1, .total = 2 } } },
        decode("tw-op1 downloading 1 2\r\n").?,
    );
}
