const std = @import("std");

/// Configuration for WASM database
pub const Config = struct {
    cache_size: usize = 4 * 1024 * 1024,
    compression: bool = false, // Disabled for WASM for now
    sync_mode: SyncMode = .normal,
};

pub const SyncMode = enum {
    none,
    normal,
    full,
};

/// Simplified in-memory database for WASM
/// File system operations will be handled by JavaScript/IndexedDB
pub const Database = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap([]u8),
    mutex: std.Thread.Mutex,
    
    // Statistics
    total_reads: usize,
    total_writes: usize,
    bytes_compressed: usize,
    bytes_uncompressed: usize,
    
    pub fn init(allocator: std.mem.Allocator, _path: []const u8, _config: Config) !Database {
        _ = _path; // Path is ignored in WASM, persistence handled by JS
        _ = _config;
        
        return Database{
            .allocator = allocator,
            .data = std.StringHashMap([]u8).init(allocator),
            .mutex = .{},
            .total_reads = 0,
            .total_writes = 0,
            .bytes_compressed = 0,
            .bytes_uncompressed = 0,
        };
    }
    
    pub fn deinit(self: *Database) void {
        // Free all keys and values
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }
    
    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        if (key.len == 0) return error.InvalidKey;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Make copies of key and value
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        
        // Check if key already exists and free old value
        if (self.data.get(key)) |old_value| {
            self.allocator.free(old_value);
        }
        
        try self.data.put(key_copy, value_copy);
        self.total_writes += 1;
    }
    
    pub fn get(self: *Database, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const value = self.data.get(key) orelse return error.NotFound;
        self.total_reads += 1;
        
        // Return a copy
        return try allocator.dupe(u8, value);
    }
    
    pub fn delete(self: *Database, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.data.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        } else {
            return error.NotFound;
        }
    }
    
    pub fn contains(self: *Database, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.data.contains(key);
    }
    
    pub fn count(self: *Database) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.data.count();
    }
};
