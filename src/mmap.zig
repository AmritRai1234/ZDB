const std = @import("std");
const Allocator = std.mem.Allocator;

/// Memory-mapped file for zero-copy I/O
/// Uses mmap for fast, OS-managed page cache access
pub const MmapFile = struct {
    fd: std.posix.fd_t,
    ptr: [*]align(std.mem.page_size) u8,
    size: usize,
    
    pub fn init(path: []const u8, size: usize) !MmapFile {
        // Open file
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        errdefer std.posix.close(fd);
        
        // Set file size
        try std.posix.ftruncate(fd, @intCast(size));
        
        // Memory map the file
        const ptr = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        
        // Advise kernel about access pattern
        std.posix.madvise(ptr, size, std.posix.MADV.RANDOM) catch {};
        
        return .{
            .fd = fd,
            .ptr = ptr.ptr,
            .size = size,
        };
    }
    
    pub fn deinit(self: *MmapFile) void {
        std.posix.munmap(@alignCast(self.ptr[0..self.size]));
        std.posix.close(self.fd);
    }
    
    /// Get slice at offset (zero-copy!)
    pub fn get(self: *MmapFile, offset: usize, len: usize) []u8 {
        std.debug.assert(offset + len <= self.size);
        return self.ptr[offset .. offset + len];
    }
    
    /// Write data at offset (zero-copy!)
    pub fn write(self: *MmapFile, offset: usize, data: []const u8) void {
        std.debug.assert(offset + data.len <= self.size);
        @memcpy(self.ptr[offset..][0..data.len], data);
    }
    
    /// Sync to disk
    pub fn sync(self: *MmapFile) !void {
        try std.posix.msync(@alignCast(self.ptr[0..self.size]), std.posix.MSF.SYNC);
    }
    
    /// Prefetch range (hint to OS)
    pub fn prefetch(self: *MmapFile, offset: usize, len: usize) void {
        std.posix.madvise(
            self.ptr[offset .. offset + len],
            len,
            std.posix.MADV.WILLNEED,
        ) catch {};
    }
    
    /// Sequential access hint
    pub fn sequential(self: *MmapFile) void {
        std.posix.madvise(
            self.ptr[0..self.size],
            self.size,
            std.posix.MADV.SEQUENTIAL,
        ) catch {};
    }
    
    /// Random access hint
    pub fn random(self: *MmapFile) void {
        std.posix.madvise(
            self.ptr[0..self.size],
            self.size,
            std.posix.MADV.RANDOM,
        ) catch {};
    }
};

test "mmap basic operations" {
    const allocator = std.testing.allocator;
    _ = allocator;
    
    var mmap = try MmapFile.init("test_mmap.db", 1024 * 1024);
    defer mmap.deinit();
    defer std.fs.cwd().deleteFile("test_mmap.db") catch {};
    
    // Write data
    const data = "Hello, mmap!";
    mmap.write(0, data);
    
    // Read back (zero-copy!)
    const retrieved = mmap.get(0, data.len);
    try std.testing.expect(std.mem.eql(u8, retrieved, data));
}

test "mmap prefetch" {
    var mmap = try MmapFile.init("test_prefetch.db", 1024 * 1024);
    defer mmap.deinit();
    defer std.fs.cwd().deleteFile("test_prefetch.db") catch {};
    
    // Prefetch range
    mmap.prefetch(0, 4096);
    
    // Access should be faster (OS has prefetched)
    const data = mmap.get(0, 100);
    try std.testing.expect(data.len == 100);
}
