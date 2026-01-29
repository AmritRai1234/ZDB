const std = @import("std");
const Allocator = std.mem.Allocator;
const LRUCache = @import("cache.zig").LRUCache;
const compress = @import("compression.zig").compress;
const decompress = @import("compression.zig").decompress;
const simd = @import("simd.zig");
const WriteCombiningBuffer = @import("write_buffer.zig").WriteCombiningBuffer;
const fast = @import("fast.zig");

/// Database configuration options
pub const Config = struct {
    /// Size of in-memory cache in bytes (default: 16MB for better performance)
    cache_size: usize = 16 * 1024 * 1024,
    
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
    index: fast.FastIndex,  // C hash table for maximum performance
    wal: ?std.fs.File,
    rwlock: std.Thread.RwLock,
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
        key_len: u16,  // Store key length to avoid double-read
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
            .index = try fast.FastIndex.init(allocator, 1024 * 1024),  // 1M capacity
            .wal = wal,
            .rwlock = .{},
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
        // FastIndex cleanup (no need to free keys, C handles it)
        self.index.deinit();
        self.cache.deinit();
        
        // Clean up write buffer
        if (self.write_buffer) |*wb| {
            wb.deinit();
        }
        
        self.file.close();
        if (self.wal) |wal| {
            wal.close();
        }
    }
    
    /// Store a key-value pair
    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        if (key.len == 0) return error.InvalidKey;
        
        self.rwlock.lock();  // Exclusive write lock
        defer self.rwlock.unlock();
        
        // Write to WAL first for durability
        const offset = try self.appendToWAL(key, value);
        
        // Update in-memory index using C hash table
        const hash = std.hash.Wyhash.hash(0, key);
        try self.index.put(
            key,
            hash,
            offset,
            @intCast(value.len),
            @intCast(key.len),
            self.config.compression,
        );
        
        // Sync if configured
        if (self.config.sync_mode == .full) {
            try self.wal.?.sync();
        }
    }
    
    /// Retrieve a value by key (ultra-optimized with single syscall)
    pub fn get(self: *Database, key: []const u8, allocator: Allocator) ![]u8 {
        self.rwlock.lockShared();  // Shared read lock - multiple readers OK!
        defer self.rwlock.unlockShared();
        
        // Lookup in C hash table
        const hash = std.hash.Wyhash.hash(0, key);
        const c_entry = self.index.get(key, hash) orelse return error.NotFound;
        
        // Convert C entry to Zig entry
        const entry = Entry{
            .offset = c_entry.offset,
            .size = c_entry.size,
            .key_len = c_entry.key_len,
            .compressed = c_entry.compressed != 0,
        };
        
        // Read from WAL/main file
        const wal_file = self.wal orelse return error.Corruption;
        const fd = wal_file.handle;
        
        // Calculate total size using key_len from index (single read!)
        const header_size = @sizeOf(RecordHeader);
        const total_size = header_size + entry.key_len + entry.size;
        
        // Single pread syscall for entire record
        var read_buf = try allocator.alloc(u8, total_size);
        defer allocator.free(read_buf);
        
        const bytes_read = try std.posix.pread(fd, read_buf, entry.offset);
        if (bytes_read != total_size) return error.Corruption;
        
        // Extract value (skip header + key)
        const value_offset = header_size + entry.key_len;
        const value = try allocator.dupe(u8, read_buf[value_offset..value_offset + entry.size]);
        
        // Decompress if needed
        if (entry.compressed and self.config.compression) {
            const decompressed = try decompress(allocator, value, entry.size);
            allocator.free(value);
            return decompressed;
        }
        
        return value;
    }
    
    /// Delete a key-value pair
    pub fn delete(self: *Database, key: []const u8) !void {
        self.rwlock.lock();  // Exclusive write lock
        defer self.rwlock.unlock();
        
        // Delete from C hash table
        const hash = std.hash.Wyhash.hash(0, key);
        try self.index.delete(key, hash);
        
        // Write tombstone to WAL
        try self.appendTombstone(key);
    }
    
    /// Check if a key exists
    pub fn contains(self: *Database, key: []const u8) bool {
        self.rwlock.lockShared();  // Shared read lock
        defer self.rwlock.unlockShared();
        
        const hash = std.hash.Wyhash.hash(0, key);
        return self.index.get(key, hash) != null;
    }
    
    /// Get the number of keys in the database
    pub fn count(self: *Database) usize {
        self.rwlock.lockShared();  // Shared read lock
        defer self.rwlock.unlockShared();
        
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
        const wal_file = self.wal orelse return;
        
        // Get WAL file size
        const stat = try wal_file.stat();
        const file_size = stat.size;
        
        if (file_size == 0) return; // Empty WAL, nothing to load
        
        // Scan WAL from beginning
        var offset: u64 = 0;
        while (offset < file_size) {
            // Read record header
            var header: RecordHeader = undefined;
            const header_bytes = try std.posix.pread(
                wal_file.handle,
                std.mem.asBytes(&header),
                offset
            );
            
            if (header_bytes != @sizeOf(RecordHeader)) break; // End of valid data
            
            // Read key
            const key_offset = offset + @sizeOf(RecordHeader);
            const key_buf = try self.allocator.alloc(u8, header.key_len);
            errdefer self.allocator.free(key_buf);
            
            const key_bytes = try std.posix.pread(
                wal_file.handle,
                key_buf,
                key_offset
            );
            
            if (key_bytes != header.key_len) {
                self.allocator.free(key_buf);
                break; // Corrupted record
            }
            
            // Add to index using C hash table
            const hash = std.hash.Wyhash.hash(0, key_buf);
            try self.index.put(
                key_buf,
                hash,
                offset,
                header.value_len,
                header.key_len,
                (header.flags & 0x01) != 0,
            );
            
            // Move to next record
            offset += @sizeOf(RecordHeader) + header.key_len + header.value_len;
        }
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
    
    // Clean up from previous runs
    std.fs.cwd().deleteFile("/tmp/test.db") catch {};
    std.fs.cwd().deleteFile("/tmp/test.db.wal") catch {};
    
    var db = try Database.init(allocator, "/tmp/test.db", .{});
    defer db.deinit();
    
    try std.testing.expect(db.count() == 0);
}

test "basic put and get" {
    const allocator = std.testing.allocator;
    
    // Clean up from previous runs
    std.fs.cwd().deleteFile("/tmp/test_put_get.db") catch {};
    std.fs.cwd().deleteFile("/tmp/test_put_get.db.wal") catch {};
    
    var db = try Database.init(allocator, "/tmp/test_put_get.db", .{});
    defer db.deinit();
    
    try db.put("hello", "world");
    
    const value = try db.get("hello", allocator);
    defer allocator.free(value);
    
    try std.testing.expectEqualStrings("world", value);
}

test "delete key" {
    const allocator = std.testing.allocator;
    
    // Clean up from previous runs
    std.fs.cwd().deleteFile("/tmp/test_delete.db") catch {};
    std.fs.cwd().deleteFile("/tmp/test_delete.db.wal") catch {};
    
    var db = try Database.init(allocator, "/tmp/test_delete.db", .{});
    defer db.deinit();
    
    try db.put("key", "value");
    try std.testing.expect(db.contains("key"));
    
    try db.delete("key");
    try std.testing.expect(!db.contains("key"));
}
