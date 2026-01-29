const std = @import("std");
const Allocator = std.mem.Allocator;

// Import C fast path functions
const c = @cImport({
    @cInclude("fast.h");
    @cInclude("unistd.h");
});

/// Fast index using C implementation for maximum performance
pub const FastIndex = struct {
    c_index: *c.FastIndex,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, capacity: usize) !FastIndex {
        const c_idx = c.fast_index_init(capacity) orelse return error.OutOfMemory;
        return .{
            .c_index = c_idx,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *FastIndex) void {
        c.fast_index_free(self.c_index);
    }
    
    /// Ultra-fast lookup using C implementation
    pub fn get(self: *FastIndex, key: []const u8, hash: u64) ?*c.IndexEntry {
        return c.fast_index_get(self.c_index, key.ptr, key.len, hash);
    }
    
    /// Fast put operation
    pub fn put(self: *FastIndex, key: []const u8, hash: u64, offset: u64, size: u32, key_len: u16, compressed: bool) !void {
        const result = c.fast_index_put(
            self.c_index,
            key.ptr,
            key.len,
            hash,
            offset,
            size,
            key_len,
            if (compressed) 1 else 0,
        );
        if (result != 0) return error.IndexFull;
    }
    
    /// Fast delete operation
    pub fn delete(self: *FastIndex, key: []const u8, hash: u64) !void {
        const result = c.fast_index_delete(self.c_index, key.ptr, key.len, hash);
        if (result != 0) return error.NotFound;
    }
    
    /// Get count
    pub fn count(self: *FastIndex) usize {
        return c.fast_index_count(self.c_index);
    }
    
    /// Iterator for scanning all entries
    pub const Iterator = struct {
        index: *FastIndex,
        pos: usize,
        
        pub fn next(self: *Iterator) ?*c.IndexEntry {
            while (self.pos < self.index.c_index.capacity) {
                const entry = &self.index.c_index.entries[self.pos];
                self.pos += 1;
                
                if (entry.hash != 0) {
                    return entry;
                }
            }
            return null;
        }
    };
    
    pub fn iterator(self: *FastIndex) Iterator {
        return .{
            .index = self,
            .pos = 0,
        };
    }
};

/// Fast WAL reader using optimized C syscalls
pub fn fastWalRead(
    fd: std.posix.fd_t,
    offset: u64,
    header_buf: []u8,
    value_buf: []u8,
    key_size: usize,
) !void {
    const result = c.fast_wal_read(
        fd,
        offset,
        header_buf.ptr,
        header_buf.len,
        value_buf.ptr,
        value_buf.len,
        key_size,
    );
    
    if (result != 0) return error.ReadFailed;
}

/// Memory-mapped file for zero-copy reads
pub const MappedFile = struct {
    c_mf: *c.MappedFile,
    
    pub fn init(fd: std.posix.fd_t) !MappedFile {
        const c_mf = c.mmap_file(fd) orelse return error.MmapFailed;
        return .{ .c_mf = c_mf };
    }
    
    pub fn deinit(self: *MappedFile) void {
        c.munmap_file(self.c_mf);
    }
    
    /// Zero-copy read from mapped file
    pub fn read(self: *MappedFile, offset: u64, size: usize) ?[]const u8 {
        const ptr = c.mmap_read(self.c_mf, offset, size) orelse return null;
        return @as([*]const u8, @ptrCast(ptr))[0..size];
    }
};

/// Memory pool for fast allocations
pub const MemPool = struct {
    c_pool: *c.MemPool,
    
    pub fn init(size: usize) !MemPool {
        const pool = c.mempool_create(size) orelse return error.OutOfMemory;
        return .{ .c_pool = pool };
    }
    
    pub fn deinit(self: *MemPool) void {
        c.free(self.c_pool.*.pool);
        c.free(self.c_pool);
    }
    
    pub fn alloc(self: *MemPool, size: usize) ?[]u8 {
        const ptr = c.mempool_alloc(self.c_pool, size) orelse return null;
        return @as([*]u8, @ptrCast(ptr))[0..size];
    }
    
    pub fn reset(self: *MemPool) void {
        c.mempool_reset(self.c_pool);
    }
};

test "fast index" {
    var idx = try FastIndex.init(std.testing.allocator, 1024);
    defer idx.deinit();
    
    // Test would go here
}
