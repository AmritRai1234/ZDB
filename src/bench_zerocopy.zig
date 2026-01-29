const std = @import("std");
const Database = @import("database.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/zerocopy.db") catch {};
    std.fs.cwd().deleteFile("/tmp/zerocopy.db.wal") catch {};
    
    var db = try Database.init(allocator, "/tmp/zerocopy.db", .{
        .cache_size = 16 * 1024 * 1024,
        .compression = false,  // Disable compression for zero-copy
        .sync_mode = .none,
    });
    defer db.deinit();
    
    const num_ops = 100000;  // 100K ops for better measurement
    
    std.debug.print("\n🚀 Zero-Copy Performance Benchmark\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    
    // Write test data
    std.debug.print("📝 Writing {} records...\n", .{num_ops});
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        
        var value_buf: [128]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "value_for_key_{d}_with_some_data_here", .{i});
        
        try db.put(key, value);
    }
    std.debug.print("✅ Write complete\n\n", .{});
    
    // Benchmark get() with allocations
    std.debug.print("📖 Benchmark: get() with allocations\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    var get_timer = try std.time.Timer.start();
    i = 0;
    while (i < num_ops) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        
        const value = try db.get(key, allocator);
        allocator.free(value);
    }
    const get_ns = get_timer.read();
    const get_ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(get_ns)) / 1_000_000_000.0);
    
    std.debug.print("✅ Time: {d}ms\n", .{get_ns / 1_000_000});
    std.debug.print("✅ Throughput: {d:.0} ops/sec\n\n", .{get_ops_per_sec});
    
    // Benchmark getBorrowed() zero-copy
    std.debug.print("⚡ Benchmark: getBorrowed() ZERO-COPY\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    var borrowed_timer = try std.time.Timer.start();
    i = 0;
    while (i < num_ops) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        
        const value = try db.getBorrowed(key);
        _ = value;  // Use it but don't free (borrowed!)
    }
    const borrowed_ns = borrowed_timer.read();
    const borrowed_ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(borrowed_ns)) / 1_000_000_000.0);
    
    std.debug.print("✅ Time: {d}ms\n", .{borrowed_ns / 1_000_000});
    std.debug.print("✅ Throughput: {d:.0} ops/sec\n\n", .{borrowed_ops_per_sec});
    
    // Summary
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("📊 PERFORMANCE COMPARISON\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    
    std.debug.print("get() (with alloc):     {d:.0} ops/sec\n", .{get_ops_per_sec});
    std.debug.print("getBorrowed() (zero-copy): {d:.0} ops/sec\n\n", .{borrowed_ops_per_sec});
    
    const speedup = borrowed_ops_per_sec / get_ops_per_sec;
    std.debug.print("🔥 SPEEDUP: {d:.2}x faster with zero-copy!\n\n", .{speedup});
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/zerocopy.db") catch {};
    std.fs.cwd().deleteFile("/tmp/zerocopy.db.wal") catch {};
}
