const std = @import("std");
const Allocator = std.mem.Allocator;

/// Memory-efficient allocators for mobile devices
/// Optimized for low memory overhead and predictable performance

/// Arena allocator for transaction batches
/// Allocates from a fixed buffer, frees all at once
pub const TransactionArena = struct {
    buffer: []u8,
    backing_allocator: Allocator,
    fba: std.heap.FixedBufferAllocator,
    
    pub fn init(backing_allocator: Allocator, size: usize) !TransactionArena {
        const buffer = try backing_allocator.alloc(u8, size);
        return .{
            .buffer = buffer,
            .backing_allocator = backing_allocator,
            .fba = std.heap.FixedBufferAllocator.init(buffer),
        };
    }
    
    pub fn deinit(self: *TransactionArena) void {
        self.backing_allocator.free(self.buffer);
    }
    
    pub fn allocator(self: *TransactionArena) Allocator {
        return self.fba.allocator();
    }
    
    pub fn reset(self: *TransactionArena) void {
        self.fba.reset();
    }
};

/// Memory pool for B-tree nodes
/// Pre-allocates nodes to reduce allocation overhead
pub fn NodePool(comptime T: type, comptime pool_size: usize) type {
    return struct {
        const Self = @This();
        
        nodes: [pool_size]T,
        free_list: std.ArrayList(usize),
        allocator: Allocator,
        
        pub fn init(allocator: Allocator) !Self {
            return .{
                .nodes = undefined,
                .free_list = blk: {
                    var list = std.ArrayList(usize).init(allocator);
                    var i: usize = 0;
                    while (i < pool_size) : (i += 1) {
                        try list.append(allocator, i);
                    }
                    break :blk list;
                },
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.free_list.deinit(self.allocator);
        }
        
        pub fn acquire(self: *Self) ?*T {
            if (self.free_list.items.len == 0) return null;
            const index = self.free_list.pop();
            return &self.nodes[index];
        }
        
        pub fn release(self: *Self, node: *T) !void {
            const index = (@intFromPtr(node) - @intFromPtr(&self.nodes[0])) / @sizeOf(T);
            try self.free_list.append(self.allocator, index);
        }
    };
}

/// Tracking allocator for leak detection in debug builds
pub const TrackingAllocator = struct {
    backing_allocator: Allocator,
    allocations: std.AutoHashMap(usize, usize),
    total_allocated: usize,
    total_freed: usize,
    
    pub fn init(backing_allocator: Allocator) TrackingAllocator {
        return .{
            .backing_allocator = backing_allocator,
            .allocations = std.AutoHashMap(usize, usize).init(backing_allocator),
            .total_allocated = 0,
            .total_freed = 0,
        };
    }
    
    pub fn deinit(self: *TrackingAllocator) void {
        self.allocations.deinit();
    }
    
    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }
    
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            const addr = @intFromPtr(ptr);
            self.allocations.put(addr, len) catch {};
            self.total_allocated += len;
        }
        return result;
    }
    
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }
    
    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const addr = @intFromPtr(buf.ptr);
        if (self.allocations.fetchRemove(addr)) |kv| {
            self.total_freed += kv.value;
        }
        self.backing_allocator.rawFree(buf, buf_align, ret_addr);
    }
    
    pub fn report(self: *TrackingAllocator) void {
        std.debug.print("Memory Report:\n", .{});
        std.debug.print("  Total allocated: {d} bytes\n", .{self.total_allocated});
        std.debug.print("  Total freed: {d} bytes\n", .{self.total_freed});
        std.debug.print("  Outstanding: {d} bytes\n", .{self.total_allocated - self.total_freed});
        std.debug.print("  Active allocations: {d}\n", .{self.allocations.count()});
    }
};

test "transaction arena" {
    const allocator = std.testing.allocator;
    
    var arena = try TransactionArena.init(allocator, 4096);
    defer arena.deinit();
    
    const a = arena.allocator();
    const data1 = try a.alloc(u8, 100);
    const data2 = try a.alloc(u8, 200);
    
    try std.testing.expect(data1.len == 100);
    try std.testing.expect(data2.len == 200);
    
    arena.reset();
    
    // Can reuse after reset
    const data3 = try a.alloc(u8, 50);
    try std.testing.expect(data3.len == 50);
}
