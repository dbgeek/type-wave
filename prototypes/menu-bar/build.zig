const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "menu-bar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const m = exe.root_module;
    m.linkFramework("AppKit", .{}); // NSStatusBar / NSStatusItem / NSMenu / NSMenuItem / NSAlert / NSImage / NSSecureTextField
    m.linkFramework("CoreFoundation", .{}); // CFRunLoopRun / CFRunLoopStop — same main loop the daemon blocks on
    m.linkSystemLibrary("objc", .{}); // -lobjc — objc_getClass / sel_registerName / objc_msgSend / objc_allocateClassPair

    // Frameworks + libobjc.tbd live under the active SDK; point the linker at both.
    const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
    m.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the menu-bar status-item spike");
    run_step.dependOn(&run_cmd.step);
}
