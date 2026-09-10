const std = @import("std");

pub const max_pcm_len: usize = 24_000 * 2 * 26;

/// Benchmark reference kept verbatim with `whisper_helper_core.resample24To16Alloc` at
/// the measured commit. Production keeps owning the scalar implementation.
pub fn resampleScalarAlloc(allocator: std.mem.Allocator, pcm: []const u8) ![]f32 {
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

pub fn resampleVectorAlloc(allocator: std.mem.Allocator, pcm: []const u8) ![]f32 {
    if (pcm.len == 0) return error.EmptyPcm;
    if (pcm.len % 2 != 0) return error.OddPcmLength;
    if (pcm.len > max_pcm_len) return error.PcmTooLarge;

    const input_len = pcm.len / 2;
    const output_len = (input_len * 2) / 3;
    if (output_len == 0) return error.EmptyPcm;
    const output = try allocator.alloc(f32, output_len);
    errdefer allocator.free(output);

    const InputVector = @Vector(12, i16);
    const PhaseVector = @Vector(4, i16);
    const FloatPhaseVector = @Vector(4, f32);
    const OutputVector = @Vector(8, f32);
    const scale: FloatPhaseVector = @splat(1.0 / 32768.0);

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index + 12 <= input_len and output_index + 8 <= output_len) {
        const byte_index = input_index * 2;
        const input = std.mem.bytesToValue(InputVector, pcm[byte_index..][0..@sizeOf(InputVector)]);
        const direct_i: PhaseVector = @shuffle(i16, input, undefined, [_]i32{ 0, 3, 6, 9 });
        const average_left_i: PhaseVector = @shuffle(i16, input, undefined, [_]i32{ 1, 4, 7, 10 });
        const average_right_i: PhaseVector = @shuffle(i16, input, undefined, [_]i32{ 2, 5, 8, 11 });
        const direct: FloatPhaseVector = @as(FloatPhaseVector, @floatFromInt(direct_i)) * scale;
        const averaged = (@as(FloatPhaseVector, @floatFromInt(average_left_i)) +
            @as(FloatPhaseVector, @floatFromInt(average_right_i))) * @as(FloatPhaseVector, @splat(0.5)) * scale;
        const interleaved: OutputVector = @shuffle(f32, direct, averaged, [_]i32{ 0, -1, 1, -2, 2, -3, 3, -4 });
        const lanes: [8]f32 = interleaved;
        @memcpy(output[output_index..][0..8], &lanes);
        input_index += 12;
        output_index += 8;
    }

    for (output[output_index..], output_index..) |*sample, index| {
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

test "explicit Zig vectors preserve the scalar 3:2 mapping through a tail" {
    const pcm = encode(&.{
        -32768, 0,      32767,
        16384,  -16384, 0,
        8192,   4096,   -4096,
        32767,  -32768, 16384,
        -8192,
    });

    const actual = try resampleVectorAlloc(std.testing.allocator, &pcm);
    defer std.testing.allocator.free(actual);

    const expected = [_]f32{
        -1.0,              16383.5 / 32768.0,
        0.5,               -8192.0 / 32768.0,
        0.25,              0.0,
        32767.0 / 32768.0, -8192.0 / 32768.0,
    };
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want, got);
    }
}

test "explicit Zig vectors match every scalar sample at benchmark Segment sizes" {
    const input_sample_counts = [_]usize{ 13, 24_000 / 20, 24_000 * 5, max_pcm_len / 2 };
    for (input_sample_counts) |input_sample_count| {
        const pcm = try std.testing.allocator.alloc(u8, input_sample_count * 2);
        defer std.testing.allocator.free(pcm);
        fillDeterministicPcm(pcm);

        const scalar = try resampleScalarAlloc(std.testing.allocator, pcm);
        defer std.testing.allocator.free(scalar);
        const vector = try resampleVectorAlloc(std.testing.allocator, pcm);
        defer std.testing.allocator.free(vector);

        try std.testing.expectEqual((input_sample_count * 2) / 3, vector.len);
        try std.testing.expectEqual(scalar.len, vector.len);
        for (scalar, vector) |want, got| {
            try std.testing.expectEqual(want, got);
        }
        try std.testing.expectEqual(scalar[0], vector[0]);
        try std.testing.expectEqual(scalar[scalar.len - 1], vector[vector.len - 1]);
    }
}

fn encode(comptime samples: []const i16) [samples.len * 2]u8 {
    var pcm: [samples.len * 2]u8 = undefined;
    for (samples, 0..) |sample, index| {
        std.mem.writeInt(i16, pcm[index * 2 ..][0..2], sample, .little);
    }
    return pcm;
}

fn pcmSample(pcm: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(u16, pcm[index * 2 ..][0..2], .little);
    const signed: i16 = @bitCast(bits);
    return @as(f32, @floatFromInt(signed)) / 32768.0;
}

pub fn fillDeterministicPcm(pcm: []u8) void {
    var state: u32 = 0x4d59_5df4;
    var index: usize = 0;
    while (index < pcm.len) : (index += 2) {
        state = state *% 1_664_525 +% 1_013_904_223;
        std.mem.writeInt(i16, pcm[index..][0..2], @bitCast(@as(u16, @truncate(state))), .little);
    }
}
