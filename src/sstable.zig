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
        entries: []IndexEntry,
        allocator: Allocator,
        
        const IndexEntry = struct {
            key: []const u8,
            offset: u64,
        };
        
        fn init(allocator: Allocator) SparseIndex {
            return .{
                .entries = &[_]IndexEntry{},
                .allocator = allocator,
            };
        }
        
        fn deinit(self: *SparseIndex) void {
            for (self.entries) |entry| {
                self.allocator.free(entry.key);
            }
            self.allocator.free(self.entries);
        }
        
        fn add(self: *SparseIndex, key: []const u8, offset: u64) !void {
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            
            const new_entries = try self.allocator.realloc(self.entries, self.entries.len + 1);
            self.entries = new_entries;
            self.entries[self.entries.len - 1] = .{
                .key = key_copy,
                .offset = offset,
            };
        }
        
        /// Find the block that might contain the key
        fn findBlock(self: *const SparseIndex, key: []const u8) ?u64 {
            if (self.entries.len == 0) return null;
            
            // Binary search for the largest key <= target
            var left: usize = 0;
            var right: usize = self.entries.len;
            
            while (left < right) {
                const mid = left + (right - left) / 2;
                const cmp = std.mem.order(u8, self.entries[mid].key, key);
                
                if (cmp == .lt) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            
            if (left == 0) return self.entries[0].offset;
            return self.entries[left - 1].offset;
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
        
        // TODO: Read index entries
        
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
        
        // TODO: Read and search the block
        _ = block_offset;
        
        return null;
    }
    
    /// Scan range [start, end)
    pub fn scan(self: *SSTable, start: []const u8, end: []const u8) Iterator {
        return Iterator{
            .sstable = self,
            .start = start,
            .end = end,
            .current_offset = 0,
        };
    }
    
    pub const Iterator = struct {
        sstable: *SSTable,
        start: []const u8,
        end: []const u8,
        current_offset: u64,
        
        pub fn next(self: *Iterator) ?KV {
            // TODO: Implement iteration
            _ = self;
            return null;
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
            .entries = std.ArrayList(Entry).init(allocator),
            .bloom_filter = bloom_filter,
        };
    }
    
    pub fn deinit(self: *SSTableWriter) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit();
        self.bloom_filter.deinit();
        self.file.close();
    }
    
    pub fn add(self: *SSTableWriter, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        
        try self.entries.append(.{
            .key = key_copy,
            .value = value_copy,
        });
        
        self.bloom_filter.add(key);
    }
    
    pub fn finish(self: *SSTableWriter) !void {
        // Sort entries by key
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lessThan);
        
        // Write data blocks
        // TODO: Implement block writing
        
        // Write sparse index
        const index_offset = try self.file.getPos();
        // TODO: Write index
        
        // Write bloom filter
        const bloom_offset = try self.file.getPos();
        try self.bloom_filter.serialize(self.file.writer());
        
        // Write header
        const header = SSTable.Header{
            .magic = SSTable.Header.MAGIC,
            .version = SSTable.Header.VERSION,
            .key_count = self.entries.items.len,
            .data_blocks_count = 0, // TODO
            .index_offset = index_offset,
            .bloom_offset = bloom_offset,
            .compression_type = 0,
            .reserved = [_]u8{0} ** 19,
        };
        
        try self.file.seekTo(0);
        try header.serialize(self.file.writer());
    }
};
