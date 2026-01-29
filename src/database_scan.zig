    /// Scan range [start, end) across all storage tiers
    pub fn scan(self: *Database, start: []const u8, end: []const u8) !ScanIterator {
        self.rwlock.lockShared();
        // Note: Iterator will unlock when done
        
        return ScanIterator{
            .db = self,
            .start = start,
            .end = end,
            .current_sstable = 0,
            .current_iter = null,
            .allocator = self.allocator,
        };
    }
    
    pub const ScanIterator = struct {
        db: *Database,
        start: []const u8,
        end: []const u8,
        current_sstable: usize,
        current_iter: ?sstable.SSTable.Iterator,
        allocator: Allocator,
        
        pub fn next(self: *ScanIterator) ?sstable.SSTable.KV {
            // Iterate through all SSTables
            while (self.current_sstable < self.db.sstables.items.len) {
                // Initialize iterator for current SSTable if needed
                if (self.current_iter == null) {
                    self.current_iter = self.db.sstables.items[self.current_sstable].scan(self.start, self.end);
                }
                
                // Get next from current iterator
                if (self.current_iter.?.next()) |kv| {
                    return kv;
                }
                
                // Move to next SSTable
                self.current_sstable += 1;
                self.current_iter = null;
            }
            
            return null;
        }
        
        pub fn deinit(self: *ScanIterator) void {
            self.db.rwlock.unlockShared();
        }
    };
    
    /// Flush WAL to SSTable (hot → warm migration)
    pub fn flushToSSTable(self: *Database) !void {
        self.rwlock.lock();
        defer self.rwlock.unlockShared();
        
        // Check if compaction is allowed
        if (!self.compactor.shouldCompact()) {
            return error.CompactionNotAllowed;
        }
        
        // Create SSTable from current WAL
        const sst_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.sst.{d}",
            .{ self.config.path, std.time.timestamp() }
        );
        defer self.allocator.free(sst_path);
        
        var writer = try sstable.SSTableWriter.init(self.allocator, sst_path, self.index.count());
        defer writer.deinit();
        
        // Iterate through all keys in index
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            // Read value from WAL
            const value = try self.get(entry.key, self.allocator);
            defer self.allocator.free(value);
            
            try writer.add(entry.key, value);
        }
        
        try writer.finish();
        
        // Load the new SSTable
        const new_sst = try sstable.SSTable.init(self.allocator, sst_path);
        try self.sstables.append(new_sst);
        
        // TODO: Clear WAL and index (would need to implement this carefully)
    }
    
    /// Trigger compaction if needed
    pub fn maybeCompact(self: *Database) !void {
        const total_size = blk: {
            var sum: u64 = 0;
            for (self.sstables.items) |*sst| {
                sum += sst.header.key_count * 128; // Rough estimate
            }
            break :blk sum;
        };
        
        if (self.compactor.needsCompaction(self.sstables.items.len, total_size)) {
            try self.compactSSTables();
        }
    }
    
    fn compactSSTables(self: *Database) !void {
        if (self.sstables.items.len < 2) return;
        
        // Create paths for input SSTables
        var input_paths = try self.allocator.alloc([]const u8, self.sstables.items.len);
        defer self.allocator.free(input_paths);
        
        // TODO: Get actual paths (would need to store them)
        
        const output_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.sst.compacted.{d}",
            .{ self.config.path, std.time.timestamp() }
        );
        defer self.allocator.free(output_path);
        
        // Run compaction
        try self.compactor.compact(input_paths, output_path);
        
        // TODO: Replace old SSTables with compacted one
    }
