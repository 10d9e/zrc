const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const e2e_quick = b.option(bool, "e2e-quick", "e2e: only 10 MiB and 100 MiB") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "rs",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // zig build run -- encode file.txt
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |run_args| run_cmd.addArgs(run_args);
    const run_step = b.step("run", "Run rs");
    run_step.dependOn(&run_cmd.step);

    // zig build test
    const test_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // zig build e2e — CLI encode/decode timing (needs python3)
    const run_e2e = b.addSystemCommand(&.{"python3"});
    run_e2e.addFileArg(b.path("scripts/e2e_cli_test.py"));
    if (e2e_quick) run_e2e.addArg("--quick");
    run_e2e.addFileArg(exe.getEmittedBin());
    run_e2e.step.dependOn(&exe.step);
    const e2e_step = b.step("e2e", "CLI encode/decode e2e timing (10 MiB–1 GiB)");
    e2e_step.dependOn(&run_e2e.step);
}
