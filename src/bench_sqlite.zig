const std = @import("std");
const Database = @import("database.zig").Database;
const Transaction = @import("transaction.zig").Transaction;

// SQLite C bindings
const c = @cImport({
    @cInclude("sqlite3.h");
});

const BenchmarkResult = struct {
    name: []const u8,
    operations: usize,
    duration_ms: i64,
    ops_per_sec: f64,
    avg_latency_us: f64,
};

fn printResult(result: BenchmarkResult) void {
    std.debug.print("\n{s}:\n", .{result.name});
    std.debug.print("  Operations: {}\n", .{result.operations});
    std.debug.print("  Duration: {}ms\n", .{result.duration_ms});
    std.debug.print("  Throughput: {d:.0} ops/sec\n", .{result.ops_per_sec});
    std.debug.print("  Avg Latency: {d:.2}μs\n", .{result.avg_latency_us});
}

fn benchmarkZMDBWritesBatched(allocator: std.mem.Allocator, count: usize) !BenchmarkResult {
    const start = std.time.milliTimestamp();
    
    var db = try Database.init(allocator, "bench_zmdb.db", .{
        .cache_size = 4 * 1024 * 1024,
        .compression = false,
        .sync_mode = .none,
    });
    defer db.deinit();
    
    // Use transaction for fair comparison
    var tx = Transaction.init(&db, allocator);
    defer tx.deinit();
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{i});
        
        var value_buf: [128]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "value_{d}_{s}", .{i, "x" ** 100});
        
        try tx.put(key, value);
    }
    
    try tx.commit();
    
    const end = std.time.milliTimestamp();
    const duration = end - start;
    
    return .{
        .name = "ZMDB Batched Writes (Transaction)",
        .operations = count,
        .duration_ms = duration,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        .avg_latency_us = (@as(f64, @floatFromInt(duration)) * 1000.0) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkZMDBWritesUnbatched(allocator: std.mem.Allocator, count: usize) !BenchmarkResult {
    const start = std.time.milliTimestamp();
    
    var db = try Database.init(allocator, "bench_zmdb_unbatched.db", .{
        .cache_size = 4 * 1024 * 1024,
        .compression = false,
        .sync_mode = .none,
    });
    defer db.deinit();
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{i});
        
        var value_buf: [128]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "value_{d}_{s}", .{i, "x" ** 100});
        
        try db.put(key, value);
    }
    
    const end = std.time.milliTimestamp();
    const duration = end - start;
    
    return .{
        .name = "ZMDB Individual Writes (No Transaction)",
        .operations = count,
        .duration_ms = duration,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        .avg_latency_us = (@as(f64, @floatFromInt(duration)) * 1000.0) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkSQLiteWrites(count: usize) !BenchmarkResult {
    const start = std.time.milliTimestamp();
    
    var db: ?*c.sqlite3 = null;
    _ = c.sqlite3_open("bench_sqlite.db", &db);
    defer _ = c.sqlite3_close(db);
    
    const create_sql = "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)";
    _ = c.sqlite3_exec(db, create_sql, null, null, null);
    
    _ = c.sqlite3_exec(db, "PRAGMA synchronous = OFF", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA journal_mode = MEMORY", null, null, null);
    
    _ = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, null);
    
    var stmt: ?*c.sqlite3_stmt = null;
    const insert_sql = "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)";
    _ = c.sqlite3_prepare_v2(db, insert_sql, -1, &stmt, null);
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{i}) catch unreachable;
        
        var value_buf: [128]u8 = undefined;
        const value = std.fmt.bufPrint(&value_buf, "value_{d}_{s}", .{i, "x" ** 100}) catch unreachable;
        
        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, value.ptr, @intCast(value.len), null);
        _ = c.sqlite3_step(stmt);
        _ = c.sqlite3_reset(stmt);
    }
    
    _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_exec(db, "COMMIT", null, null, null);
    
    const end = std.time.milliTimestamp();
    const duration = end - start;
    
    return .{
        .name = "SQLite Batched Writes (Transaction)",
        .operations = count,
        .duration_ms = duration,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        .avg_latency_us = (@as(f64, @floatFromInt(duration)) * 1000.0) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkZMDBReads(allocator: std.mem.Allocator, count: usize) !BenchmarkResult {
    var db = try Database.init(allocator, "bench_zmdb.db", .{
        .cache_size = 4 * 1024 * 1024,
        .compression = false,
        .sync_mode = .none,
    });
    
    // Populate with transaction
    var tx = Transaction.init(&db, allocator);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{i});
        
        var value_buf: [128]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "value_{d}_{s}", .{i, "x" ** 100});
        
        try tx.put(key, value);
    }
    try tx.commit();
    tx.deinit();
    
    const start = std.time.milliTimestamp();
    
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    i = 0;
    while (i < count) : (i += 1) {
        const random_key = rng.random().intRangeAtMost(usize, 0, count - 1);
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{random_key});
        
        const value = try db.get(key, allocator);
        allocator.free(value);
    }
    
    const end = std.time.milliTimestamp();
    const duration = end - start;
    
    db.deinit();
    
    return .{
        .name = "ZMDB Random Reads",
        .operations = count,
        .duration_ms = duration,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        .avg_latency_us = (@as(f64, @floatFromInt(duration)) * 1000.0) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkSQLiteReads(count: usize) !BenchmarkResult {
    var db: ?*c.sqlite3 = null;
    _ = c.sqlite3_open("bench_sqlite.db", &db);
    defer _ = c.sqlite3_close(db);
    
    const start = std.time.milliTimestamp();
    
    var stmt: ?*c.sqlite3_stmt = null;
    const select_sql = "SELECT value FROM kv WHERE key = ?";
    _ = c.sqlite3_prepare_v2(db, select_sql, -1, &stmt, null);
    
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const random_key = rng.random().intRangeAtMost(usize, 0, count - 1);
        
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d:0>10}", .{random_key}) catch unreachable;
        
        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null);
        _ = c.sqlite3_step(stmt);
        _ = c.sqlite3_reset(stmt);
    }
    
    _ = c.sqlite3_finalize(stmt);
    
    const end = std.time.milliTimestamp();
    const duration = end - start;
    
    return .{
        .name = "SQLite Random Reads",
        .operations = count,
        .duration_ms = duration,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        .avg_latency_us = (@as(f64, @floatFromInt(duration)) * 1000.0) / @as(f64, @floatFromInt(count)),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("ZMDB vs SQLite - Fair Comparison Benchmark\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    
    const count = 10_000;
    
    // Clean up
    std.fs.cwd().deleteFile("bench_zmdb.db") catch {};
    std.fs.cwd().deleteFile("bench_zmdb.db.wal") catch {};
    std.fs.cwd().deleteFile("bench_zmdb_unbatched.db") catch {};
    std.fs.cwd().deleteFile("bench_zmdb_unbatched.db.wal") catch {};
    std.fs.cwd().deleteFile("bench_sqlite.db") catch {};
    
    // WRITE BENCHMARKS
    std.debug.print("\n📝 WRITE BENCHMARKS ({} operations)\n", .{count});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    const zmdb_batched = try benchmarkZMDBWritesBatched(allocator, count);
    printResult(zmdb_batched);
    
    const sqlite_writes = try benchmarkSQLiteWrites(count);
    printResult(sqlite_writes);
    
    const zmdb_unbatched = try benchmarkZMDBWritesUnbatched(allocator, count);
    printResult(zmdb_unbatched);
    
    const write_speedup = zmdb_batched.ops_per_sec / sqlite_writes.ops_per_sec;
    std.debug.print("\n⚡ ZMDB (batched) is {d:.2}x ", .{write_speedup});
    if (write_speedup > 1.0) {
        std.debug.print("FASTER", .{});
    } else {
        std.debug.print("SLOWER", .{});
    }
    std.debug.print(" than SQLite for writes\n", .{});
    
    const unbatched_penalty = zmdb_unbatched.ops_per_sec / zmdb_batched.ops_per_sec;
    std.debug.print("📊 Transaction batching gives {d:.1}x speedup\n", .{1.0 / unbatched_penalty});
    
    // READ BENCHMARKS
    std.debug.print("\n📖 READ BENCHMARKS ({} operations)\n", .{count});
    std.debug.print("-" ** 70 ++ "\n", .{});
    
    const zmdb_reads = try benchmarkZMDBReads(allocator, count);
    printResult(zmdb_reads);
    
    const sqlite_reads = try benchmarkSQLiteReads(count);
    printResult(sqlite_reads);
    
    const read_speedup = zmdb_reads.ops_per_sec / sqlite_reads.ops_per_sec;
    std.debug.print("\n⚡ ZMDB is {d:.2}x ", .{read_speedup});
    if (read_speedup > 1.0) {
        std.debug.print("FASTER", .{});
    } else {
        std.debug.print("SLOWER", .{});
    }
    std.debug.print(" than SQLite for reads\n", .{});
    
    // SUMMARY
    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("SUMMARY\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("ZMDB Batched Writes:   {d:.0} ops/sec\n", .{zmdb_batched.ops_per_sec});
    std.debug.print("ZMDB Unbatched Writes: {d:.0} ops/sec\n", .{zmdb_unbatched.ops_per_sec});
    std.debug.print("SQLite Batched Writes: {d:.0} ops/sec\n", .{sqlite_writes.ops_per_sec});
    std.debug.print("ZMDB Reads:            {d:.0} ops/sec\n", .{zmdb_reads.ops_per_sec});
    std.debug.print("SQLite Reads:          {d:.0} ops/sec\n", .{sqlite_reads.ops_per_sec});
    std.debug.print("\n💡 Key Insight: Transaction batching is critical for write performance!\n", .{});
    std.debug.print("\n", .{});
    
    // Clean up
    std.fs.cwd().deleteFile("bench_zmdb.db") catch {};
    std.fs.cwd().deleteFile("bench_zmdb.db.wal") catch {};
    std.fs.cwd().deleteFile("bench_zmdb_unbatched.db") catch {};
    std.fs.cwd().deleteFile("bench_zmdb_unbatched.db.wal") catch {};
    std.fs.cwd().deleteFile("bench_sqlite.db") catch {};
}
