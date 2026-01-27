const std = @import("std");
const Database = @import("database.zig").Database;

/// Iterator for range queries
pub const Iterator = struct {
    db: *Database,
    keys: [][]const u8,
    index: usize,
    allocator: std.mem.Allocator,
    
    pub const Entry = struct {
        key: []const u8,
        value: []u8,
    };
    
    pub fn init(db: *Database, start: []const u8, end: []const u8, allocator: std.mem.Allocator) !Iterator {
        _ = start;
        _ = end;
        
        // TODO: Implement proper range scanning with B-tree
        // For now, return all keys
        var keys = std.ArrayList([]const u8).init(allocator);
        
        var iter = db.index.keyIterator();
        while (iter.next()) |key| {
            try keys.append(key.*);
        }
        
        return .{
            .db = db,
            .keys = try keys.toOwnedSlice(),
            .index = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Iterator) void {
        self.allocator.free(self.keys);
    }
    
    pub fn next(self: *Iterator) !?Entry {
        if (self.index >= self.keys.len) return null;
        
        const key = self.keys[self.index];
        self.index += 1;
        
        const value = try self.db.get(key, self.allocator);
        
        return Entry{
            .key = key,
            .value = value,
        };
    }
};
