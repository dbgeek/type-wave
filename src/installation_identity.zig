//! Owned, comparable Model Installation receipt identity for cross-thread presentation.

const std = @import("std");

pub const Text = struct {
    bytes: [128]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(value_bytes: []const u8) !Text {
        if (value_bytes.len == 0 or value_bytes.len > 128) return error.InvalidInstallationIdentity;
        var text = Text{ .len = @intCast(value_bytes.len) };
        @memcpy(text.bytes[0..value_bytes.len], value_bytes);
        return text;
    }

    pub fn value(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Identity = struct {
    repository: Text,
    revision: Text,
    runtime: Text,
    runtime_sha256: [32]u8,
    artifact: Text,
    installation_id: ?Text,
    artifact_size: u64,
    artifact_sha256: [32]u8,
    installed_by: Text,
};

test "identity text owns the receipt value" {
    var source = [_]u8{ 'm', 'o', 'd', 'e', 'l' };
    const owned = try Text.init(&source);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("model", owned.value());
}
