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
            mod.linkFramework("AVFoundation", .{}); // non-prompting Microphone authorization status
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

    // The private local-inference helper is part of every normal build. Its build action
    // acquires and byte-verifies the exact whisper.cpp v1.9.1 source archive; an explicit
    // archive remains available for offline/reproducible builders.
    const helper_step = b.step("whisper-helper", "Build the pinned private KB Whisper helper");
    const whisper_archive = b.option([]const u8, "whisper-archive", "Use the local pinned whisper.cpp source archive instead of acquiring it");
    const runtime_build = b.addSystemCommand(&.{"bash"});
    runtime_build.addFileArg(b.path("tools/build-whisper-runtime.sh"));
    if (whisper_archive) |archive_path| {
        runtime_build.addFileArg(.{ .cwd_relative = archive_path });
    } else {
        runtime_build.addArg("--download-pinned");
    }
    runtime_build.addFileArg(b.path("packaging/share/type-wave/PROVENANCE"));
    const runtime_output = runtime_build.addOutputDirectoryArg("whisper-cpp-runtime");

    const helper = b.addExecutable(.{
        .name = "type-wave-whisper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/whisper_helper.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    helper.root_module.addIncludePath(b.path("src"));
    helper.root_module.addIncludePath(runtime_output.path(b, "source/include"));
    helper.root_module.addIncludePath(runtime_output.path(b, "source/ggml/include"));
    helper.root_module.addCSourceFile(.{
        .file = b.path("src/whisper_bridge.cpp"),
        .flags = &.{ "-std=c++17", "-fno-exceptions" },
    });
    inline for (.{
        "build/src/libwhisper.a",
        "build/ggml/src/libggml.a",
        "build/ggml/src/libggml-base.a",
        "build/ggml/src/libggml-cpu.a",
        "build/ggml/src/ggml-blas/libggml-blas.a",
        "build/ggml/src/ggml-metal/libggml-metal.a",
    }) |library| helper.root_module.addObjectFile(runtime_output.path(b, library));
    helper.root_module.linkFramework("Accelerate", .{});
    helper.root_module.linkFramework("Foundation", .{});
    helper.root_module.linkFramework("Metal", .{});
    helper.root_module.linkFramework("MetalKit", .{});
    helper.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    helper.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    helper.step.dependOn(&runtime_build.step);
    b.installArtifact(helper);
    helper_step.dependOn(&helper.step);

    b.installDirectory(.{
        .source_dir = b.path("packaging/share/type-wave"),
        .install_dir = .prefix,
        .install_subdir = "share/type-wave",
    });

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

    // The local-backend release gate is a stdlib-only Python program so it can score
    // checked-in evidence without building or loading the native inference runtime.
    // Python is pinned in flake.nix alongside Zig.
    const acceptance_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "acceptance/local_backend", "-p", "test_*.py", "-v" });
    const acceptance_types = b.addSystemCommand(&.{ "mypy", "--strict", "acceptance/local_backend/gate.py" });
    const acceptance_test_step = b.step("acceptance-test", "Run the deterministic local-backend release-gate tests");
    acceptance_test_step.dependOn(&acceptance_tests.step);
    acceptance_test_step.dependOn(&acceptance_types.step);
    test_step.dependOn(&acceptance_tests.step);
    test_step.dependOn(&acceptance_types.step);

    const packaging_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "packaging.test_packaging", "-v" });
    test_step.dependOn(&packaging_tests.step);
    b.getInstallStep().dependOn(test_step);

    // `zig build install-agent` — package the daemon/helper pair as a signed headless
    // LaunchAgent. Both freshly-built binaries use the stable "type-wave dev" identity and
    // publish through one atomic pair pointer before the LaunchAgent plist is rendered.
    // The macOS-specific work (codesign/launchctl/absolute paths) lives in the script.
    // One-time cert setup and grant-persistence verification: docs/packaging.md.
    const install_agent = b.addSystemCommand(&.{"bash"});
    install_agent.addFileArg(b.path("packaging/install.sh"));
    install_agent.addFileArg(exe.getEmittedBin());
    install_agent.addFileArg(helper.getEmittedBin());
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
    check.root_module.linkFramework("AVFoundation", .{});
    check.root_module.linkSystemLibrary("objc", .{});
    check.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    check.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    const run_check = b.addRunArtifact(check);
    const check_step = b.step("capture-check", "Run the Capture start/stop-cycle regression probe (live input IO)");
    check_step.dependOn(&run_check.step);
}
