const std = @import("std");
const zmdb = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("ZMDB - Zig Mobile Database Demo\n", .{});
    std.debug.print("================================\n\n", .{});
    
    // Initialize database
    var db = try zmdb.Database.init(allocator, "demo.db", .{
        .cache_size = 4 * 1024 * 1024,
        .compression = true,
    });
    defer db.deinit();
    
    std.debug.print("Database initialized successfully\n", .{});
    
    // Basic operations
    std.debug.print("\n--- Basic Operations ---\n", .{});
    
    try db.put("user:1", "Alice");
    try db.put("user:2", "Bob");
    try db.put("user:3", "Charlie");
    std.debug.print("Inserted 3 users\n", .{});
    
    const user1 = try db.get("user:1", allocator);
    defer allocator.free(user1);
    std.debug.print("Retrieved user:1 = {s}\n", .{user1});
    
    std.debug.print("Total keys: {d}\n", .{db.count()});
    
    // Transaction example
    std.debug.print("\n--- Transaction Example ---\n", .{});
    
    var tx = zmdb.Transaction.init(&db, allocator);
    defer tx.deinit();
    
    try tx.put("product:1", "Laptop");
    try tx.put("product:2", "Mouse");
    try tx.commit();
    
    std.debug.print("Transaction committed with 2 products\n", .{});
    std.debug.print("Total keys: {d}\n", .{db.count()});
    
    // Cleanup
    std.debug.print("\n--- Cleanup ---\n", .{});
    try db.delete("user:2");
    std.debug.print("Deleted user:2\n", .{});
    std.debug.print("Final count: {d}\n", .{db.count()});
    
    std.debug.print("\nDemo completed successfully!\n", .{});
}
