const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ws = b.dependency("websocket", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "cli-dictation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("websocket", ws.module("websocket"));
    exe.root_module.linkFramework("AudioToolbox", .{});

    // AudioToolbox lives under the active SDK's framework dir; point the linker at it.
    const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
    exe.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the CLI dictation prototype");
    run_step.dependOn(&run_cmd.step);
}
