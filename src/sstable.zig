const std = @import("std");
const Allocator = std.mem.Allocator;
const fast = @import("fast.zig");
const bloom = @import("bloom.zig");

/// SSTable (Sorted String Table) - Immutable sorted key-value storage
/// Optimized for range queries and sequential access
pub const SSTable = struct {
    file: std.fs.File,
    mmap: ?fast.MappedFile,
    header: Header,
    index: SparseIndex,
    bloom_filter: ?bloom.BloomFilter,
    allocator: Allocator,
    
    const Header = struct {
        magic: u64, // "SSTABLE1"
        version: u32,
        key_count: u64,
        data_blocks_count: u32,
        index_offset: u64,
        bloom_offset: u64,
        compression_type: u8,
        reserved: [19]u8,
        
        const MAGIC = 0x31454C4241545353; // "SSTABLE1" in hex
        const VERSION = 1;
        const SIZE = 64;
        
        fn serialize(self: *const Header, writer: anytype) !void {
            try writer.writeInt(u64, self.magic, .little);
            try writer.writeInt(u32, self.version, .little);
            try writer.writeInt(u64, self.key_count, .little);
            try writer.writeInt(u32, self.data_blocks_count, .little);
            try writer.writeInt(u64, self.index_offset, .little);
            try writer.writeInt(u64, self.bloom_offset, .little);
            try writer.writeInt(u8, self.compression_type, .little);
            try writer.writeAll(&self.reserved);
        }
        
        fn deserialize(reader: anytype) !Header {
            const magic = try reader.readInt(u64, .little);
            if (magic != MAGIC) return error.InvalidMagic;
            
            const version = try reader.readInt(u32, .little);
            if (version != VERSION) return error.UnsupportedVersion;
            
            var header: Header = undefined;
            header.magic = magic;
            header.version = version;
            header.key_count = try reader.readInt(u64, .little);
            header.data_blocks_count = try reader.readInt(u32, .little);
            header.index_offset = try reader.readInt(u64, .little);
            header.bloom_offset = try reader.readInt(u64, .little);
            header.compression_type = try reader.readInt(u8, .little);
            try reader.readNoEof(&header.reserved);
            
            return header;
        }
    };
    
    const SparseIndex = struct {
        entries: std.ArrayList(IndexEntry),
        allocator: Allocator,
        
        const IndexEntry = struct {
            key: []const u8,
            offset: u64,
        };
        
        fn init(allocator: Allocator) SparseIndex {
            return .{
                .entries = std.ArrayList(IndexEntry){},
                .allocator = allocator,
            };
        }
        
        fn deinit(self: *SparseIndex) void {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.key);
            }
            self.entries.deinit(self.allocator);
        }
        
        fn add(self: *SparseIndex, key: []const u8, offset: u64) !void {
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            
            try self.entries.append(self.allocator, .{
                .key = key_copy,
                .offset = offset,
            });
        }
        
        /// Find the block that might contain the key
        fn findBlock(self: *const SparseIndex, key: []const u8) ?u64 {
            if (self.entries.items.len == 0) return null;
            
            // Binary search for the largest key <= target
            var left: usize = 0;
            var right: usize = self.entries.items.len;
            
            while (left < right) {
                const mid = left + (right - left) / 2;
                const cmp = std.mem.order(u8, self.entries.items[mid].key, key);
                
                if (cmp == .lt) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            
            if (left == 0) return self.entries.items[0].offset;
            return self.entries.items[left - 1].offset;
        }
    };
    
    pub fn init(allocator: Allocator, path: []const u8) !SSTable {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        
        // Read header
        var header_buf: [Header.SIZE]u8 = undefined;
        _ = try file.readAll(&header_buf);
        
        var stream = std.io.fixedBufferStream(&header_buf);
        const header = try Header.deserialize(stream.reader());
        
        // Memory-map the file
        const mmap_file = fast.MappedFile.init(file.handle) catch null;
        
        // Load sparse index
        try file.seekTo(header.index_offset);
        var index = SparseIndex.init(allocator);
        errdefer index.deinit();
        
        const num_index_entries = try file.reader().readInt(u64, .little);
        var i: usize = 0;
        while (i < num_index_entries) : (i += 1) {
            const key_len = try file.reader().readInt(u32, .little);
            const key = try allocator.alloc(u8, key_len);
            errdefer allocator.free(key);
            
            try file.reader().readNoEof(key);
            const offset = try file.reader().readInt(u64, .little);
            
            try index.entries.append(.{
                .key = key,
                .offset = offset,
            });
        }
        
        // Load bloom filter
        var bloom_filter: ?bloom.BloomFilter = null;
        if (header.bloom_offset > 0) {
            try file.seekTo(header.bloom_offset);
            bloom_filter = try bloom.BloomFilter.deserialize(allocator, file.reader());
        }
        
        return .{
            .file = file,
            .mmap = mmap_file,
            .header = header,
            .index = index,
            .bloom_filter = bloom_filter,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *SSTable) void {
        if (self.mmap) |*mmap| {
            mmap.deinit();
        }
        self.index.deinit();
        if (self.bloom_filter) |*bf| {
            bf.deinit();
        }
        self.file.close();
    }
    
    /// Get value for key (zero-copy if possible)
    pub fn get(self: *SSTable, key: []const u8) ?[]const u8 {
        // Check bloom filter first
        if (self.bloom_filter) |*bf| {
            if (!bf.mayContain(key)) {
                return null; // Definitely not in SSTable
            }
        }
        
        // Find the block that might contain the key
        const block_offset = self.index.findBlock(key) orelse return null;
        
        // Read and search the block
        if (self.mmap) |*mmap| {
            // Zero-copy read from mmap
            const BLOCK_SIZE = 4096;
            const block_data = mmap.read(block_offset, BLOCK_SIZE) orelse return null;
            
            // Search for key in block
            var offset: usize = 0;
            while (offset + 8 < block_data.len) {
                const key_len = std.mem.readInt(u32, block_data[offset..][0..4], .little);
                const value_len = std.mem.readInt(u32, block_data[offset + 4..][0..8], .little);
                offset += 8;
                
                if (offset + key_len + value_len > block_data.len) break;
                
                const entry_key = block_data[offset..offset + key_len];
                offset += key_len;
                
                const entry_value = block_data[offset..offset + value_len];
                offset += value_len;
                
                // Check if this is our key
                if (std.mem.eql(u8, entry_key, key)) {
                    return entry_value; // Zero-copy!
                }
                
                // Keys are sorted, so if we've passed our key, it's not here
                if (std.mem.order(u8, entry_key, key) == .gt) {
                    return null;
                }
            }
        }
        
        return null;
    }
    
    /// Scan range [start, end)
    pub fn scan(self: *SSTable, start: []const u8, end: []const u8) Iterator {
        // Find the block that might contain the start key
        const start_offset = self.index.findBlock(start) orelse SSTable.Header.SIZE;
        
        return Iterator{
            .sstable = self,
            .start = start,
            .end = end,
            .current_offset = start_offset,
            .current_block = null,
            .block_offset = 0,
            .finished = false,
        };
    }
    
    pub const Iterator = struct {
        sstable: *SSTable,
        start: []const u8,
        end: []const u8,
        current_offset: u64,
        current_block: ?[]const u8,
        block_offset: usize,
        finished: bool,
        
        pub fn next(self: *Iterator) ?KV {
            if (self.finished) return null;
            
            const mmap = &(self.sstable.mmap orelse return null);
            
            // Load next block if needed
            if (self.current_block == null) {
                const BLOCK_SIZE = 4096;
                const data = mmap.read(self.current_offset, BLOCK_SIZE) orelse {
                    self.finished = true;
                    return null;
                };
                self.current_block = data;
                self.block_offset = 0;
            }
            
            const block = self.current_block.?;
            
            // Parse entries in current block
            while (self.block_offset + 8 < block.len) {
                const key_len = std.mem.readInt(u32, block[self.block_offset..][0..4], .little);
                const value_len = std.mem.readInt(u32, block[self.block_offset + 4..][0..8], .little);
                self.block_offset += 8;
                
                if (self.block_offset + key_len + value_len > block.len) {
                    // Move to next block
                    self.current_offset += 4096;
                    self.current_block = null;
                    return self.next();
                }
                
                const key = block[self.block_offset..self.block_offset + key_len];
                self.block_offset += key_len;
                
                const value = block[self.block_offset..self.block_offset + value_len];
                self.block_offset += value_len;
                
                // Check if key is in range [start, end)
                const cmp_start = std.mem.order(u8, key, self.start);
                const cmp_end = std.mem.order(u8, key, self.end);
                
                if (cmp_start == .lt) continue; // Before range
                if (cmp_end != .lt) { // At or past end
                    self.finished = true;
                    return null;
                }
                
                // Key is in range!
                return KV{
                    .key = key,
                    .value = value,
                };
            }
            
            // End of block, move to next
            self.current_offset += 4096;
            self.current_block = null;
            return self.next();
        }
    };
    
    pub const KV = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// SSTable Writer - Builds sorted SSTables from key-value pairs
pub const SSTableWriter = struct {
    file: std.fs.File,
    allocator: Allocator,
    entries: std.ArrayList(Entry),
    bloom_filter: bloom.BloomFilter,
    
    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };
    
    pub fn init(allocator: Allocator, path: []const u8, expected_keys: usize) !SSTableWriter {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        
        // Reserve space for header
        try file.seekTo(SSTable.Header.SIZE);
        
        const bloom_filter = try bloom.BloomFilter.init(allocator, expected_keys, 10);
        
        return .{
            .file = file,
            .allocator = allocator,
            .entries = std.ArrayList(Entry){},
            .bloom_filter = bloom_filter,
        };
    }
    
    pub fn deinit(self: *SSTableWriter) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
        self.bloom_filter.deinit();
        self.file.close();
    }
    
    pub fn add(self: *SSTableWriter, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        
        try self.entries.append(self.allocator, .{
            .key = key_copy,
            .value = value_copy,
        });
        
        self.bloom_filter.insert(key);
    }
    
    pub fn finish(self: *SSTableWriter) !void {
        // Sort entries by key
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lessThan);
        
        // Write data blocks
        const BLOCK_SIZE = 4096; // 4KB blocks
        
        var sparse_index = SSTable.SparseIndex.init(self.allocator);
        defer sparse_index.deinit();
        
        var current_block = std.ArrayList(u8){};
        defer current_block.deinit(self.allocator);
        
        var block_count: u32 = 0;
        var entries_in_block: usize = 0;
        const SPARSE_INDEX_INTERVAL = 1000; // Index every 1000 keys
        
        for (self.entries.items, 0..) |entry, i| {
            // Calculate entry size: key_len(4) + value_len(4) + key + value
            const entry_size = 4 + 4 + entry.key.len + entry.value.len;
            
            // If adding this entry would exceed block size, flush current block
            if (current_block.items.len + entry_size > BLOCK_SIZE and current_block.items.len > 0) {
                try self.file.writeAll(current_block.items);
                current_block.clearRetainingCapacity();
                block_count += 1;
                entries_in_block = 0;
            }
            
            // Add to sparse index every N entries
            if (i % SPARSE_INDEX_INTERVAL == 0) {
                const offset = try self.file.getPos();
                try sparse_index.add(entry.key, offset);
            }
            
            // Write entry to current block
            var writer = current_block.writer(self.allocator);
            try writer.writeInt(u32, @intCast(entry.key.len), .little);
            try writer.writeInt(u32, @intCast(entry.value.len), .little);
            try writer.writeAll(entry.key);
            try writer.writeAll(entry.value);
            
            entries_in_block += 1;
        }
        
        // Flush last block
        if (current_block.items.len > 0) {
            try self.file.writeAll(current_block.items);
            block_count += 1;
        }
        
        // Write sparse index
        const index_offset = try self.file.getPos();
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, sparse_index.entries.items.len, .little);
        try self.file.writeAll(&buf);
        for (sparse_index.entries.items) |entry| {
            var key_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &key_len_buf, @intCast(entry.key.len), .little);
            try self.file.writeAll(&key_len_buf);
            try self.file.writeAll(entry.key);
            std.mem.writeInt(u64, &buf, entry.offset, .little);
            try self.file.writeAll(&buf);
        }
        
        // Write bloom filter
        const bloom_offset = try self.file.getPos();
        // Write bloom filter metadata
        var bloom_buf: [16]u8 = undefined;
        std.mem.writeInt(u64, bloom_buf[0..8], self.bloom_filter.num_bits, .little);
        std.mem.writeInt(u64, bloom_buf[8..16], self.bloom_filter.num_hashes, .little);
        try self.file.writeAll(&bloom_buf);
        // Write bloom filter data
        try self.file.writeAll(std.mem.sliceAsBytes(self.bloom_filter.blocks));
        
        // Write header
        const header = SSTable.Header{
            .magic = SSTable.Header.MAGIC,
            .version = SSTable.Header.VERSION,
            .key_count = self.entries.items.len,
            .data_blocks_count = block_count,
            .index_offset = index_offset,
            .bloom_offset = bloom_offset,
            .compression_type = 0,
            .reserved = [_]u8{0} ** 19,
        };
        
        try self.file.seekTo(0);
        try header.serialize(self.file.writer());
    }
};
