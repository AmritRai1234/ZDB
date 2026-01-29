const std = @import("std");
const Allocator = std.mem.Allocator;

// Safe C bindings for LZ4
const c = @cImport({
    @cInclude("lz4.h");
    @cInclude("lz4hc.h");
});

pub const CompressionLevel = enum(i32) {
    fastest = 1,      // LZ4 fast mode
    fast = 3,         // LZ4 fast mode
    default = 9,      // LZ4 HC (high compression)
    best = 12,        // LZ4 HC max
    
    pub fn toInt(self: CompressionLevel) i32 {
        return @intFromEnum(self);
    }
};

/// Minimum size to compress
pub const MIN_COMPRESS_SIZE = 128;

/// Compress data using LZ4 (4-10x faster than zstd)
pub fn compress(
    allocator: Allocator,
    data: []const u8,
    level: CompressionLevel,
) ![]u8 {
    if (data.len < MIN_COMPRESS_SIZE) {
        return try allocator.dupe(u8, data);
    }
    
    // Get maximum compressed size
    const max_size = c.LZ4_compressBound(@intCast(data.len));
    if (max_size <= 0) return error.CompressionFailed;
    
    const compressed_buf = try allocator.alloc(u8, @intCast(max_size));
    errdefer allocator.free(compressed_buf);
    
    // Compress based on level
    const compressed_size = if (level.toInt() >= 9)
        // High compression mode
        c.LZ4_compress_HC(
            data.ptr,
            compressed_buf.ptr,
            @intCast(data.len),
            @intCast(max_size),
            level.toInt(),
        )
    else
        // Fast mode
        c.LZ4_compress_default(
            data.ptr,
            compressed_buf.ptr,
            @intCast(data.len),
            @intCast(max_size),
        );
    
    if (compressed_size <= 0) {
        allocator.free(compressed_buf);
        return error.CompressionFailed;
    }
    
    // Only use compression if it saves space
    if (compressed_size >= data.len) {
        allocator.free(compressed_buf);
        return try allocator.dupe(u8, data);
    }
    
    // Resize to actual size
    const result = try allocator.realloc(compressed_buf, @intCast(compressed_size));
    return result;
}

/// Decompress LZ4 data
pub fn decompress(
    allocator: Allocator,
    compressed_data: []const u8,
    original_size: usize,
) ![]u8 {
    if (compressed_data.len >= original_size) {
        // Data wasn't compressed
        return try allocator.dupe(u8, compressed_data);
    }
    
    const decompressed_buf = try allocator.alloc(u8, original_size);
    errdefer allocator.free(decompressed_buf);
    
    const decompressed_size = c.LZ4_decompress_safe(
        compressed_data.ptr,
        decompressed_buf.ptr,
        @intCast(compressed_data.len),
        @intCast(original_size),
    );
    
    if (decompressed_size < 0) {
        allocator.free(decompressed_buf);
        return error.DecompressionFailed;
    }
    
    if (decompressed_size != original_size) {
        allocator.free(decompressed_buf);
        return error.SizeMismatch;
    }
    
    return decompressed_buf;
}

/// Calculate compression ratio
pub fn compressionRatio(original_size: usize, compressed_size: usize) f32 {
    if (original_size == 0) return 1.0;
    return @as(f32, @floatFromInt(compressed_size)) / @as(f32, @floatFromInt(original_size));
}

test "lz4 compression round-trip" {
    const allocator = std.testing.allocator;
    
    const original = "Hello, World! " ** 100;
    
    const compressed = try compress(allocator, original, .default);
    defer allocator.free(compressed);
    
    // Should be compressed
    try std.testing.expect(compressed.len < original.len);
    
    const decompressed = try decompress(allocator, compressed, original.len);
    defer allocator.free(decompressed);
    
    try std.testing.expectEqualStrings(original, decompressed);
}

test "lz4 small data not compressed" {
    const allocator = std.testing.allocator;
    
    const small_data = "small";
    const result = try compress(allocator, small_data, .default);
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings(small_data, result);
}
