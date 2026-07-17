const std = @import("std");

pub const magic = "TWW1";
pub const version: u16 = 1;
pub const header_len: usize = 12;
pub const max_payload_len: u32 = 2 * 1024 * 1024;

pub const Kind = enum(u16) {
    ready = 1,
    startup_failed = 2,
    transcribe = 3,
    cancel = 4,
    final = 5,
    failed = 6,
};

pub const Language = enum(u8) {
    english = 1,
    swedish = 2,
    auto_detect = 3,
};

pub const Diagnostic = struct {
    code: u16,
    message: []const u8,
};

pub const Transcribe = struct {
    id: u64,
    language: Language,
    pcm: []const u8,
};

pub const Final = struct {
    id: u64,
    text: []const u8,
};

pub const Failure = struct {
    id: u64,
    code: u16,
    message: []const u8,
};

pub const Frame = union(Kind) {
    ready: [32]u8,
    startup_failed: Diagnostic,
    transcribe: Transcribe,
    cancel: u64,
    final: Final,
    failed: Failure,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready, .cancel => {},
            .startup_failed => |value| allocator.free(value.message),
            .transcribe => |value| allocator.free(value.pcm),
            .final => |value| allocator.free(value.text),
            .failed => |value| allocator.free(value.message),
        }
        self.* = undefined;
    }
};

pub const DecodeError = error{
    UnexpectedEof,
    InvalidMagic,
    UnsupportedVersion,
    UnknownKind,
    PayloadTooLarge,
    InconsistentLength,
    InvalidPayload,
    InvalidUtf8,
    InvalidLanguage,
    NonzeroReserved,
    OddPcmLength,
} || std.mem.Allocator.Error;

pub const EncodeError = error{
    PayloadTooLarge,
    InvalidPayload,
    InvalidUtf8,
    OddPcmLength,
} || std.mem.Allocator.Error;

fn payloadLength(frame: Frame) EncodeError!u32 {
    const length: usize = switch (frame) {
        .ready => 32,
        .startup_failed => |value| blk: {
            if (!std.unicode.utf8ValidateSlice(value.message)) return error.InvalidUtf8;
            break :blk 6 + value.message.len;
        },
        .transcribe => |value| blk: {
            if (value.pcm.len == 0) return error.InvalidPayload;
            if (value.pcm.len % 2 != 0) return error.OddPcmLength;
            break :blk 20 + value.pcm.len;
        },
        .cancel => 8,
        .final => |value| blk: {
            if (!std.unicode.utf8ValidateSlice(value.text)) return error.InvalidUtf8;
            break :blk 12 + value.text.len;
        },
        .failed => |value| blk: {
            if (!std.unicode.utf8ValidateSlice(value.message)) return error.InvalidUtf8;
            break :blk 14 + value.message.len;
        },
    };
    if (length > max_payload_len) return error.PayloadTooLarge;
    return @intCast(length);
}

pub fn encodeAlloc(allocator: std.mem.Allocator, frame: Frame) EncodeError![]u8 {
    const payload_len = try payloadLength(frame);
    const bytes = try allocator.alloc(u8, header_len + payload_len);
    errdefer allocator.free(bytes);

    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u16, bytes[4..6], version, .little);
    std.mem.writeInt(u16, bytes[6..8], @intFromEnum(frame), .little);
    std.mem.writeInt(u32, bytes[8..12], payload_len, .little);
    const payload = bytes[header_len..];
    switch (frame) {
        .ready => |digest| @memcpy(payload, &digest),
        .startup_failed => |value| {
            std.mem.writeInt(u16, payload[0..2], value.code, .little);
            std.mem.writeInt(u32, payload[2..6], @intCast(value.message.len), .little);
            @memcpy(payload[6..], value.message);
        },
        .transcribe => |value| {
            std.mem.writeInt(u64, payload[0..8], value.id, .little);
            payload[8] = @intFromEnum(value.language);
            @memset(payload[9..16], 0);
            std.mem.writeInt(u32, payload[16..20], @intCast(value.pcm.len), .little);
            @memcpy(payload[20..], value.pcm);
        },
        .cancel => |id| std.mem.writeInt(u64, payload[0..8], id, .little),
        .final => |value| {
            std.mem.writeInt(u64, payload[0..8], value.id, .little);
            std.mem.writeInt(u32, payload[8..12], @intCast(value.text.len), .little);
            @memcpy(payload[12..], value.text);
        },
        .failed => |value| {
            std.mem.writeInt(u64, payload[0..8], value.id, .little);
            std.mem.writeInt(u16, payload[8..10], value.code, .little);
            std.mem.writeInt(u32, payload[10..14], @intCast(value.message.len), .little);
            @memcpy(payload[14..], value.message);
        },
    }
    return bytes;
}

fn exactVariable(payload: []const u8, prefix_len: usize, declared_len: u32) DecodeError![]const u8 {
    if (declared_len > max_payload_len) return error.PayloadTooLarge;
    if (prefix_len + declared_len != payload.len) return error.InconsistentLength;
    return payload[prefix_len..];
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Frame {
    if (bytes.len < header_len) return error.UnexpectedEof;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
    const kind = std.enums.fromInt(Kind, std.mem.readInt(u16, bytes[6..8], .little)) orelse return error.UnknownKind;
    const payload_len = std.mem.readInt(u32, bytes[8..12], .little);
    if (payload_len > max_payload_len) return error.PayloadTooLarge;
    if (bytes.len < header_len + payload_len) return error.UnexpectedEof;
    if (bytes.len != header_len + payload_len) return error.InconsistentLength;
    const payload = bytes[header_len..];

    return switch (kind) {
        .ready => blk: {
            if (payload.len != 32) return error.InvalidPayload;
            break :blk .{ .ready = payload[0..32].* };
        },
        .startup_failed => blk: {
            if (payload.len < 6) return error.InvalidPayload;
            const message = try exactVariable(payload, 6, std.mem.readInt(u32, payload[2..6], .little));
            if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
            break :blk .{ .startup_failed = .{
                .code = std.mem.readInt(u16, payload[0..2], .little),
                .message = try allocator.dupe(u8, message),
            } };
        },
        .transcribe => blk: {
            if (payload.len < 20) return error.InvalidPayload;
            const language = std.enums.fromInt(Language, payload[8]) orelse return error.InvalidLanguage;
            for (payload[9..16]) |reserved| if (reserved != 0) return error.NonzeroReserved;
            const pcm = try exactVariable(payload, 20, std.mem.readInt(u32, payload[16..20], .little));
            if (pcm.len == 0) return error.InvalidPayload;
            if (pcm.len % 2 != 0) return error.OddPcmLength;
            break :blk .{ .transcribe = .{
                .id = std.mem.readInt(u64, payload[0..8], .little),
                .language = language,
                .pcm = try allocator.dupe(u8, pcm),
            } };
        },
        .cancel => blk: {
            if (payload.len != 8) return error.InvalidPayload;
            break :blk .{ .cancel = std.mem.readInt(u64, payload[0..8], .little) };
        },
        .final => blk: {
            if (payload.len < 12) return error.InvalidPayload;
            const text = try exactVariable(payload, 12, std.mem.readInt(u32, payload[8..12], .little));
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            break :blk .{ .final = .{
                .id = std.mem.readInt(u64, payload[0..8], .little),
                .text = try allocator.dupe(u8, text),
            } };
        },
        .failed => blk: {
            if (payload.len < 14) return error.InvalidPayload;
            const message = try exactVariable(payload, 14, std.mem.readInt(u32, payload[10..14], .little));
            if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
            break :blk .{ .failed = .{
                .id = std.mem.readInt(u64, payload[0..8], .little),
                .code = std.mem.readInt(u16, payload[8..10], .little),
                .message = try allocator.dupe(u8, message),
            } };
        },
    };
}

/// Reads exactly one frame from a private pipe. A clean EOF is valid only between frames;
/// EOF after any header or payload byte is a protocol failure.
pub fn readFd(allocator: std.mem.Allocator, fd: std.c.fd_t) !?Frame {
    var header: [header_len]u8 = undefined;
    var offset: usize = 0;
    while (offset < header.len) {
        const count = try readSome(fd, header[offset..]);
        if (count == 0) {
            if (offset == 0) return null;
            return error.UnexpectedEof;
        }
        offset += count;
    }
    if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, header[4..6], .little) != version) return error.UnsupportedVersion;
    const payload_len = std.mem.readInt(u32, header[8..12], .little);
    if (payload_len > max_payload_len) return error.PayloadTooLarge;

    const bytes = try allocator.alloc(u8, header_len + payload_len);
    defer allocator.free(bytes);
    @memcpy(bytes[0..header_len], &header);
    offset = header_len;
    while (offset < bytes.len) {
        const count = try readSome(fd, bytes[offset..]);
        if (count == 0) return error.UnexpectedEof;
        offset += count;
    }
    return try decode(allocator, bytes);
}

pub fn writeFd(allocator: std.mem.Allocator, fd: std.c.fd_t, frame: Frame) !void {
    const bytes = try encodeAlloc(allocator, frame);
    defer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try writeSome(fd, bytes[offset..]);
        if (count == 0) return error.BrokenPipe;
        offset += count;
    }
}

fn readSome(fd: std.c.fd_t, bytes: []u8) !usize {
    while (true) {
        const count = std.c.read(fd, bytes.ptr, bytes.len);
        if (count >= 0) return @intCast(count);
        if (std.c.errno(count) != .INTR) return error.ReadFailed;
    }
}

fn writeSome(fd: std.c.fd_t, bytes: []const u8) !usize {
    while (true) {
        const count = std.c.write(fd, bytes.ptr, bytes.len);
        if (count >= 0) return @intCast(count);
        if (std.c.errno(count) != .INTR) return error.WriteFailed;
    }
}

test "version 1 protocol round-trips every identity-tagged frame" {
    const allocator = std.testing.allocator;
    const frames = [_]Frame{
        .{ .ready = @splat(0xab) },
        .{ .startup_failed = .{ .code = 7, .message = "model rejected" } },
        .{ .transcribe = .{ .id = 42, .language = .swedish, .pcm = &.{ 0x01, 0x02, 0x03, 0x04 } } },
        .{ .cancel = 42 },
        .{ .final = .{ .id = 42, .text = "Hallå världen" } },
        .{ .failed = .{ .id = 42, .code = 9, .message = "inference failed" } },
    };

    for (frames) |frame| {
        const encoded = try encodeAlloc(allocator, frame);
        defer allocator.free(encoded);
        var decoded = try decode(allocator, encoded);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualDeep(frame, decoded);
    }
}

test "protocol rejects malformed frames instead of interpreting their bytes" {
    const allocator = std.testing.allocator;
    const valid = try encodeAlloc(allocator, .{ .final = .{ .id = 9, .text = "ok" } });
    defer allocator.free(valid);

    const Mutator = struct {
        fn wrongMagic(bytes: []u8) void {
            bytes[0] = 'X';
        }
        fn wrongVersion(bytes: []u8) void {
            bytes[4] = 2;
        }
        fn unknownKind(bytes: []u8) void {
            bytes[6] = 99;
        }
        fn inconsistentLength(bytes: []u8) void {
            bytes[8] += 1;
        }
        fn invalidUtf8(bytes: []u8) void {
            bytes[24] = 0xff;
        }
    };
    const cases = .{
        .{ Mutator.wrongMagic, error.InvalidMagic },
        .{ Mutator.wrongVersion, error.UnsupportedVersion },
        .{ Mutator.unknownKind, error.UnknownKind },
        .{ Mutator.inconsistentLength, error.UnexpectedEof },
        .{ Mutator.invalidUtf8, error.InvalidUtf8 },
    };
    inline for (cases) |case| {
        const changed = try allocator.dupe(u8, valid);
        defer allocator.free(changed);
        case[0](changed);
        try std.testing.expectError(case[1], decode(allocator, changed));
    }

    try std.testing.expectError(error.UnexpectedEof, decode(allocator, valid[0 .. valid.len - 1]));
    const trailing = try std.mem.concat(allocator, u8, &.{ valid, &.{0} });
    defer allocator.free(trailing);
    try std.testing.expectError(error.InconsistentLength, decode(allocator, trailing));
}

test "transcribe validates language reserved bytes PCM shape and payload ceiling" {
    const allocator = std.testing.allocator;
    const valid = try encodeAlloc(allocator, .{ .transcribe = .{ .id = 3, .language = .english, .pcm = &.{ 0, 0 } } });
    defer allocator.free(valid);

    const invalid_language = try allocator.dupe(u8, valid);
    defer allocator.free(invalid_language);
    invalid_language[20] = 4;
    try std.testing.expectError(error.InvalidLanguage, decode(allocator, invalid_language));

    const nonzero_reserved = try allocator.dupe(u8, valid);
    defer allocator.free(nonzero_reserved);
    nonzero_reserved[21] = 1;
    try std.testing.expectError(error.NonzeroReserved, decode(allocator, nonzero_reserved));

    const odd_pcm = try allocator.dupe(u8, valid);
    defer allocator.free(odd_pcm);
    std.mem.writeInt(u32, odd_pcm[28..32], 1, .little);
    std.mem.writeInt(u32, odd_pcm[8..12], 21, .little);
    try std.testing.expectError(error.OddPcmLength, decode(allocator, odd_pcm[0 .. odd_pcm.len - 1]));

    var header: [header_len]u8 = @splat(0);
    @memcpy(header[0..4], magic);
    std.mem.writeInt(u16, header[4..6], version, .little);
    std.mem.writeInt(u16, header[6..8], @intFromEnum(Kind.final), .little);
    std.mem.writeInt(u32, header[8..12], max_payload_len + 1, .little);
    try std.testing.expectError(error.PayloadTooLarge, decode(allocator, &header));
}
