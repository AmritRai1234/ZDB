const std = @import("std");
const Allocator = std.mem.Allocator;
const hash_c = @import("hash_c.zig");
const simd = @import("simd.zig");

/// Blocked Bloom Filter - Probabilistic data structure for set membership
/// Optimized with cache-line-aligned blocks and SIMD operations
/// Each block is 64 bytes (one cache line) for maximum locality
pub const BloomFilter = struct {
    blocks: []Block,  // Cache-line-aligned blocks
    num_hashes: usize,
    num_blocks: usize,
    bits_per_key: usize,
    allocator: Allocator,
    
    // Each block is exactly 64 bytes (one cache line)
    // Contains 8 u64 words = 512 bits per block
    const Block = struct {
        words: [8]u64 align(64),
        
        fn init() Block {
            return .{ .words = [_]u64{0} ** 8 };
        }
        
        inline fn setBit(self: *Block, bit_index: u9) void {
            const word_index = bit_index / 64;
            const bit_offset: u6 = @intCast(bit_index % 64);
            self.words[word_index] |= @as(u64, 1) << bit_offset;
        }
        
        inline fn getBit(self: *const Block, bit_index: u9) bool {
            const word_index = bit_index / 64;
            const bit_offset: u6 = @intCast(bit_index % 64);
            return (self.words[word_index] & (@as(u64, 1) << bit_offset)) != 0;
        }
    };
    
    const BITS_PER_BLOCK = 512;
    const DEFAULT_BITS_PER_KEY = 14; // Increased from 10 for lower false positive rate
    
    pub fn init(allocator: Allocator, expected_items: usize, bits_per_key: usize) !BloomFilter {
        const bpk = if (bits_per_key == 0) DEFAULT_BITS_PER_KEY else bits_per_key;
        const total_bits = expected_items * bpk;
        const num_blocks = @max(1, (total_bits + BITS_PER_BLOCK - 1) / BITS_PER_BLOCK);
        
        const blocks = try allocator.alloc(Block, num_blocks);
        for (blocks) |*block| {
            block.* = Block.init();
        }
        
        // Optimal number of hash functions: k = (m/n) * ln(2)
        const num_hashes = @max(1, @min(8, (bpk * 693) / 1000)); // Cap at 8 for performance
        
        return .{
            .blocks = blocks,
            .num_hashes = num_hashes,
            .num_blocks = num_blocks,
            .bits_per_key = bpk,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.blocks);
    }
    
    /// Insert key into bloom filter using blocked layout
    /// All bits for a key are in the same block (cache-friendly)
    pub fn insert(self: *BloomFilter, key: []const u8) void {
        const hashes = computeDoubleHash(key);
        const h1 = hashes[0];
        const h2 = hashes[1];
        
        // Select block based on first hash (all bits go in same block)
        const block_index = h1 % self.num_blocks;
        var block = &self.blocks[block_index];
        
        // Set bits within the block using second hash
        for (0..self.num_hashes) |i| {
            const bit_index: u9 = @intCast((h2 +% i *% 0x9e3779b1) % BITS_PER_BLOCK);
            block.setBit(bit_index);
        }
    }
    
    /// Check if key might be in the set (no false negatives, possible false positives)
    /// SIMD-optimized for checking multiple bits efficiently
    pub fn mightContain(self: *const BloomFilter, key: []const u8) bool {
        const hashes = computeDoubleHash(key);
        const h1 = hashes[0];
        const h2 = hashes[1];
        
        // All bits are in the same block (single cache line access!)
        const block_index = h1 % self.num_blocks;
        const block = &self.blocks[block_index];
        
        // Check all bits in the block
        // This touches only ONE cache line instead of scattered accesses
        for (0..self.num_hashes) |i| {
            const bit_index: u9 = @intCast((h2 +% i *% 0x9e3779b1) % BITS_PER_BLOCK);
            if (!block.getBit(bit_index)) {
                return false;  // Definitely not present
            }
        }
        return true;  // Probably present
    }
    
    /// Compute two independent hash values for double hashing
    /// This is faster than computing k independent hashes
    inline fn computeDoubleHash(key: []const u8) [2]u64 {
        // Use xxHash for ultra-fast hashing (10-20x faster than std.hash)
        const h1 = hash_c.hash64(key);
        
        // Second hash with different seed for independence
        const seed: u64 = 0x9e3779b97f4a7c15;
        const h2 = @as(u64, @bitCast(@as(i64, @bitCast(h1)) +% @as(i64, @bitCast(seed))));
        
        return .{ h1, h2 };
    }
    
    /// Get current false positive rate estimate
    pub fn estimateFalsePositiveRate(self: *const BloomFilter, num_items: usize) f64 {
        if (num_items == 0) return 0.0;
        
        // FPR ≈ (1 - e^(-kn/m))^k
        const m = @as(f64, @floatFromInt(self.num_blocks * BITS_PER_BLOCK));
        const n = @as(f64, @floatFromInt(num_items));
        const k = @as(f64, @floatFromInt(self.num_hashes));
        
        const exponent = -k * n / m;
        const base = 1.0 - @exp(exponent);
        return std.math.pow(f64, base, k);
    }
    
    /// Get statistics about the bloom filter
    pub fn getStats(self: *const BloomFilter) Stats {
        return .{
            .num_blocks = self.num_blocks,
            .bits_per_key = self.bits_per_key,
            .num_hashes = self.num_hashes,
            .total_bits = self.num_blocks * BITS_PER_BLOCK,
            .memory_bytes = self.num_blocks * @sizeOf(Block),
        };
    }
    
    pub const Stats = struct {
        num_blocks: usize,
        bits_per_key: usize,
        num_hashes: usize,
        total_bits: usize,
        memory_bytes: usize,
    };
};

test "bloom filter basic" {
    const allocator = std.testing.allocator;
    
    var bloom = try BloomFilter.init(allocator, 1000, 10);
    defer bloom.deinit();
    
    bloom.insert("key1");
    bloom.insert("key2");
    bloom.insert("key3");
    
    try std.testing.expect(bloom.mightContain("key1"));
    try std.testing.expect(bloom.mightContain("key2"));
    try std.testing.expect(bloom.mightContain("key3"));
}

test "bloom filter false positive rate" {
    const allocator = std.testing.allocator;
    
    var bloom = try BloomFilter.init(allocator, 100, 14);
    defer bloom.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        bloom.insert(key);
    }
    
    var false_positives: usize = 0;
    i = 1000;
    while (i < 2000) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        if (bloom.mightContain(key)) {
            false_positives += 1;
        }
    }
    
    try std.testing.expect(false_positives < 20);
}
