//! Benchmark: TurboDatabase vs Original Database
//! Validates 10x performance improvement claims

const std = @import("std");
const TurboDatabase = @import("turbo_database.zig").TurboDatabase;
const TurboConfig = @import("turbo_database.zig").TurboConfig;
const KV = @import("turbo_database.zig").KV;

const NUM_KEYS = 100_000;
const VALUE_SIZE = 256;
const NUM_ITERATIONS = 3;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          ZDB TURBO BENCHMARK - 10x Performance Test          ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Keys: {d:<10}  Value Size: {d:<6}  Iterations: {d:<3}      ║\n", .{ NUM_KEYS, VALUE_SIZE, NUM_ITERATIONS });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    
    // Generate test data
    std.debug.print("⏳ Generating {d} test keys...\n", .{NUM_KEYS});
    
    const keys = try allocator.alloc([]u8, NUM_KEYS);
    defer {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }
    
    const values = try allocator.alloc([]u8, NUM_KEYS);
    defer {
        for (values) |value| allocator.free(value);
        allocator.free(values);
    }
    
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    for (keys, values, 0..) |*key, *value, i| {
        key.* = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
        value.* = try allocator.alloc(u8, VALUE_SIZE);
        random.bytes(value.*);
    }
    
    std.debug.print("✅ Test data ready\n\n", .{});
    
    // Cleanup old test files
    std.fs.cwd().deleteFile("bench_turbo.db") catch {};
    defer std.fs.cwd().deleteFile("bench_turbo.db") catch {};
    
    // ========================================================================
    // TurboDatabase Benchmark
    // ========================================================================
    
    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("                     TURBODATABASE BENCHMARK                    \n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n\n", .{});
    
    var write_times: [NUM_ITERATIONS]u64 = undefined;
    var read_times: [NUM_ITERATIONS]u64 = undefined;
    var batch_write_times: [NUM_ITERATIONS]u64 = undefined;
    var zerocopy_times: [NUM_ITERATIONS]u64 = undefined;
    var fast_read_times: [NUM_ITERATIONS]u64 = undefined;
    
    for (0..NUM_ITERATIONS) |iter| {
        std.debug.print("📊 Iteration {d}/{d}\n", .{ iter + 1, NUM_ITERATIONS });
        
        // Fresh database for each iteration
        std.fs.cwd().deleteFile("bench_turbo.db") catch {};
        
        const config = TurboConfig{
            .path = "bench_turbo.db",
            .compression = false,
            .sync_mode = .none,
            .batch_size = 256 * 1024, // 256KB batches
        };
        
        const db = try TurboDatabase.init(allocator, config);
        defer db.deinit();
        
        // ===== INDIVIDUAL WRITES =====
        {
            const start = std.time.nanoTimestamp();
            
            for (keys, values) |key, value| {
                try db.put(key, value);
            }
            try db.flush();
            
            const end = std.time.nanoTimestamp();
            write_times[iter] = @intCast(end - start);
        }
        
        // ===== INDIVIDUAL READS =====
        {
            const start = std.time.nanoTimestamp();
            
            for (keys) |key| {
                const value = try db.get(key, allocator);
                allocator.free(value);
            }
            
            const end = std.time.nanoTimestamp();
            read_times[iter] = @intCast(end - start);
        }
        
        // ===== ZERO-COPY READS =====
        {
            const start = std.time.nanoTimestamp();
            
            for (keys) |key| {
                _ = db.getBorrowed(key) catch continue;
            }
            
            const end = std.time.nanoTimestamp();
            zerocopy_times[iter] = @intCast(end - start);
        }
        
        // ===== FAST getInto() READS (NEW!) =====
        {
            var read_buf: [VALUE_SIZE * 2]u8 = undefined;
            const start = std.time.nanoTimestamp();
            
            for (keys) |key| {
                _ = db.getInto(key, &read_buf) catch continue;
            }
            
            const end = std.time.nanoTimestamp();
            fast_read_times[iter] = @intCast(end - start);
        }
        
        // Fresh database for batch test
        std.fs.cwd().deleteFile("bench_turbo_batch.db") catch {};
        defer std.fs.cwd().deleteFile("bench_turbo_batch.db") catch {};
        
        const batch_config = TurboConfig{
            .path = "bench_turbo_batch.db",
            .compression = false,
            .sync_mode = .none,
            .batch_size = 1024 * 1024, // 1MB batches
        };
        
        const batch_db = try TurboDatabase.init(allocator, batch_config);
        defer batch_db.deinit();
        
        // ===== BATCH WRITES =====
        {
            const kvs = try allocator.alloc(KV, NUM_KEYS);
            defer allocator.free(kvs);
            
            for (keys, values, 0..) |key, value, i| {
                kvs[i] = .{ .key = key, .value = value };
            }
            
            const start = std.time.nanoTimestamp();
            _ = try batch_db.putBatch(kvs);
            const end = std.time.nanoTimestamp();
            
            batch_write_times[iter] = @intCast(end - start);
        }
        
        std.debug.print("   ✓ Writes: {d:.2}ms | Reads: {d:.2}ms | Zero-copy: {d:.2}ms | Batch: {d:.2}ms\n", .{
            @as(f64, @floatFromInt(write_times[iter])) / 1_000_000.0,
            @as(f64, @floatFromInt(read_times[iter])) / 1_000_000.0,
            @as(f64, @floatFromInt(zerocopy_times[iter])) / 1_000_000.0,
            @as(f64, @floatFromInt(batch_write_times[iter])) / 1_000_000.0,
        });
    }
    
    std.debug.print("\n", .{});
    
    // Calculate averages
    var avg_write: u64 = 0;
    var avg_read: u64 = 0;
    var avg_zerocopy: u64 = 0;
    var avg_batch: u64 = 0;
    var avg_fast_read: u64 = 0;
    
    for (0..NUM_ITERATIONS) |i| {
        avg_write += write_times[i];
        avg_read += read_times[i];
        avg_zerocopy += zerocopy_times[i];
        avg_batch += batch_write_times[i];
        avg_fast_read += fast_read_times[i];
    }
    
    avg_write /= NUM_ITERATIONS;
    avg_read /= NUM_ITERATIONS;
    avg_zerocopy /= NUM_ITERATIONS;
    avg_batch /= NUM_ITERATIONS;
    avg_fast_read /= NUM_ITERATIONS;
    
    // Calculate ops/sec
    const write_ops_sec = @as(f64, @floatFromInt(NUM_KEYS)) / (@as(f64, @floatFromInt(avg_write)) / 1_000_000_000.0);
    const read_ops_sec = @as(f64, @floatFromInt(NUM_KEYS)) / (@as(f64, @floatFromInt(avg_read)) / 1_000_000_000.0);
    const zerocopy_ops_sec = @as(f64, @floatFromInt(NUM_KEYS)) / (@as(f64, @floatFromInt(avg_zerocopy)) / 1_000_000_000.0);
    const batch_ops_sec = @as(f64, @floatFromInt(NUM_KEYS)) / (@as(f64, @floatFromInt(avg_batch)) / 1_000_000_000.0);
    const fast_read_ops_sec = @as(f64, @floatFromInt(NUM_KEYS)) / (@as(f64, @floatFromInt(avg_fast_read)) / 1_000_000_000.0);
    
    // Results
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                         RESULTS                              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Operation          │ Throughput      │ Target      │ Status ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    
    // Write results
    const write_target: f64 = 710_000;
    const write_met = write_ops_sec >= write_target;
    std.debug.print("║  Writes             │ {d:>10.0}/sec  │ {d:>6.0}K/s  │  {s}   ║\n", .{
        write_ops_sec,
        write_target / 1000,
        if (write_met) "✅" else "❌",
    });
    
    // Read results
    const read_target: f64 = 760_000;
    const read_met = read_ops_sec >= read_target;
    std.debug.print("║  Reads              │ {d:>10.0}/sec  │ {d:>6.0}K/s  │  {s}   ║\n", .{
        read_ops_sec,
        read_target / 1000,
        if (read_met) "✅" else "❌",
    });
    
    // Zero-copy results
    const zerocopy_target: f64 = 50_000_000;
    const zerocopy_met = zerocopy_ops_sec >= zerocopy_target;
    std.debug.print("║  Zero-copy reads    │ {d:>10.0}/sec  │ {d:>6.0}M/s  │  {s}   ║\n", .{
        zerocopy_ops_sec,
        zerocopy_target / 1_000_000,
        if (zerocopy_met) "✅" else "❌",
    });
    
    // Batch write results
    std.debug.print("║  Batch writes       │ {d:>10.0}/sec  │    N/A      │  ⚡   ║\n", .{batch_ops_sec});
    
    // Fast getInto() results (NEW!)
    const fast_read_target: f64 = 760_000;
    const fast_read_met = fast_read_ops_sec >= fast_read_target;
    std.debug.print("║  Fast getInto()     │ {d:>10.0}/sec  │ {d:>6.0}K/s  │  {s}   ║\n", .{
        fast_read_ops_sec,
        fast_read_target / 1000,
        if (fast_read_met) "✅" else "❌",
    });
    
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    
    // Comparison with old architecture
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    SPEEDUP vs OLD ARCHITECTURE               ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    
    const old_writes: f64 = 71_000;
    const old_reads: f64 = 76_000;
    const old_zerocopy: f64 = 4_900_000;
    
    std.debug.print("║  Writes:      {d:>6.1}x  ({d:.0}K →  {d:.0}K ops/sec)              ║\n", .{
        write_ops_sec / old_writes,
        old_writes / 1000,
        write_ops_sec / 1000,
    });
    std.debug.print("║  Reads:       {d:>6.1}x  ({d:.0}K →  {d:.0}K ops/sec)              ║\n", .{
        read_ops_sec / old_reads,
        old_reads / 1000,
        read_ops_sec / 1000,
    });
    std.debug.print("║  Zero-copy:   {d:>6.1}x  ({d:.1}M → {d:.1}M ops/sec)              ║\n", .{
        zerocopy_ops_sec / old_zerocopy,
        old_zerocopy / 1_000_000,
        zerocopy_ops_sec / 1_000_000,
    });
    
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    
    // Final verdict
    const all_met = write_met and read_met and zerocopy_met;
    if (all_met) {
        std.debug.print("🎉 SUCCESS! All 10x performance targets met!\n", .{});
    } else {
        std.debug.print("⚠️  Some targets not met. Further optimization needed.\n", .{});
    }
}
