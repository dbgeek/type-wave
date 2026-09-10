const std = @import("std");
const resampler = @import("resampler.zig");

const observation_count = 501;

const Case = struct {
    name: []const u8,
    input_samples: usize,
    operations_per_observation: usize,
};

const cases = [_]Case{
    .{ .name = "50 ms", .input_samples = 24_000 / 20, .operations_per_observation = 64 },
    .{ .name = "5 s", .input_samples = 24_000 * 5, .operations_per_observation = 4 },
    .{ .name = "26 s ceiling", .input_samples = resampler.max_pcm_len / 2, .operations_per_observation = 1 },
};

const Timings = struct {
    wall_ns: [observation_count]u64 = undefined,
    cpu_ns: [observation_count]u64 = undefined,
};

const Summary = struct {
    median_wall_ns: u64,
    p95_wall_ns: u64,
    p99_wall_ns: u64,
    median_cpu_ns: u64,
};

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const allocator = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print(
        "Segment conversion benchmark (ReleaseFast; {d} observations; allocation included)\n" ++
            "equivalence=PASS (length, endpoints, every sample); tolerance=0.0 f32\n" ++
            "tail=p95/p99 wall time; CPU=process CPU time\n\n",
        .{observation_count},
    );
    std.debug.print("{s: <10} {s: <8} {s: >10} {s: >10} {s: >10} {s: >10}\n", .{
        "Segment", "method", "median us", "p95 us", "p99 us", "CPU med us",
    });

    for (cases) |case| {
        const pcm = try allocator.alloc(u8, case.input_samples * 2);
        defer allocator.free(pcm);
        resampler.fillDeterministicPcm(pcm);
        try verifyEquivalent(allocator, pcm);

        warm(allocator, pcm, resampler.resampleScalarAlloc);
        warm(allocator, pcm, resampler.resampleVectorAlloc);

        var scalar_times = Timings{};
        var vector_times = Timings{};
        for (0..observation_count) |index| {
            if (index % 2 == 0) {
                scalar_times.wall_ns[index], scalar_times.cpu_ns[index] = try measureBatch(
                    io,
                    allocator,
                    pcm,
                    case.operations_per_observation,
                    resampler.resampleScalarAlloc,
                );
                vector_times.wall_ns[index], vector_times.cpu_ns[index] = try measureBatch(
                    io,
                    allocator,
                    pcm,
                    case.operations_per_observation,
                    resampler.resampleVectorAlloc,
                );
            } else {
                vector_times.wall_ns[index], vector_times.cpu_ns[index] = try measureBatch(
                    io,
                    allocator,
                    pcm,
                    case.operations_per_observation,
                    resampler.resampleVectorAlloc,
                );
                scalar_times.wall_ns[index], scalar_times.cpu_ns[index] = try measureBatch(
                    io,
                    allocator,
                    pcm,
                    case.operations_per_observation,
                    resampler.resampleScalarAlloc,
                );
            }
        }

        divideTimings(&scalar_times, case.operations_per_observation);
        divideTimings(&vector_times, case.operations_per_observation);
        const scalar = summarize(&scalar_times);
        const vector = summarize(&vector_times);
        printSummary(case.name, "scalar", scalar);
        printSummary("", "zig-vector", vector);
        std.debug.print(
            "{s: <10} {s: <8} {d: >9.2}x wall, {d:.2}x CPU\n",
            .{
                "",
                "speedup",
                ratio(scalar.median_wall_ns, vector.median_wall_ns),
                ratio(scalar.median_cpu_ns, vector.median_cpu_ns),
            },
        );
    }
}

fn warm(
    allocator: std.mem.Allocator,
    pcm: []const u8,
    comptime convert: fn (std.mem.Allocator, []const u8) anyerror![]f32,
) void {
    for (0..32) |_| {
        const output = convert(allocator, pcm) catch unreachable;
        std.mem.doNotOptimizeAway(output[output.len - 1]);
        allocator.free(output);
    }
}

fn measureBatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    pcm: []const u8,
    operations: usize,
    comptime convert: fn (std.mem.Allocator, []const u8) anyerror![]f32,
) !struct { u64, u64 } {
    const wall_started = std.Io.Clock.now(.awake, io).nanoseconds;
    const cpu_started = std.Io.Clock.now(.cpu_process, io).nanoseconds;
    for (0..operations) |_| {
        const output = try convert(allocator, pcm);
        std.mem.doNotOptimizeAway(output[output.len - 1]);
        allocator.free(output);
    }
    const cpu_elapsed = std.Io.Clock.now(.cpu_process, io).nanoseconds - cpu_started;
    const wall_elapsed = std.Io.Clock.now(.awake, io).nanoseconds - wall_started;
    return .{ @intCast(wall_elapsed), @intCast(cpu_elapsed) };
}

fn divideTimings(timings: *Timings, divisor: usize) void {
    for (&timings.wall_ns) |*elapsed| elapsed.* /= divisor;
    for (&timings.cpu_ns) |*elapsed| elapsed.* /= divisor;
}

fn summarize(timings: *Timings) Summary {
    std.mem.sortUnstable(u64, &timings.wall_ns, {}, std.sort.asc(u64));
    std.mem.sortUnstable(u64, &timings.cpu_ns, {}, std.sort.asc(u64));
    return .{
        .median_wall_ns = timings.wall_ns[observation_count / 2],
        .p95_wall_ns = timings.wall_ns[percentileIndex(95)],
        .p99_wall_ns = timings.wall_ns[percentileIndex(99)],
        .median_cpu_ns = timings.cpu_ns[observation_count / 2],
    };
}

fn percentileIndex(comptime percentile: usize) usize {
    return @min(((observation_count * percentile + 99) / 100) - 1, observation_count - 1);
}

fn printSummary(name: []const u8, method: []const u8, summary: Summary) void {
    std.debug.print("{s: <10} {s: <10} {d: >10.2} {d: >10.2} {d: >10.2} {d: >10.2}\n", .{
        name,
        method,
        micros(summary.median_wall_ns),
        micros(summary.p95_wall_ns),
        micros(summary.p99_wall_ns),
        micros(summary.median_cpu_ns),
    });
}

fn micros(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000.0;
}

fn ratio(numerator: u64, denominator: u64) f64 {
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn verifyEquivalent(allocator: std.mem.Allocator, pcm: []const u8) !void {
    const scalar = try resampler.resampleScalarAlloc(allocator, pcm);
    defer allocator.free(scalar);
    const vector = try resampler.resampleVectorAlloc(allocator, pcm);
    defer allocator.free(vector);
    if (scalar.len != vector.len) return error.OutputLengthMismatch;
    for (scalar, vector) |want, got| {
        if (want != got) return error.SampleMismatch;
    }
    if (scalar[0] != vector[0] or scalar[scalar.len - 1] != vector[vector.len - 1]) {
        return error.EndpointMismatch;
    }
}
