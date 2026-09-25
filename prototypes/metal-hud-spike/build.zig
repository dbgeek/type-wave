const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "metal-hud-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const m = exe.root_module;
    m.linkFramework("AppKit", .{}); // NSPanel / NSScreen / NSColor via the ObjC runtime
    m.linkFramework("Foundation", .{}); // NSString, NSRunLoop, NSRunLoopCommonModes
    m.linkFramework("QuartzCore", .{}); // CAMetalLayer, CADisplayLink, CACurrentMediaTime
    m.linkFramework("Metal", .{}); // MTLCreateSystemDefaultDevice + the render pipeline
    m.linkFramework("CoreFoundation", .{}); // run loop, timers, stdin CFFileDescriptor
    m.linkSystemLibrary("objc", .{}); // -lobjc

    // Frameworks + libobjc.tbd live under the active SDK; point the linker at both.
    const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
    m.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the Metal HUD spike");
    run_step.dependOn(&run_cmd.step);
}
