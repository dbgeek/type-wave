//! Pure parser for the size/digest identity shared by model receipts and the private helper.

const std = @import("std");

pub const Identity = struct {
    size: u64,
    sha256: [32]u8,
};

/// Serialize the size/digest identity — the whole of a `MODEL_MANIFEST` file.
pub fn encode(self: Identity, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "size={d}\nsha256={s}\n", .{ self.size, &std.fmt.bytesToHex(self.sha256, .lower) });
}

pub fn parse(text: []const u8) !Identity {
    const size = try std.fmt.parseInt(u64, lineValue(text, "size=") orelse return error.InvalidArtifactIdentity, 10);
    const encoded = lineValue(text, "sha256=") orelse return error.InvalidArtifactIdentity;
    if (encoded.len != 64) return error.InvalidArtifactIdentity;
    var sha256: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sha256, encoded) catch return error.InvalidArtifactIdentity;
    return .{ .size = size, .sha256 = sha256 };
}

fn lineValue(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix) and line.len > prefix.len) return line[prefix.len..];
    }
    return null;
}

test "artifact identity parser matches complete keys rather than substrings" {
    const identity = try parse("runtime_sha256=ffff\nsize=17\nsha256=abababababababababababababababababababababababababababababababab\n");
    try std.testing.expectEqual(@as(u64, 17), identity.size);
    try std.testing.expectEqual(@as(u8, 0xab), identity.sha256[0]);
}
