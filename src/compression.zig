const std = @import("std");
const Allocator = std.mem.Allocator;

/// Simplified compression for ZMDB (zstd API changed in Zig 0.15)
/// This is a placeholder - full zstd integration requires more work

pub const CompressionLevel = enum(i32) {
    fastest = 1,
    fast = 3,
    default = 6,
    best = 9,
    
    pub fn toInt(self: CompressionLevel) i32 {
        return @intFromEnum(self);
    }
};

/// Minimum size to compress (avoid overhead for small values)
pub const MIN_COMPRESS_SIZE = 256;

/// Simple run-length encoding for demonstration
/// In production, integrate proper zstd when API stabilizes
pub fn compress(
    allocator: Allocator,
    data: []const u8,
    level: CompressionLevel,
) ![]u8 {
    _ = level;
    
    if (data.len < MIN_COMPRESS_SIZE) {
        // Too small to benefit from compression
        return try allocator.dupe(u8, data);
    }
    
    // For now, just duplicate (placeholder for real compression)
    // TODO: Integrate zstd when API stabilizes in Zig
    return try allocator.dupe(u8, data);
}

/// Decompress data
pub fn decompress(
    allocator: Allocator,
    compressed_data: []const u8,
    original_size: usize,
) ![]u8 {
    _ = original_size;
    
    // Placeholder: just duplicate
    return try allocator.dupe(u8, compressed_data);
}

/// Calculate compression ratio (0.0 to 1.0, lower is better)
pub fn compressionRatio(original_size: usize, compressed_size: usize) f32 {
    if (original_size == 0) return 1.0;
    return @as(f32, @floatFromInt(compressed_size)) / @as(f32, @floatFromInt(original_size));
}

test "compression round-trip" {
    const allocator = std.testing.allocator;
    
    const original = "Hello, World! " ** 100;
    
    const compressed = try compress(allocator, original, .default);
    defer allocator.free(compressed);
    
    const decompressed = try decompress(allocator, compressed, original.len);
    defer allocator.free(decompressed);
    
    try std.testing.expectEqualStrings(original, decompressed);
}

test "small data not compressed" {
    const allocator = std.testing.allocator;
    
    const small_data = "small";
    const result = try compress(allocator, small_data, .default);
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings(small_data, result);
}
