const std = @import("std");
const Allocator = std.mem.Allocator;

/// Full zstd compression using C bindings
/// Provides better compression ratios than placeholder

// Import zstd C library
const c = @cImport({
    @cInclude("zstd.h");
});

pub const CompressionLevel = enum(i32) {
    fastest = 1,
    fast = 3,
    default = 6,
    best = 9,
    ultra = 19,
    
    pub fn toInt(self: CompressionLevel) i32 {
        return @intFromEnum(self);
    }
};

/// Minimum size to compress (avoid overhead for small values)
pub const MIN_COMPRESS_SIZE = 256;

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
    var compressed = try allocator.alloc(u8, max_size);
    errdefer allocator.free(compressed);
    
    // Compress using zstd
    const compressed_size = c.ZSTD_compress(
        compressed.ptr,
        compressed.len,
        data.ptr,
        data.len,
        level.toInt(),
    );
    
    // Check for errors
    if (c.ZSTD_isError(compressed_size) != 0) {
        allocator.free(compressed);
        return try allocator.dupe(u8, data); // Fallback to uncompressed
    }
    
    // Only use compression if it actually reduces size
    if (compressed_size >= data.len) {
        allocator.free(compressed);
        return try allocator.dupe(u8, data);
    }
    
    // Resize to actual compressed size
    return try allocator.realloc(compressed, compressed_size);
}

/// Decompress data using zstd
pub fn decompress(
    allocator: Allocator,
    compressed_data: []const u8,
    original_size: usize,
) ![]u8 {
    if (compressed_data.len >= original_size) {
        // Not compressed, return as-is
        return try allocator.dupe(u8, compressed_data);
    }
    
    var decompressed = try allocator.alloc(u8, original_size);
    errdefer allocator.free(decompressed);
    
    const decompressed_size = c.ZSTD_decompress(
        decompressed.ptr,
        decompressed.len,
        compressed_data.ptr,
        compressed_data.len,
    );
    
    if (c.ZSTD_isError(decompressed_size) != 0) {
        allocator.free(decompressed);
        return error.DecompressionFailed;
    }
    
    if (decompressed_size != original_size) {
        allocator.free(decompressed);
        return error.SizeMismatch;
    }
    
    return decompressed;
}

/// Streaming compressor for large data
pub const StreamCompressor = struct {
    ctx: *c.ZSTD_CCtx,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, level: CompressionLevel) !StreamCompressor {
        const ctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        _ = c.ZSTD_CCtx_setParameter(ctx, c.ZSTD_c_compressionLevel, level.toInt());
        
        return .{
            .ctx = ctx,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *StreamCompressor) void {
        _ = c.ZSTD_freeCCtx(self.ctx);
    }
    
    pub fn compress_chunk(self: *StreamCompressor, dst: []u8, src: []const u8) !usize {
        const result = c.ZSTD_compressStream2(
            self.ctx,
            &c.ZSTD_outBuffer{ .dst = dst.ptr, .size = dst.len, .pos = 0 },
            &c.ZSTD_inBuffer{ .src = src.ptr, .size = src.len, .pos = 0 },
            c.ZSTD_e_continue,
        );
        
        if (c.ZSTD_isError(result) != 0) {
            return error.CompressionFailed;
        }
        
        return result;
    }
};

/// Calculate compression ratio (0.0 to 1.0, lower is better)
pub fn compressionRatio(original_size: usize, compressed_size: usize) f32 {
    if (original_size == 0) return 1.0;
    return @as(f32, @floatFromInt(compressed_size)) / @as(f32, @floatFromInt(original_size));
}

/// Dictionary training for better compression on similar data
pub fn trainDictionary(
    allocator: Allocator,
    samples: []const []const u8,
    dict_size: usize,
) ![]u8 {
    // Concatenate all samples
    var total_size: usize = 0;
    for (samples) |sample| {
        total_size += sample.len;
    }
    
    var sample_data = try allocator.alloc(u8, total_size);
    defer allocator.free(sample_data);
    
    var offset: usize = 0;
    for (samples) |sample| {
        @memcpy(sample_data[offset..][0..sample.len], sample);
        offset += sample.len;
    }
    
    // Train dictionary
    var dict = try allocator.alloc(u8, dict_size);
    errdefer allocator.free(dict);
    
    const result = c.ZSTD_trainFromBuffer(
        dict.ptr,
        dict.len,
        sample_data.ptr,
        &[_]usize{sample_data.len},
        1,
    );
    
    if (c.ZSTD_isError(result) != 0) {
        allocator.free(dict);
        return error.DictionaryTrainingFailed;
    }
    
    return try allocator.realloc(dict, result);
}

test "zstd compression round-trip" {
    const allocator = std.testing.allocator;
    
    // Create compressible data
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
    
    // Should return uncompressed for small data
    try std.testing.expectEqualStrings(small_data, result);
}
