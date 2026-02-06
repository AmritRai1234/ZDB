//! Thread-local arena allocator for zero-overhead allocations
//! Provides bump allocation with O(1) reset

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Arena allocator - bump allocation with mass free
pub const Arena = struct {
    buffer: []u8,
    offset: usize,
    allocator: Allocator,
    owns_buffer: bool,

    const ALIGNMENT: usize = 16;

    /// Create arena with given size
    pub fn init(allocator: Allocator, size: usize) !Arena {
        const buffer = try allocator.alignedAlloc(u8, ALIGNMENT, size);
        return .{
            .buffer = buffer,
            .offset = 0,
            .allocator = allocator,
            .owns_buffer = true,
        };
    }

    /// Create arena from existing buffer
    pub fn initFromBuffer(buffer: []u8) Arena {
        return .{
            .buffer = buffer,
            .offset = 0,
            .allocator = undefined,
            .owns_buffer = false,
        };
    }

    pub fn deinit(self: *Arena) void {
        if (self.owns_buffer) {
            self.allocator.free(self.buffer);
        }
    }

    /// Allocate from arena - O(1), no syscall
    pub fn alloc(self: *Arena, comptime T: type, count: usize) ![]T {
        const byte_count = @sizeOf(T) * count;
        const aligned_offset = std.mem.alignForward(usize, self.offset, @alignOf(T));

        if (aligned_offset + byte_count > self.buffer.len) {
            return error.OutOfMemory;
        }

        const ptr: [*]T = @ptrCast(@alignCast(self.buffer.ptr + aligned_offset));
        self.offset = aligned_offset + byte_count;

        return ptr[0..count];
    }

    /// Allocate bytes
    pub fn allocBytes(self: *Arena, size: usize) ![]u8 {
        return self.alloc(u8, size);
    }

    /// Reset arena - O(1) mass deallocation
    pub fn reset(self: *Arena) void {
        self.offset = 0;
    }

    /// Get remaining capacity
    pub fn remaining(self: *const Arena) usize {
        return self.buffer.len - self.offset;
    }

    /// Get usage
    pub fn used(self: *const Arena) usize {
        return self.offset;
    }

    /// Create std.mem.Allocator interface
    pub fn asAllocator(self: *Arena) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = arenaAlloc,
                .resize = arenaResize,
                .free = arenaFree,
            },
        };
    }

    fn arenaAlloc(ctx: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const aligned_offset = std.mem.alignForward(usize, self.offset, @as(usize, 1) << @intCast(ptr_align));

        if (aligned_offset + len > self.buffer.len) {
            return null;
        }

        const ptr = self.buffer.ptr + aligned_offset;
        self.offset = aligned_offset + len;
        return ptr;
    }

    fn arenaResize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        // Arena doesn't support resize
        return false;
    }

    fn arenaFree(_: *anyopaque, _: []u8, _: u8, _: usize) void {
        // Arena doesn't free individual allocations
    }
};

/// Thread-local arena pool
pub const ArenaPool = struct {
    arenas: []Arena,
    sizes: []usize,
    allocator: Allocator,

    const ARENA_SIZE: usize = 1024 * 1024; // 1MB per arena
    const MAX_ARENAS: usize = 16;

    pub fn init(allocator: Allocator) !ArenaPool {
        const arenas = try allocator.alloc(Arena, MAX_ARENAS);
        const sizes = try allocator.alloc(usize, MAX_ARENAS);

        for (arenas, sizes) |*arena, *size| {
            arena.* = try Arena.init(allocator, ARENA_SIZE);
            size.* = ARENA_SIZE;
        }

        return .{
            .arenas = arenas,
            .sizes = sizes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArenaPool) void {
        for (self.arenas) |*arena| {
            arena.deinit();
        }
        self.allocator.free(self.arenas);
        self.allocator.free(self.sizes);
    }

    /// Get arena for current thread
    pub fn getThreadArena(self: *ArenaPool) *Arena {
        // Simple round-robin based on thread ID
        const tid = std.Thread.getCurrentId();
        const idx = @as(usize, @intCast(tid)) % self.arenas.len;
        return &self.arenas[idx];
    }

    /// Reset all arenas
    pub fn resetAll(self: *ArenaPool) void {
        for (self.arenas) |*arena| {
            arena.reset();
        }
    }
};

/// Scratch allocator - temporary allocations that reset after scope
pub fn ScratchAllocator(comptime size: usize) type {
    return struct {
        buffer: [size]u8 = undefined,
        offset: usize = 0,

        const Self = @This();

        pub fn alloc(self: *Self, T: type, count: usize) ![]T {
            const byte_count = @sizeOf(T) * count;
            const aligned_offset = std.mem.alignForward(usize, self.offset, @alignOf(T));

            if (aligned_offset + byte_count > size) {
                return error.OutOfMemory;
            }

            const ptr: [*]T = @ptrCast(@alignCast(&self.buffer[aligned_offset]));
            self.offset = aligned_offset + byte_count;

            return ptr[0..count];
        }

        pub fn reset(self: *Self) void {
            self.offset = 0;
        }
    };
}

// Tests
test "arena basic allocation" {
    const allocator = std.testing.allocator;

    var arena = try Arena.init(allocator, 4096);
    defer arena.deinit();

    // Allocate some data
    const data1 = try arena.alloc(u64, 10);
    try std.testing.expectEqual(@as(usize, 10), data1.len);

    const data2 = try arena.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), data2.len);

    try std.testing.expect(arena.used() > 0);

    // Reset
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
}

test "arena allocator interface" {
    const base_allocator = std.testing.allocator;

    var arena = try Arena.init(base_allocator, 4096);
    defer arena.deinit();

    var allocator = arena.asAllocator();

    // Use as standard allocator
    const data = try allocator.alloc(u8, 256);
    try std.testing.expectEqual(@as(usize, 256), data.len);

    // Free is no-op
    allocator.free(data);
}

test "scratch allocator" {
    var scratch = ScratchAllocator(1024){};

    const data1 = try scratch.alloc(u32, 10);
    try std.testing.expectEqual(@as(usize, 10), data1.len);

    const data2 = try scratch.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), data2.len);

    scratch.reset();

    // Can reuse after reset
    const data3 = try scratch.alloc(u64, 100);
    try std.testing.expectEqual(@as(usize, 100), data3.len);
}
