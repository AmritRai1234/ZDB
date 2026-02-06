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
    
    // Add include path for fast.h
    exe.addIncludePath(b.path("src"));
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
    
    // Link C libraries for tests
    lib_unit_tests.linkLibC();
    lib_unit_tests.linkSystemLibrary("xxhash");
    lib_unit_tests.linkSystemLibrary("lz4");
    lib_unit_tests.addIncludePath(b.path("src"));

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
    sqlite_bench.linkSystemLibrary("xxhash");
    sqlite_bench.linkSystemLibrary("lz4");
    sqlite_bench.addIncludePath(b.path("src"));
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
    simple_bench.linkSystemLibrary("xxhash");
    simple_bench.linkSystemLibrary("lz4");
    simple_bench.addIncludePath(b.path("src"));
    b.installArtifact(simple_bench);
    
    const simple_bench_cmd = b.addRunArtifact(simple_bench);
    const simple_bench_step = b.step("bench-simple", "Run simplified ZMDB vs SQLite benchmark");
    simple_bench_step.dependOn(&simple_bench_cmd.step);
    
    // Profiling benchmark
    const profile_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_profile.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    profile_bench_module.addImport("lib", zmdb_module);
    
    const profile_bench = b.addExecutable(.{
        .name = "zmdb-profile",
        .root_module = profile_bench_module,
    });
    profile_bench.linkLibC();
    profile_bench.linkSystemLibrary("xxhash");
    profile_bench.linkSystemLibrary("lz4");
    profile_bench.addIncludePath(b.path("src"));
    b.installArtifact(profile_bench);
    
    const profile_bench_cmd = b.addRunArtifact(profile_bench);
    const profile_bench_step = b.step("bench-profile", "Run profiling benchmark");
    profile_bench_step.dependOn(&profile_bench_cmd.step);
    
    // Zero-copy benchmark
    const zerocopy_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_zerocopy.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    zerocopy_bench_module.addImport("lib", zmdb_module);
    
    const zerocopy_bench = b.addExecutable(.{
        .name = "zmdb-zerocopy",
        .root_module = zerocopy_bench_module,
    });
    zerocopy_bench.linkLibC();
    zerocopy_bench.linkSystemLibrary("xxhash");
    zerocopy_bench.linkSystemLibrary("lz4");
    zerocopy_bench.addIncludePath(b.path("src"));
    b.installArtifact(zerocopy_bench);
    
    const zerocopy_bench_cmd = b.addRunArtifact(zerocopy_bench);
    const zerocopy_bench_step = b.step("bench-zerocopy", "Run zero-copy performance benchmark");
    zerocopy_bench_step.dependOn(&zerocopy_bench_cmd.step);
    
    // Benchmark: Hybrid architecture
    const hybrid_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_hybrid.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    hybrid_bench_module.addImport("lib", zmdb_module);
    
    const hybrid_bench = b.addExecutable(.{
        .name = "zmdb-hybrid",
        .root_module = hybrid_bench_module,
    });
    hybrid_bench.linkLibC();
    hybrid_bench.linkSystemLibrary("xxhash");
    hybrid_bench.linkSystemLibrary("lz4");
    hybrid_bench.addIncludePath(b.path("src"));
    b.installArtifact(hybrid_bench);
    
    const hybrid_bench_cmd = b.addRunArtifact(hybrid_bench);
    const hybrid_bench_step = b.step("bench-hybrid", "Run hybrid architecture benchmark");
    hybrid_bench_step.dependOn(&hybrid_bench_cmd.step);
    
    // Benchmark: Turbo 10x Performance
    const turbo_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_turbo.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    
    const turbo_bench = b.addExecutable(.{
        .name = "zmdb-turbo-bench",
        .root_module = turbo_bench_module,
    });
    turbo_bench.linkLibC();
    turbo_bench.linkSystemLibrary("lz4");
    turbo_bench.addIncludePath(b.path("src"));
    b.installArtifact(turbo_bench);
    
    const turbo_bench_cmd = b.addRunArtifact(turbo_bench);
    const turbo_bench_step = b.step("bench-turbo", "Run 10x TurboDatabase performance benchmark");
    turbo_bench_step.dependOn(&turbo_bench_cmd.step);
    
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
    
    // Link C libraries
    debug_exe.linkLibC();
    debug_exe.linkSystemLibrary("xxhash");
    debug_exe.linkSystemLibrary("lz4");
    debug_exe.addIncludePath(b.path("src"));
    b.installArtifact(debug_exe);
    
    const debug_cmd = b.addRunArtifact(debug_exe);
    const debug_step = b.step("debug-db", "Run database debug tool");
    debug_step.dependOn(&debug_cmd.step);
    
    // Persistence test
    const persist_module = b.createModule(.{
        .root_source_file = b.path("src/test_persistence.zig"),
        .target = target,
        .optimize = .Debug,
    });
    persist_module.addImport("lib", zmdb_module);
    
    const persist_exe = b.addExecutable(.{
        .name = "test-persistence",
        .root_module = persist_module,
    });
    persist_exe.linkLibC();
    persist_exe.linkSystemLibrary("xxhash");
    persist_exe.linkSystemLibrary("lz4");
    persist_exe.addIncludePath(b.path("src"));
    b.installArtifact(persist_exe);
    
    const persist_cmd = b.addRunArtifact(persist_exe);
    const persist_step = b.step("test-persist", "Test data persistence");
    persist_step.dependOn(&persist_cmd.step);
    
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
    
    // Turbo WebAssembly build (10x performance)
    const turbo_wasm_module = b.createModule(.{
        .root_source_file = b.path("src/turbo_wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });
    
    const turbo_wasm_lib = b.addExecutable(.{
        .name = "turbo_wasm",
        .root_module = turbo_wasm_module,
    });
    
    turbo_wasm_lib.entry = .disabled;
    turbo_wasm_lib.rdynamic = true;
    
    const turbo_wasm_install = b.addInstallArtifact(turbo_wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    
    const turbo_wasm_step = b.step("build-turbo-wasm", "Build TurboDatabase WebAssembly module");
    turbo_wasm_step.dependOn(&turbo_wasm_install.step);
    
    // Standard benchmark (db_bench style)
    const std_bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench_standard.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    std_bench_module.addImport("turbo_index", b.createModule(.{
        .root_source_file = b.path("src/turbo_index.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    
    const std_bench_exe = b.addExecutable(.{
        .name = "db_bench",
        .root_module = std_bench_module,
    });
    b.installArtifact(std_bench_exe);
    
    const std_bench_run = b.addRunArtifact(std_bench_exe);
    const std_bench_step = b.step("db-bench", "Run standard db_bench style benchmark");
    std_bench_step.dependOn(&std_bench_run.step);
    
    // YCSB Benchmark (industry standard)
    const ycsb_module = b.createModule(.{
        .root_source_file = b.path("src/ycsb_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    ycsb_module.addImport("turbo_database", b.createModule(.{
        .root_source_file = b.path("src/turbo_database.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    
    const ycsb_exe = b.addExecutable(.{
        .name = "ycsb",
        .root_module = ycsb_module,
    });
    ycsb_exe.linkLibC();
    ycsb_exe.linkSystemLibrary("lz4");
    b.installArtifact(ycsb_exe);
    
    const ycsb_run = b.addRunArtifact(ycsb_exe);
    const ycsb_step = b.step("ycsb", "Run YCSB (Yahoo Cloud Serving Benchmark)");
    ycsb_step.dependOn(&ycsb_run.step);
}
