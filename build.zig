const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // This project installs a long-running local agent; default plain builds to
    // the production mode we install, while still allowing `-Doptimize=Debug`.
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.graph.release_mode) {
        .off, .any, .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

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

    // Frameworks + libobjc.tbd live under the active SDK; point the linker at both.
    const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");

    // Every module that reaches the OS-facing files needs the same framework/SDK wiring.
    // Factored so the exe and the `zig build test` artifact stay in lockstep.
    const linkFrameworks = struct {
        fn apply(mod: *std.Build.Module, sdk_path: []const u8, bb: *std.Build) void {
            // Transcription Session's vendored websocket rides std.crypto.tls (no extra
            // framework); Capture's AudioQueue lives in AudioToolbox.
            mod.linkFramework("AudioToolbox", .{});
            // Talk Key tap + Insertion event synthesis.
            mod.linkFramework("CoreGraphics", .{}); // CGEventTap, CGEvent*, CG*EventAccess
            mod.linkFramework("CoreFoundation", .{}); // run loop, CFRelease
            mod.linkFramework("Carbon", .{}); // IsSecureEventInputEnabled
            mod.linkFramework("ApplicationServices", .{}); // umbrella (AX if ever needed)
            mod.linkFramework("AppKit", .{}); // NSPasteboard (insert) + NSPanel/NSTextField/NSScreen (overlay HUD, #22)
            mod.linkFramework("QuartzCore", .{}); // CALayer — the overlay HUD's rounded pill (wayfinder #22)
            mod.linkFramework("Security", .{}); // SecItem* — API key in the login keychain (wayfinder #33)
            mod.linkSystemLibrary("objc", .{}); // -lobjc
            mod.addFrameworkPath(.{ .cwd_relative = bb.fmt("{s}/System/Library/Frameworks", .{sdk_path}) });
            mod.addLibraryPath(.{ .cwd_relative = bb.fmt("{s}/usr/lib", .{sdk_path}) });
        }
    }.apply;

    const m = exe.root_module;
    m.addImport("websocket", ws.module("websocket"));

    // packaging/Info.plist is embedded into the binary's __TEXT,__info_plist section
    // (src/info_plist.zig) — the effective Info.plist for a bare CLI tool. Registered
    // as an anonymous import so @embedFile can read its bytes from outside src/.
    m.addAnonymousImport("Info.plist", .{ .root_source_file = b.path("packaging/Info.plist") });

    linkFrameworks(m, sdk, b);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run type-wave (foreground skeleton)");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — the Utterance Coordinator's lifecycle matrix plus the backfilled
    // pure-function tests (parseEnvKey, formatSessionUpdate, backoffMs, levelToNorm),
    // aggregated through src/tests.zig. Same imports/frameworks as the exe, since the tested
    // files reference the websocket module and the macOS frameworks.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addImport("websocket", ws.module("websocket"));
    linkFrameworks(tests.root_module, sdk, b);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the unit tests (Coordinator lifecycle + pure functions)");
    test_step.dependOn(&run_tests.step);

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

    // `zig build capture-check` — the live start/stop-cycle regression probe for the
    // works-once Capture bug (src/capture_check.zig). Local-machine only: it performs
    // real input IO, so it is a step rather than a `zig build test` test.
    const check = b.addExecutable(.{
        .name = "capture-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capture_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    check.root_module.linkFramework("AudioToolbox", .{});
    check.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    check.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    const run_check = b.addRunArtifact(check);
    const check_step = b.step("capture-check", "Run the Capture start/stop-cycle regression probe (live input IO)");
    check_step.dependOn(&run_check.step);
}
