//! YCSB - Yahoo! Cloud Serving Benchmark
//! Industry standard database benchmark
//! Implements workloads A, B, C, D, E, F

const std = @import("std");
const TurboDatabase = @import("turbo_database.zig").TurboDatabase;
const TurboConfig = @import("turbo_database.zig").TurboConfig;

// ============================================================================
// YCSB Configuration
// ============================================================================

const RECORD_COUNT: usize = 100_000;  // Total records
const OPERATION_COUNT: usize = 100_000;  // Operations per workload
const FIELD_COUNT: usize = 10;  // Fields per record
const FIELD_LENGTH: usize = 100;  // Bytes per field
const VALUE_SIZE: usize = FIELD_COUNT * FIELD_LENGTH;  // 1KB per record

// Zipfian distribution constant (0.99 = highly skewed hot spots)
const ZIPFIAN_CONSTANT: f64 = 0.99;

// ============================================================================
// Workload Definitions
// ============================================================================

const Workload = struct {
    name: []const u8,
    description: []const u8,
    read_proportion: f32,
    update_proportion: f32,
    insert_proportion: f32,
    scan_proportion: f32,
    rmw_proportion: f32,  // read-modify-write
};

const WORKLOADS = [_]Workload{
    .{ .name = "A", .description = "Update heavy (50/50 read/update)", 
       .read_proportion = 0.5, .update_proportion = 0.5, .insert_proportion = 0, .scan_proportion = 0, .rmw_proportion = 0 },
    .{ .name = "B", .description = "Read mostly (95/5 read/update)",
       .read_proportion = 0.95, .update_proportion = 0.05, .insert_proportion = 0, .scan_proportion = 0, .rmw_proportion = 0 },
    .{ .name = "C", .description = "Read only (100% read)",
       .read_proportion = 1.0, .update_proportion = 0, .insert_proportion = 0, .scan_proportion = 0, .rmw_proportion = 0 },
    .{ .name = "D", .description = "Read latest (95/5 read/insert)",
       .read_proportion = 0.95, .update_proportion = 0, .insert_proportion = 0.05, .scan_proportion = 0, .rmw_proportion = 0 },
    .{ .name = "E", .description = "Short ranges (95/5 scan/insert)",
       .read_proportion = 0, .update_proportion = 0, .insert_proportion = 0.05, .scan_proportion = 0.95, .rmw_proportion = 0 },
    .{ .name = "F", .description = "Read-modify-write (50/50 read/rmw)",
       .read_proportion = 0.5, .update_proportion = 0, .insert_proportion = 0, .scan_proportion = 0, .rmw_proportion = 0.5 },
};

// ============================================================================
// Zipfian Distribution Generator
// ============================================================================

const ZipfianGenerator = struct {
    items: usize,
    base: usize,
    theta: f64,
    zeta_n: f64,
    zeta_2: f64,
    alpha: f64,
    eta: f64,
    
    fn init(items: usize) ZipfianGenerator {
        const theta = ZIPFIAN_CONSTANT;
        const zeta_2 = zetaStatic(2, theta);
        const zeta_n = zetaStatic(items, theta);
        
        const alpha = 1.0 / (1.0 - theta);
        const eta = (1.0 - std.math.pow(f64, 2.0 / @as(f64, @floatFromInt(items)), 1.0 - theta)) / 
                   (1.0 - zeta_2 / zeta_n);
        
        return .{
            .items = items,
            .base = 0,
            .theta = theta,
            .zeta_n = zeta_n,
            .zeta_2 = zeta_2,
            .alpha = alpha,
            .eta = eta,
        };
    }
    
    fn zetaStatic(n: usize, theta: f64) f64 {
        var sum: f64 = 0;
        for (1..n + 1) |i| {
            sum += 1.0 / std.math.pow(f64, @as(f64, @floatFromInt(i)), theta);
        }
        return sum;
    }
    
    fn next(self: *const ZipfianGenerator, random: std.Random) usize {
        const u = random.float(f64);
        const uz = u * self.zeta_n;
        
        if (uz < 1.0) return self.base;
        if (uz < 1.0 + std.math.pow(f64, 0.5, self.theta)) return self.base + 1;
        
        const ret = self.base + @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(self.items)) * 
            std.math.pow(f64, self.eta * u - self.eta + 1.0, self.alpha)
        ));
        
        return @min(ret, self.items - 1);
    }
};

// ============================================================================
// YCSB Benchmark Runner
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("\n", .{});
    try stdout.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║     YCSB - Yahoo! Cloud Serving Benchmark                    ║\n", .{});
    try stdout.print("║     Industry Standard Database Performance Test              ║\n", .{});
    try stdout.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    try stdout.print("║  Records: {d:<8}  Operations: {d:<8}  Value: {d} bytes    ║\n", 
        .{ RECORD_COUNT, OPERATION_COUNT, VALUE_SIZE });
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});
    
    // Generate test data
    try stdout.print("⏳ Loading {d} records...\n", .{RECORD_COUNT});
    
    std.fs.cwd().deleteFile("ycsb_test.db") catch {};
    defer std.fs.cwd().deleteFile("ycsb_test.db") catch {};
    
    const config = TurboConfig{
        .path = "ycsb_test.db",
        .compression = false,
        .sync_mode = .none,
        .batch_size = 512 * 1024,
    };
    
    const db = try TurboDatabase.init(allocator, config);
    defer db.deinit();
    
    // Pre-allocate value buffer
    var value_buf: [VALUE_SIZE]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    random.bytes(&value_buf);
    
    // Load phase - insert all records
    var key_buf: [32]u8 = undefined;
    const load_start = std.time.nanoTimestamp();
    
    for (0..RECORD_COUNT) |i| {
        const key = std.fmt.bufPrint(&key_buf, "user{d:0>16}", .{i}) catch unreachable;
        try db.put(key, &value_buf);
    }
    try db.flush();
    
    const load_end = std.time.nanoTimestamp();
    const load_time_ms = @as(f64, @floatFromInt(load_end - load_start)) / 1_000_000.0;
    const load_ops_sec = @as(f64, @floatFromInt(RECORD_COUNT)) / (load_time_ms / 1000.0);
    
    try stdout.print("✅ Loaded in {d:.1}ms ({d:.0} ops/sec)\n\n", .{ load_time_ms, load_ops_sec });
    
    // Initialize Zipfian generator
    const zipf = ZipfianGenerator.init(RECORD_COUNT);
    var read_buf: [VALUE_SIZE * 2]u8 = undefined;
    var insert_counter: usize = RECORD_COUNT;
    
    // Run each workload
    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("                        WORKLOAD RESULTS                        \n", .{});
    try stdout.print("═══════════════════════════════════════════════════════════════\n\n", .{});
    
    for (WORKLOADS) |workload| {
        const start = std.time.nanoTimestamp();
        var ops_completed: usize = 0;
        
        for (0..OPERATION_COUNT) |_| {
            const op_choice = random.float(f32);
            
            if (op_choice < workload.read_proportion) {
                // READ
                const key_idx = zipf.next(random);
                const key = std.fmt.bufPrint(&key_buf, "user{d:0>16}", .{key_idx}) catch unreachable;
                _ = db.getInto(key, &read_buf) catch continue;
                ops_completed += 1;
            } else if (op_choice < workload.read_proportion + workload.update_proportion) {
                // UPDATE
                const key_idx = zipf.next(random);
                const key = std.fmt.bufPrint(&key_buf, "user{d:0>16}", .{key_idx}) catch unreachable;
                random.bytes(&value_buf);
                db.put(key, &value_buf) catch continue;
                ops_completed += 1;
            } else if (op_choice < workload.read_proportion + workload.update_proportion + workload.insert_proportion) {
                // INSERT
                const key = std.fmt.bufPrint(&key_buf, "user{d:0>16}", .{insert_counter}) catch unreachable;
                insert_counter += 1;
                random.bytes(&value_buf);
                db.put(key, &value_buf) catch continue;
                ops_completed += 1;
            } else if (op_choice < workload.read_proportion + workload.update_proportion + workload.insert_proportion + workload.scan_proportion) {
                // SCAN (simulate with multiple reads)
                const start_key = zipf.next(random);
                const scan_length = random.intRangeAtMost(usize, 1, 100);
                for (0..scan_length) |j| {
                    const key_idx = start_key + j;
                    if (key_idx >= RECORD_COUNT + insert_counter - RECORD_COUNT) break;
                    const key = std.fmt.bufPrint(&key_buf, "user{d:0>16}", .{key_idx}) catch unreachable;
                    _ = db.getInto(key, &read_buf) catch continue;
                }
                ops_completed += 1;
            } else {
                // READ-MODIFY-WRITE
                const key_idx = zipf.next(random);
                const key = std.fmt.bufPrint(&key_buf, "user{d:0>16}", .{key_idx}) catch unreachable;
                const len = db.getInto(key, &read_buf) catch continue;
                // Modify the value
                if (len > 0) {
                    read_buf[0] = random.int(u8);
                }
                db.put(key, read_buf[0..len]) catch continue;
                ops_completed += 1;
            }
        }
        
        try db.flush();
        const end = std.time.nanoTimestamp();
        const time_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        const ops_sec = @as(f64, @floatFromInt(ops_completed)) / (time_ms / 1000.0);
        const latency_us = time_ms * 1000.0 / @as(f64, @floatFromInt(ops_completed));
        
        try stdout.print("Workload {s}: {s}\n", .{ workload.name, workload.description });
        try stdout.print("  Throughput: {d:>12.0} ops/sec\n", .{ops_sec});
        try stdout.print("  Avg Latency: {d:>10.2} μs/op\n", .{latency_us});
        try stdout.print("  Runtime: {d:>14.1} ms\n\n", .{time_ms});
    }
    
    // Summary
    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("                           SUMMARY                             \n", .{});
    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("  Database: ZDB TurboDatabase\n", .{});
    try stdout.print("  Records: {d}\n", .{RECORD_COUNT});
    try stdout.print("  Value Size: {d} bytes\n", .{VALUE_SIZE});
    try stdout.print("  Distribution: Zipfian (θ={d:.2})\n", .{ZIPFIAN_CONSTANT});
    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
}
