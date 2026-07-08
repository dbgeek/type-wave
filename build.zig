const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ws = b.dependency("websocket", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "type-wave",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const m = exe.root_module;
    m.addImport("websocket", ws.module("websocket"));

    // Transcription Session's vendored websocket rides std.crypto.tls (no extra
    // framework); Capture's AudioQueue lives in AudioToolbox.
    m.linkFramework("AudioToolbox", .{});
    // Talk Key tap + Insertion event synthesis.
    m.linkFramework("CoreGraphics", .{}); // CGEventTap, CGEvent*, CG*EventAccess
    m.linkFramework("CoreFoundation", .{}); // run loop, CFRelease
    m.linkFramework("Carbon", .{}); // IsSecureEventInputEnabled
    m.linkFramework("ApplicationServices", .{}); // umbrella (AX if ever needed)
    m.linkFramework("AppKit", .{}); // NSPasteboard via the ObjC runtime
    m.linkSystemLibrary("objc", .{}); // -lobjc

    // Frameworks + libobjc.tbd live under the active SDK; point the linker at both.
    const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
    m.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run type-wave (foreground skeleton)");
    run_step.dependOn(&run_cmd.step);
}
