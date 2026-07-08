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

    // packaging/Info.plist is embedded into the binary's __TEXT,__info_plist section
    // (src/info_plist.zig) — the effective Info.plist for a bare CLI tool. Registered
    // as an anonymous import so @embedFile can read its bytes from outside src/.
    m.addAnonymousImport("Info.plist", .{ .root_source_file = b.path("packaging/Info.plist") });

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

    // `zig build install-agent` — package the daemon as a signed headless LaunchAgent
    // (wayfinder #15): codesign the freshly-built binary with the stable "type-wave dev"
    // identity, install it to ~/.local/bin/type-wave, and render+install the LaunchAgent
    // plist. The macOS-specific work (codesign/launchctl/absolute paths) lives in the
    // script so build.zig stays host-agnostic; the built binary is passed as its argument.
    // One-time cert setup and grant-persistence verification: docs/packaging.md.
    const install_agent = b.addSystemCommand(&.{"bash"});
    install_agent.addFileArg(b.path("packaging/install.sh"));
    install_agent.addFileArg(exe.getEmittedBin());
    const agent_step = b.step("install-agent", "Codesign + install the daemon as a headless LaunchAgent (macOS; see docs/packaging.md)");
    agent_step.dependOn(&install_agent.step);
}
