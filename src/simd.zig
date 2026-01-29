const std = @import("std");

/// SIMD-accelerated operations for ARM NEON and x86 SSE
/// Provides vectorized key comparison and hashing

/// Compare two byte slices using SIMD vectorization
pub fn compareKeys(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    
    var i: usize = 0;
    
    // Process 16 bytes at a time with vector operations
    while (i + 16 <= a.len) : (i += 16) {
        const va: @Vector(16, u8) = a[i..][0..16].*;
        const vb: @Vector(16, u8) = b[i..][0..16].*;
        
        const cmp = va == vb;
        if (@reduce(.And, cmp) == false) return false;
    }
    
    // Handle remaining bytes
    return std.mem.eql(u8, a[i..], b[i..]);
}

/// Fast hash using SIMD for larger keys
pub fn hashKey(key: []const u8) u64 {
    if (key.len == 0) return 0;
    
    // For small keys, use standard hash
    if (key.len < 32) {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key);
        return hasher.final();
    }
    
    // SIMD-accelerated hashing for larger keys
    var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
    var i: usize = 0;
    
    // Process 32 bytes at a time with vectors
    while (i + 32 <= key.len) : (i += 32) {
        const v1: @Vector(16, u8) = key[i..][0..16].*;
        const v2: @Vector(16, u8) = key[i + 16..][0..16].*;
        
        // Reduce vectors to scalars and mix into hash
        const sum1 = @reduce(.Add, v1);
        const sum2 = @reduce(.Add, v2);
        
        hash ^= @as(u64, sum1);
        hash *%= 0x100000001b3; // FNV prime
        hash ^= @as(u64, sum2);
        hash *%= 0x100000001b3;
    }
    
    // Handle remaining bytes
    while (i < key.len) : (i += 1) {
        hash ^= key[i];
        hash *%= 0x100000001b3;
    }
    
    return hash;
}

/// Vectorized memory copy (faster than @memcpy for large buffers)
pub fn fastCopy(dest: []u8, src: []const u8) void {
    std.debug.assert(dest.len >= src.len);
    
    var i: usize = 0;
    
    // Copy 32 bytes at a time using vectors
    while (i + 32 <= src.len) : (i += 32) {
        const v1: @Vector(16, u8) = src[i..][0..16].*;
        const v2: @Vector(16, u8) = src[i + 16..][0..16].*;
        
        dest[i..][0..16].* = v1;
        dest[i + 16..][0..16].* = v2;
    }
    
    // Handle remainder
    @memcpy(dest[i..src.len], src[i..]);
}

/// Prefetch memory for next access (reduces latency)
pub inline fn prefetch(ptr: [*]const u8) void {
    const arch = @import("builtin").target.cpu.arch;
    
    switch (arch) {
        .aarch64 => {
            asm volatile ("prfm pldl1keep, [%[ptr], #64]"
                :
                : [ptr] "r" (ptr)
            );
        },
        .x86_64 => {
            asm volatile ("prefetcht0 64(%[ptr])"
                :
                : [ptr] "r" (ptr)
            );
        },
        else => {},
    }
}

test "SIMD key comparison" {
    const key1 = "hello_world_test_key_1234567890";
    const key2 = "hello_world_test_key_1234567890";
    const key3 = "hello_world_test_key_9876543210";
    
    try std.testing.expect(compareKeys(key1, key2) == true);
    try std.testing.expect(compareKeys(key1, key3) == false);
}

test "SIMD hash consistency" {
    const key = "test_key_for_hashing";
    const hash1 = hashKey(key);
    const hash2 = hashKey(key);
    
    try std.testing.expect(hash1 == hash2);
    try std.testing.expect(hash1 != 0);
}

/// Vectorized checksum computation (CRC32 alternative)
pub fn vectorizedChecksum(data: []const u8) u32 {
    if (data.len == 0) return 0;
    
    var checksum: u32 = 0xffffffff;
    var i: usize = 0;
    
    // Process 16 bytes at a time
    while (i + 16 <= data.len) : (i += 16) {
        const v: @Vector(16, u8) = data[i..][0..16].*;
        const sum = @reduce(.Add, v);
        checksum ^= @as(u32, sum);
        checksum = checksum *% 0x1EDC6F41; // Mix
    }
    
    // Handle remainder
    while (i < data.len) : (i += 1) {
        checksum ^= data[i];
        checksum = checksum *% 0x1EDC6F41;
    }
    
    return ~checksum;
}

test "vectorized copy" {
    var dest: [100]u8 = undefined;
    const src = "x" ** 100;
    
    fastCopy(&dest, src);
    try std.testing.expect(std.mem.eql(u8, &dest, src));
}

test "SIMD hash performance" {
    const key = "this_is_a_longer_key_for_simd_hashing_test_1234567890";
    const hash1 = hashKey(key);
    const hash2 = hashKey(key);
    
    try std.testing.expect(hash1 == hash2);
    try std.testing.expect(hash1 != 0);
}

test "vectorized checksum" {
    const data = "test data for checksum";
    const cs1 = vectorizedChecksum(data);
    const cs2 = vectorizedChecksum(data);
    
    try std.testing.expect(cs1 == cs2);
    try std.testing.expect(cs1 != 0);
}
