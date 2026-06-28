const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "z-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
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
        }),
    });
    const test_step = b.step("test", "Run unit tests (testing.io, no subprocess)");
    test_step.dependOn(&b.addRunArtifact(test_exe).step);

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
}
