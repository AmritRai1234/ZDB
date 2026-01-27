const std = @import("std");
const Allocator = std.mem.Allocator;
const LSMTree = @import("lsm.zig").LSMTree;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n", .{});
    std.debug.print("======================================================================\n", .{});
    std.debug.print("ZMDB LSM-Tree Performance Benchmark\n", .{});
    std.debug.print("======================================================================\n", .{});
    std.debug.print("\n", .{});
    
    // Clean up previous test data
    std.fs.cwd().deleteTree("bench_lsm_data") catch {};
    
    var lsm = try LSMTree.init(allocator, "bench_lsm_data");
    defer lsm.deinit();
    defer std.fs.cwd().deleteTree("bench_lsm_data") catch {};
    
    // Benchmark writes
    const num_writes = 100_000;
    std.debug.print("📝 WRITE BENCHMARK ({d} operations)\n", .{num_writes});
    std.debug.print("----------------------------------------------------------------------\n", .{});
    
    const write_start = std.time.milliTimestamp();
    
    var i: usize = 0;
    while (i < num_writes) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        var val_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{i});
        const val = try std.fmt.bufPrint(&val_buf, "value_{d}_data_payload", .{i});
        try lsm.put(key, val);
    }
    
    const write_duration = std.time.milliTimestamp() - write_start;
    const write_throughput = (@as(f64, @floatFromInt(num_writes)) / @as(f64, @floatFromInt(write_duration))) * 1000.0;
    const write_latency = @as(f64, @floatFromInt(write_duration * 1000)) / @as(f64, @floatFromInt(num_writes));
    
    std.debug.print("\nLSM-Tree Writes:\n", .{});
    std.debug.print("  Operations: {d}\n", .{num_writes});
    std.debug.print("  Duration: {d}ms\n", .{write_duration});
    std.debug.print("  Throughput: {d:.0} ops/sec\n", .{write_throughput});
    std.debug.print("  Avg Latency: {d:.2}μs\n", .{write_latency});
    
    // Force flush
    try lsm.flush();
    
    // Benchmark reads
    std.debug.print("\n📖 READ BENCHMARK ({d} operations)\n", .{num_writes});
    std.debug.print("----------------------------------------------------------------------\n", .{});
    
    const read_start = std.time.milliTimestamp();
    
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = rng.random();
    
    i = 0;
    while (i < num_writes) : (i += 1) {
        const rand_key = random.intRangeAtMost(usize, 0, num_writes - 1);
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{rand_key});
        const val = try lsm.get(key);
        if (val) |v| {
            allocator.free(v);
        }
    }
    
    const read_duration = std.time.milliTimestamp() - read_start;
    const read_throughput = (@as(f64, @floatFromInt(num_writes)) / @as(f64, @floatFromInt(read_duration))) * 1000.0;
    const read_latency = @as(f64, @floatFromInt(read_duration * 1000)) / @as(f64, @floatFromInt(num_writes));
    
    std.debug.print("\nLSM-Tree Reads:\n", .{});
    std.debug.print("  Operations: {d}\n", .{num_writes});
    std.debug.print("  Duration: {d}ms\n", .{read_duration});
    std.debug.print("  Throughput: {d:.0} ops/sec\n", .{read_throughput});
    std.debug.print("  Avg Latency: {d:.2}μs\n", .{read_latency});
    
    // Print statistics
    const stats = lsm.stats();
    std.debug.print("\n📊 LSM-TREE STATISTICS\n", .{});
    std.debug.print("----------------------------------------------------------------------\n", .{});
    std.debug.print("  Total Writes: {d}\n", .{stats.total_writes});
    std.debug.print("  Total Reads: {d}\n", .{stats.total_reads});
    std.debug.print("  Memtable Flushes: {d}\n", .{stats.memtable_flushes});
    std.debug.print("  Memtable Size: {d} bytes\n", .{stats.memtable_size});
    std.debug.print("  SSTables: {d}\n", .{stats.num_sstables});
    
    std.debug.print("\n", .{});
    std.debug.print("======================================================================\n", .{});
    std.debug.print("🚀 LSM-Tree Performance: {d:.0}K writes/sec, {d:.0}K reads/sec\n", .{
        write_throughput / 1000.0,
        read_throughput / 1000.0,
    });
    std.debug.print("======================================================================\n", .{});
    std.debug.print("\n", .{});
}
