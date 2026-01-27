const std = @import("std");
const Allocator = std.mem.Allocator;
const BloomFilter = @import("bloom.zig").BloomFilter;
const compress = @import("compression.zig").compress;
const decompress = @import("compression.zig").decompress;

/// SSTable (Sorted String Table) - Immutable sorted on-disk data structure
/// Block-based format for efficient reads and compression
pub const SSTable = struct {
    file: std.fs.File,
    index: Index,
    bloom: BloomFilter,
    allocator: Allocator,
    
    const BLOCK_SIZE = 16 * 1024; // 16KB blocks
    const MAGIC = 0x5354424C; // "STBL"
    
    /// Block index for fast lookups
    const Index = struct {
        entries: []IndexEntry,
        allocator: Allocator,
        
        const IndexEntry = struct {
            first_key: []const u8,
            offset: u64,
            size: u32,
        };
        
        pub fn deinit(self: *Index) void {
            for (self.entries) |entry| {
                self.allocator.free(entry.first_key);
            }
            self.allocator.free(self.entries);
        }
        
        pub fn findBlock(self: *Index, key: []const u8) ?IndexEntry {
            // Binary search for block containing key
            var left: usize = 0;
            var right: usize = self.entries.len;
            
            while (left < right) {
                const mid = left + (right - left) / 2;
                const cmp = std.mem.order(u8, key, self.entries[mid].first_key);
                
                if (cmp == .lt) {
                    right = mid;
                } else if (cmp == .gt) {
                    left = mid + 1;
                } else {
                    return self.entries[mid];
                }
            }
            
            if (left > 0) {
                return self.entries[left - 1];
            }
            return null;
        }
    };
    
    /// Create SSTable from sorted key-value pairs
    pub fn create(
        allocator: Allocator,
        path: []const u8,
        entries: []const struct { key: []const u8, value: []const u8 },
    ) !SSTable {
        const file = try std.fs.cwd().createFile(path, .{ .read = true });
        errdefer file.close();
        
        var index_entries = std.ArrayList(Index.IndexEntry).init(allocator);
        errdefer index_entries.deinit();
        
        // Create bloom filter
        var bloom = try BloomFilter.init(allocator, entries.len, 10);
        errdefer bloom.deinit();
        
        var current_block = std.ArrayList(u8).init(allocator);
        defer current_block.deinit();
        
        var offset: u64 = @sizeOf(u32); // Skip magic number
        var first_key_in_block: ?[]const u8 = null;
        
        for (entries) |entry| {
            // Add to bloom filter
            bloom.insert(entry.key);
            
            // Serialize entry: key_len(u32) + key + value_len(u32) + value
            const entry_size = @sizeOf(u32) + entry.key.len + @sizeOf(u32) + entry.value.len;
            
            // Start new block if current is full
            if (current_block.items.len + entry_size > BLOCK_SIZE and current_block.items.len > 0) {
                // Write block
                const compressed = try compress(allocator, current_block.items, .default);
                defer allocator.free(compressed);
                
                _ = try file.write(compressed);
                
                // Add index entry
                try index_entries.append(.{
                    .first_key = try allocator.dupe(u8, first_key_in_block.?),
                    .offset = offset,
                    .size = @intCast(compressed.len),
                });
                
                offset += compressed.len;
                current_block.clearRetainingCapacity();
                first_key_in_block = null;
            }
            
            // Track first key in block
            if (first_key_in_block == null) {
                first_key_in_block = entry.key;
            }
            
            // Write entry to block
            const key_len: u32 = @intCast(entry.key.len);
            const value_len: u32 = @intCast(entry.value.len);
            
            try current_block.writer().writeInt(u32, key_len, .little);
            try current_block.appendSlice(entry.key);
            try current_block.writer().writeInt(u32, value_len, .little);
            try current_block.appendSlice(entry.value);
        }
        
        // Write final block
        if (current_block.items.len > 0) {
            const compressed = try compress(allocator, current_block.items, .default);
            defer allocator.free(compressed);
            
            _ = try file.write(compressed);
            
            try index_entries.append(.{
                .first_key = try allocator.dupe(u8, first_key_in_block.?),
                .offset = offset,
                .size = @intCast(compressed.len),
            });
        }
        
        // Write magic number at start
        try file.seekTo(0);
        try file.writer().writeInt(u32, MAGIC, .little);
        
        return .{
            .file = file,
            .index = .{
                .entries = try index_entries.toOwnedSlice(),
                .allocator = allocator,
            },
            .bloom = bloom,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *SSTable) void {
        self.index.deinit();
        self.bloom.deinit();
        self.file.close();
    }
    
    /// Get value for key (returns null if not found)
    pub fn get(self: *SSTable, key: []const u8) !?[]u8 {
        // Check bloom filter first
        if (!self.bloom.mightContain(key)) {
            return null; // Definitely not present
        }
        
        // Find block
        const block_entry = self.index.findBlock(key) orelse return null;
        
        // Read and decompress block
        try self.file.seekTo(block_entry.offset);
        const compressed = try self.allocator.alloc(u8, block_entry.size);
        defer self.allocator.free(compressed);
        
        _ = try self.file.read(compressed);
        const block_data = try decompress(self.allocator, compressed);
        defer self.allocator.free(block_data);
        
        // Search within block
        var offset: usize = 0;
        while (offset < block_data.len) {
            const key_len = std.mem.readInt(u32, block_data[offset..][0..4], .little);
            offset += 4;
            
            const entry_key = block_data[offset..offset + key_len];
            offset += key_len;
            
            const value_len = std.mem.readInt(u32, block_data[offset..][0..4], .little);
            offset += 4;
            
            const entry_value = block_data[offset..offset + value_len];
            offset += value_len;
            
            if (std.mem.eql(u8, entry_key, key)) {
                return try self.allocator.dupe(u8, entry_value);
            }
        }
        
        return null;
    }
};

test "sstable create and read" {
    const allocator = std.testing.allocator;
    
    const entries = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "key1", .value = "value1" },
        .{ .key = "key2", .value = "value2" },
        .{ .key = "key3", .value = "value3" },
    };
    
    var sst = try SSTable.create(allocator, "test.sst", &entries);
    defer sst.deinit();
    defer std.fs.cwd().deleteFile("test.sst") catch {};
    
    const val1 = try sst.get("key1");
    defer if (val1) |v| allocator.free(v);
    try std.testing.expect(std.mem.eql(u8, val1.?, "value1"));
    
    const val2 = try sst.get("key2");
    defer if (val2) |v| allocator.free(v);
    try std.testing.expect(std.mem.eql(u8, val2.?, "value2"));
    
    const val_missing = try sst.get("key999");
    try std.testing.expect(val_missing == null);
}
