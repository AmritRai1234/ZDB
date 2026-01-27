const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create module for the library
    const zmdb_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("lib", zmdb_module);
    
    const exe = b.addExecutable(.{
        .name = "zmdb",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // SQLite benchmark
    const sqlite_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_sqlite.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    sqlite_bench_module.addImport("lib", zmdb_module);
    
    const sqlite_bench = b.addExecutable(.{
        .name = "zmdb-vs-sqlite",
        .root_module = sqlite_bench_module,
    });
    sqlite_bench.linkLibC();
    sqlite_bench.linkSystemLibrary("sqlite3");
    b.installArtifact(sqlite_bench);
    
    const sqlite_bench_cmd = b.addRunArtifact(sqlite_bench);
    const sqlite_bench_step = b.step("bench-sqlite", "Run ZMDB vs SQLite benchmark");
    sqlite_bench_step.dependOn(&sqlite_bench_cmd.step);
    
    // LSM benchmark
    const lsm_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_lsm.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    lsm_bench_module.addImport("lsm", zmdb_module);
    
    const lsm_bench = b.addExecutable(.{
        .name = "zmdb-lsm-bench",
        .root_module = lsm_bench_module,
    });
    b.installArtifact(lsm_bench);
    
    const lsm_bench_cmd = b.addRunArtifact(lsm_bench);
    const lsm_bench_step = b.step("bench-lsm", "Run LSM-Tree benchmark");
    lsm_bench_step.dependOn(&lsm_bench_cmd.step);
}
