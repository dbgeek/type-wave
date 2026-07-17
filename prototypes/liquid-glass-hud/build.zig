const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // AppKit gates Liquid Glass on the binary's LC_BUILD_VERSION sdk stamp
    // (#40 §6.4): the flake's nix SDK stamps sdk 14.4, which makes the binary
    // read as legacy. The stamp follows the linker sysroot, which in this Zig
    // is only settable from the CLI, so the canonical build command is
    //
    //   zig build run --sysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    //
    // (framework/lib paths below are sysroot-relative to match). Pass
    // -Dlegacy_sdk=true INSTEAD of --sysroot to build against the nix/xcrun
    // SDK — that answers the explicit checkpoint "does glass render at all
    // from an sdk-14.4 binary".
    const legacy_sdk = b.option(bool, "legacy_sdk", "build against the default (nix) SDK instead of a --sysroot SDK") orelse false;

    const exe = b.addExecutable(.{
        .name = "liquid-glass-hud",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const m = exe.root_module;
    m.linkFramework("AppKit", .{}); // NSPanel / NSGlassEffectView / NSColor via the ObjC runtime
    m.linkFramework("QuartzCore", .{}); // CALayer bars + CATransaction
    m.linkFramework("CoreFoundation", .{}); // run loop + render-pump timer
    m.linkFramework("AudioToolbox", .{}); // live mic tap (AudioQueue) for the whisper check
    m.linkSystemLibrary("objc", .{}); // -lobjc

    if (legacy_sdk) {
        const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
        m.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    } else {
        // -F paths are searched literally, -L paths get the --sysroot prefix.
        const clt_sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk";
        m.addFrameworkPath(.{ .cwd_relative = clt_sdk ++ "/System/Library/Frameworks" });
        m.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the Liquid Glass HUD spike");
    run_step.dependOn(&run_cmd.step);
}
