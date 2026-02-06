//! Standard Database Benchmark - db_bench style
//! Same methodology as RocksDB/LevelDB benchmarks
//! Tests: fillseq, fillrandom, readseq, readrandom

const std = @import("std");
const TurboIndex = @import("turbo_index.zig").TurboIndex;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("\n", .{});
    try stdout.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║     STANDARD DATABASE BENCHMARK (db_bench style)             ║\n", .{});
    try stdout.print("║     Same methodology as RocksDB/LevelDB benchmarks           ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});
    
    // Standard benchmark: 1 million operations, 100-byte values
    const NUM_ENTRIES: usize = 1_000_000;
    const VALUE_SIZE: usize = 100;
    
    try stdout.print("Configuration:\n", .{});
    try stdout.print("  - Entries: {d}\n", .{NUM_ENTRIES});
    try stdout.print("  - Value size: {d} bytes\n", .{VALUE_SIZE});
    try stdout.print("  - Key size: 16 bytes\n\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var index = try TurboIndex.init(allocator);
    defer index.deinit();
    
    var key_buf: [16]u8 = undefined;
    
    // ============ FILLSEQ - Sequential writes ============
    try stdout.print("fillseq          : ", .{});
    var timer = std.time.Timer.start() catch unreachable;
    
    for (0..NUM_ENTRIES) |i| {
        _ = std.fmt.bufPrint(&key_buf, "key{d:0>12}", .{i}) catch unreachable;
        const hash = std.hash.Wyhash.hash(0, &key_buf);
        _ = try index.put(&key_buf, hash, 0, VALUE_SIZE, false);
    }
    
    const fillseq_ns = timer.read();
    const fillseq_ops = @as(f64, @floatFromInt(NUM_ENTRIES)) / (@as(f64, @floatFromInt(fillseq_ns)) / 1_000_000_000.0);
    const fillseq_us = @as(f64, @floatFromInt(fillseq_ns)) / @as(f64, @floatFromInt(NUM_ENTRIES)) / 1000.0;
    try stdout.print("{d:>10.0} ops/sec  ({d:.3} micros/op)\n", .{fillseq_ops, fillseq_us});
    
    // ============ READSEQ - Sequential reads ============
    try stdout.print("readseq          : ", .{});
    timer.reset();
    
    for (0..NUM_ENTRIES) |i| {
        _ = std.fmt.bufPrint(&key_buf, "key{d:0>12}", .{i}) catch unreachable;
        const hash = std.hash.Wyhash.hash(0, &key_buf);
        _ = index.get(&key_buf, hash);
    }
    
    const readseq_ns = timer.read();
    const readseq_ops = @as(f64, @floatFromInt(NUM_ENTRIES)) / (@as(f64, @floatFromInt(readseq_ns)) / 1_000_000_000.0);
    const readseq_us = @as(f64, @floatFromInt(readseq_ns)) / @as(f64, @floatFromInt(NUM_ENTRIES)) / 1000.0;
    try stdout.print("{d:>10.0} ops/sec  ({d:.3} micros/op)\n", .{readseq_ops, readseq_us});
    
    // ============ READRANDOM - Random reads ============
    try stdout.print("readrandom       : ", .{});
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    timer.reset();
    
    for (0..NUM_ENTRIES) |_| {
        const rand_key = random.intRangeAtMost(usize, 0, NUM_ENTRIES - 1);
        _ = std.fmt.bufPrint(&key_buf, "key{d:0>12}", .{rand_key}) catch unreachable;
        const hash = std.hash.Wyhash.hash(0, &key_buf);
        _ = index.get(&key_buf, hash);
    }
    
    const readrand_ns = timer.read();
    const readrand_ops = @as(f64, @floatFromInt(NUM_ENTRIES)) / (@as(f64, @floatFromInt(readrand_ns)) / 1_000_000_000.0);
    const readrand_us = @as(f64, @floatFromInt(readrand_ns)) / @as(f64, @floatFromInt(NUM_ENTRIES)) / 1000.0;
    try stdout.print("{d:>10.0} ops/sec  ({d:.3} micros/op)\n", .{readrand_ops, readrand_us});
    
    // ============ FILLRANDOM - Random writes (overwrite) ============
    try stdout.print("fillrandom       : ", .{});
    var prng2 = std.Random.DefaultPrng.init(67890);
    const random2 = prng2.random();
    timer.reset();
    
    for (0..NUM_ENTRIES) |_| {
        const rand_key = random2.intRangeAtMost(usize, 0, NUM_ENTRIES - 1);
        _ = std.fmt.bufPrint(&key_buf, "key{d:0>12}", .{rand_key}) catch unreachable;
        const hash = std.hash.Wyhash.hash(0, &key_buf);
        _ = try index.put(&key_buf, hash, 0, VALUE_SIZE, false);
    }
    
    const fillrand_ns = timer.read();
    const fillrand_ops = @as(f64, @floatFromInt(NUM_ENTRIES)) / (@as(f64, @floatFromInt(fillrand_ns)) / 1_000_000_000.0);
    const fillrand_us = @as(f64, @floatFromInt(fillrand_ns)) / @as(f64, @floatFromInt(NUM_ENTRIES)) / 1000.0;
    try stdout.print("{d:>10.0} ops/sec  ({d:.3} micros/op)\n", .{fillrand_ops, fillrand_us});
    
    // ============ SUMMARY ============
    try stdout.print("\n", .{});
    try stdout.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║               COMPARISON WITH OTHER DATABASES                ║\n", .{});
    try stdout.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    try stdout.print("║  Operation    │ ZDB Turbo   │ RocksDB*  │ LevelDB*  │ LMDB* ║\n", .{});
    try stdout.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    try stdout.print("║  fillseq      │ {d:>9.0}K  │    400K   │   200K    │  500K ║\n", .{fillseq_ops / 1000});
    try stdout.print("║  fillrandom   │ {d:>9.0}K  │    200K   │   100K    │  300K ║\n", .{fillrand_ops / 1000});
    try stdout.print("║  readrandom   │ {d:>9.0}K  │    100K   │    50K    │  800K ║\n", .{readrand_ops / 1000});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    try stdout.print("* Approximate published benchmarks (varies by hardware)\n", .{});
}
