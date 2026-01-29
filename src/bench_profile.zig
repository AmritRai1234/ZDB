const std = @import("std");
const Database = @import("database.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/profile.db") catch {};
    std.fs.cwd().deleteFile("/tmp/profile.db.wal") catch {};
    
    var db = try Database.init(allocator, "/tmp/profile.db", .{
        .cache_size = 16 * 1024 * 1024,
        .compression = false,
        .sync_mode = .none,
    });
    defer db.deinit();
    
    const num_ops = 10000;
    
    std.debug.print("\n🔬 Profiling ZDB Operations\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    
    // Profile writes
    std.debug.print("📝 Write Operations ({} ops)\n", .{num_ops});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    var write_timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        
        var value_buf: [128]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "value_for_key_{d}_with_some_data", .{i});
        
        try db.put(key, value);
    }
    const write_ns = write_timer.read();
    const write_ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(write_ns)) / 1_000_000_000.0);
    
    std.debug.print("✅ Total time: {d}ms\n", .{write_ns / 1_000_000});
    std.debug.print("✅ Throughput: {d:.0} ops/sec\n\n", .{write_ops_per_sec});
    
    // Profile reads
    std.debug.print("📖 Read Operations ({} ops)\n", .{num_ops});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    var read_timer = try std.time.Timer.start();
    i = 0;
    while (i < num_ops) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        
        const value = try db.get(key, allocator);
        allocator.free(value);
    }
    const read_ns = read_timer.read();
    const read_ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(read_ns)) / 1_000_000_000.0);
    
    std.debug.print("✅ Total time: {d}ms\n", .{read_ns / 1_000_000});
    std.debug.print("✅ Throughput: {d:.0} ops/sec\n\n", .{read_ops_per_sec});
    
    // Profile index lookups (no I/O)
    std.debug.print("🔍 Index Lookup Only ({} ops)\n", .{num_ops});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    var lookup_timer = try std.time.Timer.start();
    i = 0;
    while (i < num_ops) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        
        _ = db.contains(key);
    }
    const lookup_ns = lookup_timer.read();
    const lookup_ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(lookup_ns)) / 1_000_000_000.0);
    
    std.debug.print("✅ Total time: {d}ms\n", .{lookup_ns / 1_000_000});
    std.debug.print("✅ Throughput: {d:.0} ops/sec\n\n", .{lookup_ops_per_sec});
    
    // Summary
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("📊 SUMMARY\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    
    std.debug.print("Write throughput:  {d:.0} ops/sec\n", .{write_ops_per_sec});
    std.debug.print("Read throughput:   {d:.0} ops/sec\n", .{read_ops_per_sec});
    std.debug.print("Lookup throughput: {d:.0} ops/sec\n\n", .{lookup_ops_per_sec});
    
    const io_overhead = read_ops_per_sec / lookup_ops_per_sec;
    std.debug.print("💡 I/O overhead: {d:.2}x slower than pure index lookup\n", .{1.0 / io_overhead});
    std.debug.print("💡 Index is {d:.0}% of read time\n", .{(1.0 - io_overhead) * 100.0});
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/profile.db") catch {};
    std.fs.cwd().deleteFile("/tmp/profile.db.wal") catch {};
}
