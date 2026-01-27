const std = @import("std");
const zmdb = @import("lib.zig");

const NUM_OPERATIONS = 10_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("ZMDB Benchmark Suite\n", .{});
    std.debug.print("====================\n\n", .{});
    
    // Clean up old benchmark database
    std.fs.cwd().deleteFile("bench.db") catch {};
    std.fs.cwd().deleteFile("bench.db.wal") catch {};
    
    var db = try zmdb.Database.init(allocator, "bench.db", .{
        .cache_size = 8 * 1024 * 1024,
        .compression = false,
        .sync_mode = .none, // Fastest for benchmarking
    });
    defer db.deinit();
    
    // Benchmark sequential writes
    try benchmarkSequentialWrites(&db);
    
    // Benchmark random reads
    try benchmarkRandomReads(&db, allocator);
    
    // Benchmark mixed workload
    try benchmarkMixedWorkload(&db, allocator);
    
    std.debug.print("\nBenchmark completed!\n", .{});
}

fn benchmarkSequentialWrites(db: *zmdb.Database) !void {
    std.debug.print("Benchmarking sequential writes ({d} ops)...\n", .{NUM_OPERATIONS});
    
    var timer = try std.time.Timer.start();
    
    var i: usize = 0;
    while (i < NUM_OPERATIONS) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key:{d:0>10}", .{i});
        
        var value_buf: [64]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "value_{d}_data", .{i});
        
        try db.put(key, value);
    }
    
    const elapsed = timer.read();
    const ops_per_sec = @as(f64, NUM_OPERATIONS) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const avg_latency_us = @as(f64, @floatFromInt(elapsed)) / @as(f64, NUM_OPERATIONS) / 1000.0;
    
    std.debug.print("  Time: {d:.2}s\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0});
    std.debug.print("  Throughput: {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  Avg latency: {d:.2} µs\n\n", .{avg_latency_us});
}

fn benchmarkRandomReads(db: *zmdb.Database, allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmarking random reads ({d} ops)...\n", .{NUM_OPERATIONS});
    
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var timer = try std.time.Timer.start();
    
    var i: usize = 0;
    while (i < NUM_OPERATIONS) : (i += 1) {
        const rand_id = random.intRangeAtMost(usize, 0, NUM_OPERATIONS - 1);
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key:{d:0>10}", .{rand_id});
        
        const value = db.get(key, allocator) catch continue;
        allocator.free(value);
    }
    
    const elapsed = timer.read();
    const ops_per_sec = @as(f64, NUM_OPERATIONS) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const avg_latency_us = @as(f64, @floatFromInt(elapsed)) / @as(f64, NUM_OPERATIONS) / 1000.0;
    
    std.debug.print("  Time: {d:.2}s\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0});
    std.debug.print("  Throughput: {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  Avg latency: {d:.2} µs\n\n", .{avg_latency_us});
}

fn benchmarkMixedWorkload(db: *zmdb.Database, allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmarking mixed workload (70% reads, 30% writes)...\n", .{});
    
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();
    
    var timer = try std.time.Timer.start();
    
    var i: usize = 0;
    while (i < NUM_OPERATIONS) : (i += 1) {
        const is_write = random.intRangeAtMost(u8, 0, 99) < 30;
        const rand_id = random.intRangeAtMost(usize, 0, NUM_OPERATIONS - 1);
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key:{d:0>10}", .{rand_id});
        
        if (is_write) {
            var value_buf: [64]u8 = undefined;
            const value = try std.fmt.bufPrint(&value_buf, "updated_{d}", .{i});
            try db.put(key, value);
        } else {
            const value = db.get(key, allocator) catch continue;
            allocator.free(value);
        }
    }
    
    const elapsed = timer.read();
    const ops_per_sec = @as(f64, NUM_OPERATIONS) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const avg_latency_us = @as(f64, @floatFromInt(elapsed)) / @as(f64, NUM_OPERATIONS) / 1000.0;
    
    std.debug.print("  Time: {d:.2}s\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0});
    std.debug.print("  Throughput: {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  Avg latency: {d:.2} µs\n\n", .{avg_latency_us});
}
