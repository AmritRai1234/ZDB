const std = @import("std");
const Allocator = std.mem.Allocator;
const sstable = @import("sstable.zig");

/// Battery-aware compaction scheduler
/// Only runs compaction when it's safe for battery and thermal constraints
pub const Compactor = struct {
    allocator: Allocator,
    power_mode: PowerMode,
    battery_level: u8, // 0-100
    is_charging: bool,
    cpu_temp: f32, // Celsius
    
    pub const PowerMode = enum {
        aggressive,    // Full performance, battery not a concern
        balanced,      // Normal operation
        ultra_saver,   // Minimize all background work
    };
    
    pub fn init(allocator: Allocator) Compactor {
        return .{
            .allocator = allocator,
            .power_mode = .balanced,
            .battery_level = 100,
            .is_charging = false,
            .cpu_temp = 25.0,
        };
    }
    
    /// Check if compaction should run based on battery/thermal constraints
    pub fn shouldCompact(self: *const Compactor) bool {
        // Never compact in ultra_saver mode
        if (self.power_mode == .ultra_saver) {
            return false;
        }
        
        // Always compact if charging and not overheating
        if (self.is_charging and self.cpu_temp < 70.0) {
            return true;
        }
        
        // Check battery level
        if (self.battery_level < 20) {
            return false; // Too low, save battery
        }
        
        // Check CPU temperature
        if (self.cpu_temp > 75.0) {
            return false; // Too hot, avoid thermal throttling
        }
        
        // In aggressive mode, compact if battery > 50%
        if (self.power_mode == .aggressive and self.battery_level > 50) {
            return true;
        }
        
        // In balanced mode, compact if battery > 60%
        if (self.power_mode == .balanced and self.battery_level > 60) {
            return true;
        }
        
        return false;
    }
    
    /// Update power state (would be called by system integration)
    pub fn updatePowerState(self: *Compactor, battery_level: u8, is_charging: bool, cpu_temp: f32) void {
        self.battery_level = battery_level;
        self.is_charging = is_charging;
        self.cpu_temp = cpu_temp;
    }
    
    /// Set power mode
    pub fn setPowerMode(self: *Compactor, mode: PowerMode) void {
        self.power_mode = mode;
    }
    
    /// Compact multiple SSTables into one
    pub fn compact(self: *Compactor, input_paths: []const []const u8, output_path: []const u8) !void {
        if (!self.shouldCompact()) {
            return error.CompactionNotAllowed;
        }
        
        // Open all input SSTables
        var sstables = try self.allocator.alloc(sstable.SSTable, input_paths.len);
        defer {
            for (sstables) |*sst| {
                sst.deinit();
            }
            self.allocator.free(sstables);
        }
        
        for (input_paths, 0..) |path, i| {
            sstables[i] = try sstable.SSTable.init(self.allocator, path);
        }
        
        // Merge using k-way merge
        try self.mergeSSTablesKWay(sstables, output_path);
    }
    
    /// K-way merge of multiple sorted SSTables
    fn mergeSSTablesKWay(self: *Compactor, sstables_list: []sstable.SSTable, output_path: []const u8) !void {
        // Create output writer
        const total_keys = blk: {
            var sum: usize = 0;
            for (sstables_list) |*sst| {
                sum += sst.header.key_count;
            }
            break :blk sum;
        };
        
        var writer = try sstable.SSTableWriter.init(self.allocator, output_path, total_keys);
        defer writer.deinit();
        
        // Create iterators for each SSTable
        const IteratorWithIndex = struct {
            iter: sstable.SSTable.Iterator,
            current: ?sstable.SSTable.KV,
            index: usize,
        };
        
        var iters = try self.allocator.alloc(IteratorWithIndex, sstables_list.len);
        defer self.allocator.free(iters);
        
        // Initialize all iterators
        for (sstables_list, 0..) |*sst, i| {
            var iter = sst.scan("", "\xFF" ** 256); // Scan all keys
            const first = iter.next();
            iters[i] = .{
                .iter = iter,
                .current = first,
                .index = i,
            };
        }
        
        // K-way merge: repeatedly find minimum key
        while (true) {
            // Find iterator with smallest current key
            var min_idx: ?usize = null;
            var min_key: ?[]const u8 = null;
            
            for (iters, 0..) |*iter_with_idx, i| {
                if (iter_with_idx.current) |kv| {
                    if (min_key == null or std.mem.order(u8, kv.key, min_key.?) == .lt) {
                        min_key = kv.key;
                        min_idx = i;
                    }
                }
            }
            
            if (min_idx == null) break; // All iterators exhausted
            
            // Write the minimum key-value pair
            const min_kv = iters[min_idx.?].current.?;
            try writer.add(min_kv.key, min_kv.value);
            
            // Advance the iterator that had the minimum
            iters[min_idx.?].current = iters[min_idx.?].iter.next();
            
            // Check if we should pause (battery/thermal check)
            if (!self.shouldCompact()) {
                return error.CompactionInterrupted;
            }
        }
        
        try writer.finish();
    }
    
    /// Determine if compaction is needed based on SSTable count/size
    pub fn needsCompaction(self: *const Compactor, sstable_count: usize, total_size: u64) bool {
        _ = self;
        
        // Compact if we have too many SSTables
        if (sstable_count > 10) {
            return true;
        }
        
        // Compact if total size is large (> 100MB)
        if (total_size > 100 * 1024 * 1024) {
            return true;
        }
        
        return false;
    }
};

// Tests
test "compaction power checks" {
    var compactor = Compactor.init(std.testing.allocator);
    
    // Charging and cool - should compact
    compactor.updatePowerState(80, true, 50.0);
    try std.testing.expect(compactor.shouldCompact());
    
    // Low battery - should not compact
    compactor.updatePowerState(15, false, 50.0);
    try std.testing.expect(!compactor.shouldCompact());
    
    // High temperature - should not compact
    compactor.updatePowerState(80, false, 80.0);
    try std.testing.expect(!compactor.shouldCompact());
    
    // Ultra saver mode - never compact
    compactor.setPowerMode(.ultra_saver);
    compactor.updatePowerState(100, true, 50.0);
    try std.testing.expect(!compactor.shouldCompact());
    
    // Aggressive mode with good battery - should compact
    compactor.setPowerMode(.aggressive);
    compactor.updatePowerState(60, false, 50.0);
    try std.testing.expect(compactor.shouldCompact());
}

test "compaction triggers" {
    var compactor = Compactor.init(std.testing.allocator);
    
    // Too many SSTables
    try std.testing.expect(compactor.needsCompaction(15, 1024));
    
    // Large total size
    try std.testing.expect(compactor.needsCompaction(5, 150 * 1024 * 1024));
    
    // Normal case - no compaction needed
    try std.testing.expect(!compactor.needsCompaction(5, 10 * 1024 * 1024));
}
