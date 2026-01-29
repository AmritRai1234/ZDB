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
        c.free(self.c_index.*.entries);
        c.free(self.c_index);
    }
    
    /// Ultra-fast lookup using C implementation
    pub fn get(self: *FastIndex, key: []const u8, hash: u64) ?*c.IndexEntry {
        return c.fast_index_get(self.c_index, key.ptr, key.len, hash);
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
