const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Same SDK split as prototypes/liquid-glass-hud: AppKit gates new-design
    // behavior on the binary's LC_BUILD_VERSION sdk stamp (#40 §6.4), and the
    // nix SDK stamps 14.4. Status-item template images are probably not gated
    // (the deployed daemon renders SF Symbols from a 14.4 stamp today), but the
    // whole point of this spike is judging how the icon sits in the *Tahoe*
    // menu bar — so the canonical build takes the 26.5 SDK:
    //
    //   zig build run --sysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    //
    // Pass -Dlegacy_sdk=true INSTEAD of --sysroot to build against the nix
    // SDK (also the side-by-side check that the stamp doesn't matter here).
    const legacy_sdk = b.option(bool, "legacy_sdk", "build against the default (nix) SDK instead of a --sysroot SDK") orelse false;

    const exe = b.addExecutable(.{
        .name = "status-item-icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const m = exe.root_module;
    m.linkFramework("AppKit", .{}); // NSStatusBar / NSStatusItem / NSImage / NSImageSymbolConfiguration
    m.linkFramework("CoreFoundation", .{}); // run loop + the command-applier timer
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
    const run_step = b.step("run", "Build and run the Status Item icon spike");
    run_step.dependOn(&run_cmd.step);
}
