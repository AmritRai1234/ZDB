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
    
    // Link high-performance C libraries
    exe.linkLibC();
    exe.linkSystemLibrary("xxhash");
    exe.linkSystemLibrary("lz4");
    exe.linkSystemLibrary("jemalloc");
    
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const lib_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_test_module,
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
    
    // Simple benchmark (no persistence issues)
    const simple_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_simple.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    simple_bench_module.addImport("lib", zmdb_module);
    
    const simple_bench = b.addExecutable(.{
        .name = "zmdb-simple-bench",
        .root_module = simple_bench_module,
    });
    simple_bench.linkLibC();
    simple_bench.linkSystemLibrary("sqlite3");
    b.installArtifact(simple_bench);
    
    const simple_bench_cmd = b.addRunArtifact(simple_bench);
    const simple_bench_step = b.step("bench-simple", "Run simplified ZMDB vs SQLite benchmark");
    simple_bench_step.dependOn(&simple_bench_cmd.step);
    
    // Debug tool
    const debug_module = b.createModule(.{
        .root_source_file = b.path("src/debug_db.zig"),
        .target = target,
        .optimize = .Debug,
    });
    debug_module.addImport("lib", zmdb_module);
    
    const debug_exe = b.addExecutable(.{
        .name = "zmdb-debug",
        .root_module = debug_module,
    });
    b.installArtifact(debug_exe);
    
    const debug_cmd = b.addRunArtifact(debug_exe);
    const debug_step = b.step("debug-db", "Run database debug tool");
    debug_step.dependOn(&debug_cmd.step);
    
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
    
    // WebAssembly build
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });
    
    const wasm_lib = b.addExecutable(.{
        .name = "zmdb",
        .root_module = wasm_module,
    });
    
    // Configure WASM output
    wasm_lib.entry = .disabled; // No main function for library
    wasm_lib.rdynamic = true; // Export all symbols
    
    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    
    const wasm_step = b.step("build-wasm", "Build WebAssembly module");
    wasm_step.dependOn(&wasm_install.step);
}
