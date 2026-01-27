const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bloom Filter - Probabilistic data structure for set membership
pub const BloomFilter = struct {
    bits: []u8,
    num_hashes: usize,
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, expected_items: usize, bits_per_key: usize) !BloomFilter {
        const num_bits = expected_items * bits_per_key;
        const num_bytes = (num_bits + 7) / 8;
        const bits = try allocator.alloc(u8, num_bytes);
        @memset(bits, 0);
        
        const num_hashes = @max(1, (bits_per_key * 693) / 1000);
        
        return .{
            .bits = bits,
            .num_hashes = num_hashes,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bits);
    }
    
    pub fn insert(self: *BloomFilter, key: []const u8) void {
        var h = std.hash.Wyhash.init(0);
        h.update(key);
        const hash = h.final();
        
        for (0..self.num_hashes) |i| {
            const bit_index = (hash +% i *% rotateHash(hash)) % (self.bits.len * 8);
            self.bits[bit_index / 8] |= @as(u8, 1) << @intCast(bit_index % 8);
        }
    }
    
    pub fn mightContain(self: *BloomFilter, key: []const u8) bool {
        var h = std.hash.Wyhash.init(0);
        h.update(key);
        const hash = h.final();
        
        for (0..self.num_hashes) |i| {
            const bit_index = (hash +% i *% rotateHash(hash)) % (self.bits.len * 8);
            if ((self.bits[bit_index / 8] & (@as(u8, 1) << @intCast(bit_index % 8))) == 0) {
                return false;
            }
        }
        return true;
    }
    
    fn rotateHash(hash: u64) u64 {
        return (hash >> 32) | (hash << 32);
    }
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
