const std = @import("std");
const Database = @import("database.zig").Database;

/// Transaction handle for atomic operations
pub const Transaction = struct {
    db: *Database,
    allocator: std.mem.Allocator,
    operations: std.ArrayList(Operation),
    committed: bool,
    
    const Operation = union(enum) {
        put: struct {
            key: []const u8,
            value: []const u8,
        },
        delete: []const u8,
    };
    
    pub fn init(db: *Database, allocator: std.mem.Allocator) Transaction {
        return .{
            .db = db,
            .allocator = allocator,
            .operations = .{},  // Empty ArrayList
            .committed = false,
        };
    }
    
    pub fn deinit(self: *Transaction) void {
        self.operations.deinit(self.allocator);
    }
    
    pub fn put(self: *Transaction, key: []const u8, value: []const u8) !void {
        try self.operations.append(self.allocator, .{
            .put = .{ .key = key, .value = value },
        });
    }
    
    pub fn delete(self: *Transaction, key: []const u8) !void {
        try self.operations.append(self.allocator, .{ .delete = key });
    }
    
    pub fn commit(self: *Transaction) !void {
        if (self.committed) return error.AlreadyCommitted;
        
        // Apply all operations atomically
        for (self.operations.items) |op| {
            switch (op) {
                .put => |p| try self.db.put(p.key, p.value),
                .delete => |k| try self.db.delete(k),
            }
        }
        
        self.committed = true;
    }
    
    pub fn rollback(self: *Transaction) void {
        self.operations.clearRetainingCapacity();
        self.committed = true; // Mark as done
    }
};
