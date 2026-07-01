const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const md2ansi_mod = b.createModule(.{
        .root_source_file = b.path("src/md2ansi/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "z-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "md2ansi", .module = md2ansi_mod },
            },
        }),
    });
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/Logo.rc") });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the agent");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "md2ansi", .module = md2ansi_mod },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests (testing.io, no subprocess)");
    // On Windows, --listen=- + stderr leak logs overflow pipe buffer, causing deadlock.
    // Workaround: install test binary and run via cmd with stderr redirected to nul.
    const test_install = b.addInstallArtifact(test_exe, .{ .dest_dir = .{ .override = .{ .custom = "test-bin" } } });
    const test_installed_path = b.fmt("{s} 2>nul", .{b.getInstallPath(.prefix, "test-bin/test.exe")});
    const test_cmd = b.addSystemCommand(&.{ "cmd", "/c", test_installed_path });
    test_cmd.step.dependOn(&test_install.step);
    test_step.dependOn(&test_cmd.step);

    const test_real_exe = b.addExecutable(.{
        .name = "test-real",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_real.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_real_run = b.addRunArtifact(test_real_exe);
    const test_real_step = b.step("test-real", "Run real IO tests (subprocess via init.io)");
    test_real_step.dependOn(&test_real_run.step);

    const check_step = b.step("check", "Run consistency checks (CLI flags, tool descriptions, docs)");
    const script_path = b.fmt("{s}/scripts/check-consistency.ps1", .{b.build_root.path.?});
    const check_script = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File", script_path });
    check_step.dependOn(&check_script.step);
}
