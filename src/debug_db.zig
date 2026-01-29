const std = @import("std");
const Database = @import("database.zig").Database;
const Transaction = @import("transaction.zig").Transaction;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n🔍 Debugging ZMDB Read/Write Issue\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    
    // Clean up
    std.fs.cwd().deleteFile("debug.db") catch {};
    std.fs.cwd().deleteFile("debug.db.wal") catch {};
    
    var db = try Database.init(allocator, "debug.db", .{
        .cache_size = 4 * 1024 * 1024,
        .compression = false,
        .sync_mode = .none,
    });
    defer db.deinit();
    
    std.debug.print("✅ Database initialized\n\n", .{});
    
    // Test 1: Direct put/get (no transaction)
    std.debug.print("Test 1: Direct put/get\n", .{});
    std.debug.print("-" ** 40 ++ "\n", .{});
    
    try db.put("test_key_1", "test_value_1");
    std.debug.print("✅ Put: test_key_1 = test_value_1\n", .{});
    
    if (db.get("test_key_1", allocator)) |value| {
        defer allocator.free(value);
        std.debug.print("✅ Get: test_key_1 = {s}\n\n", .{value});
    } else |err| {
        std.debug.print("❌ Get failed: {}\n\n", .{err});
    }
    
    // Test 2: Transaction put/get
    std.debug.print("Test 2: Transaction put/get\n", .{});
    std.debug.print("-" ** 40 ++ "\n", .{});
    
    var tx = Transaction.init(&db, allocator);
    defer tx.deinit();
    
    try tx.put("tx_key_1", "tx_value_1");
    try tx.put("tx_key_2", "tx_value_2");
    std.debug.print("✅ Transaction: Added 2 keys\n", .{});
    
    try tx.commit();
    std.debug.print("✅ Transaction: Committed\n", .{});
    
    if (db.get("tx_key_1", allocator)) |value| {
        defer allocator.free(value);
        std.debug.print("✅ Get: tx_key_1 = {s}\n", .{value});
    } else |err| {
        std.debug.print("❌ Get tx_key_1 failed: {}\n", .{err});
    }
    
    if (db.get("tx_key_2", allocator)) |value| {
        defer allocator.free(value);
        std.debug.print("✅ Get: tx_key_2 = {s}\n\n", .{value});
    } else |err| {
        std.debug.print("❌ Get tx_key_2 failed: {}\n\n", .{err});
    }
    
    // Test 3: Check index
    std.debug.print("Test 3: Index contents\n", .{});
    std.debug.print("-" ** 40 ++ "\n", .{});
    std.debug.print("Index size: {}\n", .{db.index.count()});
    
    var iter = db.index.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const key = entry.key[0..entry.key_len];
        std.debug.print("  Key {}: {s}\n", .{count, key});
        count += 1;
    }
    
    std.debug.print("\n", .{});
    
    // Clean up
    std.fs.cwd().deleteFile("debug.db") catch {};
    std.fs.cwd().deleteFile("debug.db.wal") catch {};
}
