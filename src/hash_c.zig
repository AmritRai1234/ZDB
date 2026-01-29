const std = @import("std");

// C bindings for xxHash (ultra-fast hashing library)
const c = @cImport({
    @cInclude("xxhash.h");
});

/// Ultra-fast 64-bit hash using C xxHash library (10-20x faster than std.hash)
pub fn hash64(data: []const u8) u64 {
    return c.XXH64(data.ptr, data.len, 0);
}

/// Ultra-fast 64-bit hash with custom seed
pub fn hash64WithSeed(data: []const u8, seed: u64) u64 {
    return c.XXH64(data.ptr, data.len, seed);
}

/// Ultra-fast 32-bit hash
pub fn hash32(data: []const u8) u32 {
    return c.XXH32(data.ptr, data.len, 0);
}

test "xxhash basic" {
    const data = "Hello, World!";
    const h = hash64(data);
    try std.testing.expect(h != 0);
    
    // Same input should give same hash
    const h2 = hash64(data);
    try std.testing.expectEqual(h, h2);
}

test "xxhash different inputs" {
    const h1 = hash64("test1");
    const h2 = hash64("test2");
    try std.testing.expect(h1 != h2);
}
