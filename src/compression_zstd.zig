const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("zstd.h");
});

/// Compression using zstd library
/// Provides excellent compression ratios with fast decompression
pub const CompressionLevel = enum(i32) {
    fastest = 1,
    fast = 3,
    default = 6,
    best = 9,
    ultra = 19,  // Maximum compression for battery saver mode
    
    pub fn toInt(self: CompressionLevel) i32 {
        return @intFromEnum(self);
    }
};

/// Minimum size to compress (avoid overhead for small values)
pub const MIN_COMPRESS_SIZE = 128;  // Lowered from 256 for better compression

/// Compress data using zstd
pub fn compress(
    allocator: Allocator,
    data: []const u8,
    level: CompressionLevel,
) ![]u8 {
    if (data.len < MIN_COMPRESS_SIZE) {
        // Too small to benefit from compression
        return try allocator.dupe(u8, data);
    }
    
    // Get maximum compressed size
    const max_size = c.ZSTD_compressBound(data.len);
    const compressed_buf = try allocator.alloc(u8, max_size);
    errdefer allocator.free(compressed_buf);
    
    // Compress
    const compressed_size = c.ZSTD_compress(
        compressed_buf.ptr,
        max_size,
        data.ptr,
        data.len,
        level.toInt(),
    );
    
    // Check for errors
    if (c.ZSTD_isError(compressed_size) != 0) {
        allocator.free(compressed_buf);
        return error.CompressionFailed;
    }
    
    // Only use compression if it actually saves space
    if (compressed_size >= data.len) {
        allocator.free(compressed_buf);
        return try allocator.dupe(u8, data);
    }
    
    // Resize to actual compressed size
    const result = try allocator.realloc(compressed_buf, compressed_size);
    return result;
}

/// Decompress data using zstd
pub fn decompress(
    allocator: Allocator,
    compressed_data: []const u8,
    original_size: usize,
) ![]u8 {
    if (compressed_data.len >= original_size) {
        // Data wasn't actually compressed
        return try allocator.dupe(u8, compressed_data);
    }
    
    const decompressed_buf = try allocator.alloc(u8, original_size);
    errdefer allocator.free(decompressed_buf);
    
    const decompressed_size = c.ZSTD_decompress(
        decompressed_buf.ptr,
        original_size,
        compressed_data.ptr,
        compressed_data.len,
    );
    
    if (c.ZSTD_isError(decompressed_size) != 0) {
        allocator.free(decompressed_buf);
        return error.DecompressionFailed;
    }
    
    if (decompressed_size != original_size) {
        allocator.free(decompressed_buf);
        return error.SizeMismatch;
    }
    
    return decompressed_buf;
}

/// Calculate compression ratio (0.0 to 1.0, lower is better)
pub fn compressionRatio(original_size: usize, compressed_size: usize) f32 {
    if (original_size == 0) return 1.0;
    return @as(f32, @floatFromInt(compressed_size)) / @as(f32, @floatFromInt(original_size));
}

/// Get compression statistics
pub fn getCompressionStats(original_size: usize, compressed_size: usize) CompressionStats {
    const ratio = compressionRatio(original_size, compressed_size);
    const bytes_saved = if (compressed_size < original_size) 
        original_size - compressed_size 
    else 
        0;
    const savings_percent = if (original_size > 0)
        (@as(f32, @floatFromInt(bytes_saved)) / @as(f32, @floatFromInt(original_size))) * 100.0
    else
        0.0;
    
    return .{
        .original_size = original_size,
        .compressed_size = compressed_size,
        .ratio = ratio,
        .bytes_saved = bytes_saved,
        .savings_percent = savings_percent,
    };
}

pub const CompressionStats = struct {
    original_size: usize,
    compressed_size: usize,
    ratio: f32,
    bytes_saved: usize,
    savings_percent: f32,
};

test "compression round-trip" {
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

test "small data not compressed" {
    const allocator = std.testing.allocator;
    
    const small_data = "small";
    const result = try compress(allocator, small_data, .default);
    defer allocator.free(result);
    
    // Should not be compressed (too small)
    try std.testing.expectEqualStrings(small_data, result);
}

test "compression stats" {
    const stats = getCompressionStats(1000, 400);
    try std.testing.expect(stats.ratio == 0.4);
    try std.testing.expect(stats.bytes_saved == 600);
    try std.testing.expect(stats.savings_percent == 60.0);
}
