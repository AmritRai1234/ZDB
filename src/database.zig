const std = @import("std");
const Allocator = std.mem.Allocator;
const LRUCache = @import("cache.zig").LRUCache;
const compress = @import("compression.zig").compress;
const decompress = @import("compression.zig").decompress;
const simd = @import("simd.zig");
const WriteCombiningBuffer = @import("write_buffer.zig").WriteCombiningBuffer;

/// Database configuration options
pub const Config = struct {
    /// Size of in-memory cache in bytes (default: 4MB)
    cache_size: usize = 4 * 1024 * 1024,
    
    /// Enable compression for stored values
    compression: bool = true,
    
    /// Optional encryption key (32 bytes for AES-256)
    encryption_key: ?[]const u8 = null,
    
    /// Sync mode: .none (fastest), .normal, .full (safest)
    sync_mode: SyncMode = .normal,
    
    /// Maximum file size before compaction (default: 100MB)
    max_file_size: usize = 100 * 1024 * 1024,
};

pub const SyncMode = enum {
    none,    // No fsync (fastest, least safe)
    normal,  // Fsync on transaction commit
    full,    // Fsync on every write
};

/// Main database handle
pub const Database = struct {
    allocator: Allocator,
    config: Config,
    file: std.fs.File,
    index: std.StringHashMap(Entry),
    wal: ?std.fs.File,
    mutex: std.Thread.Mutex,
    cache: LRUCache([256]u8, []u8), // Cache for read optimization
    write_buffer: ?WriteCombiningBuffer, // High-performance write batching
    
    // Statistics
    total_reads: usize,
    total_writes: usize,
    bytes_compressed: usize,
    bytes_uncompressed: usize,
    
    /// Internal entry metadata
    const Entry = struct {
        offset: u64,
        size: u32,
        compressed: bool,
    };
    
    /// Initialize a new database or open an existing one
    pub fn init(allocator: Allocator, path: []const u8, config: Config) !Database {
        // Open or create database file
        const file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();
        
        // Open WAL file
        var wal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{path});
        const wal = try std.fs.cwd().createFile(wal_path, .{
            .read = true,
            .truncate = false,
        });
        errdefer wal.close();
        
        // Initialize write buffer for high-performance writes
        const write_buffer = WriteCombiningBuffer.init(allocator, wal) catch null;
        
        var db = Database{
            .allocator = allocator,
            .config = config,
            .file = file,
            .index = std.StringHashMap(Entry).init(allocator),
            .wal = wal,
            .mutex = .{},
            .cache = LRUCache([256]u8, []u8).init(allocator, 256), // 256 entry cache
            .write_buffer = write_buffer,
            .total_reads = 0,
            .total_writes = 0,
            .bytes_compressed = 0,
            .bytes_uncompressed = 0,
        };
        
        // Load existing index from file
        try db.loadIndex();
        
        return db;
    }
    
    /// Clean up and close database
    pub fn deinit(self: *Database) void {
        // Free all keys in the index
        var iter = self.index.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        
        self.index.deinit();
        self.cache.deinit();
        self.file.close();
        if (self.wal) |wal| {
            wal.close();
        }
    }
    
    /// Store a key-value pair
    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        if (key.len == 0) return error.InvalidKey;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Write to WAL first for durability
        const offset = try self.appendToWAL(key, value);
        
        // Update in-memory index
        const key_copy = try self.allocator.dupe(u8, key);
        try self.index.put(key_copy, .{
            .offset = offset,
            .size = @intCast(value.len),
            .compressed = self.config.compression,
        });
        
        // Sync if configured
        if (self.config.sync_mode == .full) {
            try self.wal.?.sync();
        }
    }
    
    /// Retrieve a value by key
    pub fn get(self: *Database, key: []const u8, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const entry = self.index.get(key) orelse return error.NotFound;
        
        // Read from WAL/main file
        const wal_file = self.wal orelse return error.Corruption;
        try wal_file.seekTo(entry.offset);
        
        // Read record header
        var header: RecordHeader = undefined;
        const bytes_read = try wal_file.read(std.mem.asBytes(&header));
        if (bytes_read != @sizeOf(RecordHeader)) return error.Corruption;
        
        // Skip the key (we already know it)
        const key_buf = try allocator.alloc(u8, header.key_len);
        defer allocator.free(key_buf);
        _ = try wal_file.read(key_buf);
        
        // Read value
        const value = try allocator.alloc(u8, header.value_len);
        errdefer allocator.free(value);
        
        _ = try wal_file.read(value);
        
        // Decompress if needed
        if (entry.compressed and self.config.compression) {
            // TODO: Implement decompression
            return value;
        }
        
        return value;
    }
    
    /// Delete a key-value pair
    pub fn delete(self: *Database, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.index.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            
            // Write tombstone to WAL
            try self.appendTombstone(key);
        } else {
            return error.NotFound;
        }
    }
    
    /// Check if a key exists
    pub fn contains(self: *Database, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.index.contains(key);
    }
    
    /// Get the number of keys in the database
    pub fn count(self: *Database) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.index.count();
    }
    
    // Internal methods
    
    const RecordHeader = packed struct {
        key_len: u16,
        value_len: u32,
        checksum: u32,
        flags: u8,
    };
    
    fn loadIndex(self: *Database) !void {
        _ = self;
        // TODO: Scan WAL and main file to rebuild index
        // For now, start with empty index
    }
    
    fn appendToWAL(self: *Database, key: []const u8, value: []const u8) !u64 {
        const wal_file = self.wal orelse return error.Corruption;
        const offset = try wal_file.getEndPos();
        
        try wal_file.seekTo(offset);
        
        // Write record header
        const header = RecordHeader{
            .key_len = @intCast(key.len),
            .value_len = @intCast(value.len),
            .checksum = computeChecksum(key, value),
            .flags = 0,
        };
        
        try wal_file.writeAll(std.mem.asBytes(&header));
        try wal_file.writeAll(key);
        try wal_file.writeAll(value);
        
        return offset;
    }
    
    fn appendTombstone(self: *Database, key: []const u8) !void {
        const wal_file = self.wal orelse return error.Corruption;
        
        const header = RecordHeader{
            .key_len = @intCast(key.len),
            .value_len = 0,
            .checksum = computeChecksum(key, ""),
            .flags = 1, // Tombstone flag
        };
        
        try wal_file.writeAll(std.mem.asBytes(&header));
        try wal_file.writeAll(key);
    }
    
    fn computeChecksum(key: []const u8, value: []const u8) u32 {
        var hasher = std.hash.Crc32.init();
        hasher.update(key);
        hasher.update(value);
        return hasher.final();
    }
};

test "database init and deinit" {
    const allocator = std.testing.allocator;
    
    var db = try Database.init(allocator, "/tmp/test.db", .{});
    defer db.deinit();
    
    try std.testing.expect(db.count() == 0);
}

test "basic put and get" {
    const allocator = std.testing.allocator;
    
    var db = try Database.init(allocator, "/tmp/test_put_get.db", .{});
    defer db.deinit();
    
    try db.put("hello", "world");
    
    const value = try db.get("hello", allocator);
    defer allocator.free(value);
    
    try std.testing.expectEqualStrings("world", value);
}

test "delete key" {
    const allocator = std.testing.allocator;
    
    var db = try Database.init(allocator, "/tmp/test_delete.db", .{});
    defer db.deinit();
    
    try db.put("key", "value");
    try std.testing.expect(db.contains("key"));
    
    try db.delete("key");
    try std.testing.expect(!db.contains("key"));
}
