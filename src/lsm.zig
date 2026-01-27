const std = @import("std");
const Allocator = std.mem.Allocator;
const SkipList = @import("skiplist.zig").SkipList;
const SSTable = @import("sstable.zig").SSTable;
const BloomFilter = @import("bloom.zig").BloomFilter;

/// LSM-Tree - Log-Structured Merge-Tree for high-performance writes
/// Writes go to in-memory memtable, flush to sorted SSTables on disk
pub const LSMTree = struct {
    allocator: Allocator,
    memtable: SkipList([]const u8, []const u8),
    immutable_memtable: ?SkipList([]const u8, []const u8),
    sstables: std.ArrayList(SSTable),
    data_dir: []const u8,
    next_sst_id: usize,
    mutex: std.Thread.Mutex,
    
    // Configuration
    memtable_size_limit: usize,
    
    // Statistics
    total_writes: usize,
    total_reads: usize,
    memtable_flushes: usize,
    
    const MEMTABLE_SIZE = 4 * 1024 * 1024; // 4MB
    
    pub fn init(allocator: Allocator, data_dir: []const u8) !LSMTree {
        // Create data directory if it doesn't exist
        std.fs.cwd().makeDir(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        return .{
            .allocator = allocator,
            .memtable = try SkipList([]const u8, []const u8).init(allocator),
            .immutable_memtable = null,
            .sstables = std.ArrayList(SSTable).init(allocator),
            .data_dir = data_dir,
            .next_sst_id = 0,
            .mutex = .{},
            .memtable_size_limit = MEMTABLE_SIZE,
            .total_writes = 0,
            .total_reads = 0,
            .memtable_flushes = 0,
        };
    }
    
    pub fn deinit(self: *LSMTree) void {
        self.memtable.deinit();
        if (self.immutable_memtable) |*imm| {
            imm.deinit();
        }
        for (self.sstables.items) |*sst| {
            sst.deinit();
        }
        self.sstables.deinit();
    }
    
    /// Put key-value pair (writes to memtable)
    pub fn put(self: *LSMTree, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if memtable is full
        if (self.memtable.size() >= self.memtable_size_limit) {
            try self.flushMemtable();
        }
        
        // Write to memtable (pure memory, super fast!)
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.memtable.insert(key_copy, value_copy);
        
        self.total_writes += 1;
    }
    
    /// Get value for key
    pub fn get(self: *LSMTree, key: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.total_reads += 1;
        
        // Check memtable first (fastest)
        if (self.memtable.get(key)) |value| {
            return try self.allocator.dupe(u8, value);
        }
        
        // Check immutable memtable
        if (self.immutable_memtable) |*imm| {
            if (imm.get(key)) |value| {
                return try self.allocator.dupe(u8, value);
            }
        }
        
        // Check SSTables (newest first, use bloom filters)
        var i: usize = self.sstables.items.len;
        while (i > 0) {
            i -= 1;
            if (try self.sstables.items[i].get(key)) |value| {
                return value; // SSTable.get already allocates
            }
        }
        
        return null;
    }
    
    /// Flush memtable to SSTable on disk
    fn flushMemtable(self: *LSMTree) !void {
        // Move current memtable to immutable
        if (self.immutable_memtable != null) {
            // Wait for previous flush to complete
            // In production, this would be async
            return error.FlushInProgress;
        }
        
        self.immutable_memtable = self.memtable;
        self.memtable = try SkipList([]const u8, []const u8).init(self.allocator);
        
        // Collect entries from immutable memtable
        var entries = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(self.allocator);
        defer entries.deinit();
        
        var iter = self.immutable_memtable.?.iterator();
        while (iter.next()) |entry| {
            try entries.append(.{ .key = entry.key, .value = entry.value });
        }
        
        // Create SSTable file
        var path_buf: [256]u8 = undefined;
        const sst_path = try std.fmt.bufPrint(&path_buf, "{s}/sst_{d}.db", .{ self.data_dir, self.next_sst_id });
        self.next_sst_id += 1;
        
        // Write SSTable
        const sst = try SSTable.create(self.allocator, sst_path, entries.items);
        try self.sstables.append(sst);
        
        // Clean up immutable memtable
        self.immutable_memtable.?.deinit();
        self.immutable_memtable = null;
        
        self.memtable_flushes += 1;
    }
    
    /// Force flush current memtable
    pub fn flush(self: *LSMTree) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.memtable.len() > 0) {
            try self.flushMemtable();
        }
    }
    
    /// Get statistics
    pub fn stats(self: *LSMTree) Stats {
        return .{
            .total_writes = self.total_writes,
            .total_reads = self.total_reads,
            .memtable_flushes = self.memtable_flushes,
            .memtable_size = self.memtable.size(),
            .num_sstables = self.sstables.items.len,
        };
    }
    
    pub const Stats = struct {
        total_writes: usize,
        total_reads: usize,
        memtable_flushes: usize,
        memtable_size: usize,
        num_sstables: usize,
    };
};

test "lsm basic operations" {
    const allocator = std.testing.allocator;
    
    var lsm = try LSMTree.init(allocator, "test_lsm_data");
    defer lsm.deinit();
    defer std.fs.cwd().deleteTree("test_lsm_data") catch {};
    
    // Write some data
    try lsm.put("key1", "value1");
    try lsm.put("key2", "value2");
    try lsm.put("key3", "value3");
    
    // Read back
    const val1 = try lsm.get("key1");
    defer if (val1) |v| allocator.free(v);
    try std.testing.expect(std.mem.eql(u8, val1.?, "value1"));
    
    const val2 = try lsm.get("key2");
    defer if (val2) |v| allocator.free(v);
    try std.testing.expect(std.mem.eql(u8, val2.?, "value2"));
    
    // Check stats
    const s = lsm.stats();
    try std.testing.expect(s.total_writes == 3);
    try std.testing.expect(s.total_reads == 2);
}

test "lsm memtable flush" {
    const allocator = std.testing.allocator;
    
    var lsm = try LSMTree.init(allocator, "test_lsm_flush");
    defer lsm.deinit();
    defer std.fs.cwd().deleteTree("test_lsm_flush") catch {};
    
    // Write enough data to trigger flush
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        var val_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        const val = try std.fmt.bufPrint(&val_buf, "value_{d}", .{i});
        try lsm.put(key, val);
    }
    
    // Force flush
    try lsm.flush();
    
    // Verify data is still readable
    const val = try lsm.get("key_500");
    defer if (val) |v| allocator.free(v);
    try std.testing.expect(std.mem.eql(u8, val.?, "value_500"));
    
    // Check that SSTable was created
    const s = lsm.stats();
    try std.testing.expect(s.num_sstables >= 1);
}
