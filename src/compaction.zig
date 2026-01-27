const std = @import("std");
const Allocator = std.mem.Allocator;
const Database = @import("database.zig").Database;

/// Background compaction for WAL files
/// Merges live records, removes tombstones, reclaims space

pub const CompactionConfig = struct {
    /// Trigger compaction when WAL exceeds this size
    max_wal_size: usize = 100 * 1024 * 1024, // 100MB
    
    /// Minimum time between compactions (seconds)
    min_interval_secs: u64 = 3600, // 1 hour
    
    /// I/O throttle (bytes per second, 0 = unlimited)
    io_throttle_bps: usize = 10 * 1024 * 1024, // 10MB/s
    
    /// Enable background compaction thread
    background: bool = true,
};

pub const CompactionStats = struct {
    records_read: usize,
    records_written: usize,
    tombstones_removed: usize,
    bytes_reclaimed: usize,
    duration_ms: i64,
};

pub const Compactor = struct {
    db: *Database,
    config: CompactionConfig,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    last_compaction: i64,
    
    pub fn init(db: *Database, config: CompactionConfig) Compactor {
        return .{
            .db = db,
            .config = config,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .last_compaction = 0,
        };
    }
    
    pub fn start(self: *Compactor) !void {
        if (!self.config.background) return;
        if (self.running.load(.acquire)) return error.AlreadyRunning;
        
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, compactionLoop, .{self});
    }
    
    pub fn stop(self: *Compactor) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    
    /// Perform compaction synchronously
    pub fn compact(self: *Compactor) !CompactionStats {
        const start_time = std.time.milliTimestamp();
        
        var stats = CompactionStats{
            .records_read = 0,
            .records_written = 0,
            .tombstones_removed = 0,
            .bytes_reclaimed = 0,
            .duration_ms = 0,
        };
        
        // Create temporary compacted file
        const temp_path = "/tmp/zmdb_compact.tmp";
        const temp_file = try std.fs.cwd().createFile(temp_path, .{
            .read = true,
            .truncate = true,
        });
        defer temp_file.close();
        defer std.fs.cwd().deleteFile(temp_path) catch {};
        
        // Read all live records from WAL
        // This is simplified - real implementation would:
        // 1. Lock database for writes
        // 2. Scan WAL for live records
        // 3. Write to temp file
        // 4. Atomically swap files
        // 5. Unlock database
        
        // For now, just track stats
        stats.duration_ms = std.time.milliTimestamp() - start_time;
        self.last_compaction = std.time.timestamp();
        
        return stats;
    }
    
    fn compactionLoop(self: *Compactor) void {
        while (self.running.load(.acquire)) {
            // Sleep for check interval
            std.time.sleep(60 * std.time.ns_per_s); // Check every minute
            
            // Check if compaction is needed
            if (self.shouldCompact()) {
                const stats = self.compact() catch |err| {
                    std.debug.print("Compaction error: {}\n", .{err});
                    continue;
                };
                
                std.debug.print("Compaction completed: {} records, {} bytes reclaimed\n", 
                    .{stats.records_written, stats.bytes_reclaimed});
            }
        }
    }
    
    fn shouldCompact(self: *Compactor) bool {
        // Check time since last compaction
        const now = std.time.timestamp();
        if (now - self.last_compaction < self.config.min_interval_secs) {
            return false;
        }
        
        // Check WAL size (simplified - would need actual file size)
        // In real implementation, check if WAL file exceeds max_wal_size
        
        return false; // Placeholder
    }
};

/// Throttled I/O writer
pub const ThrottledWriter = struct {
    file: std.fs.File,
    bytes_per_second: usize,
    last_write_time: i64,
    bytes_written_this_second: usize,
    
    pub fn init(file: std.fs.File, bytes_per_second: usize) ThrottledWriter {
        return .{
            .file = file,
            .bytes_per_second = bytes_per_second,
            .last_write_time = std.time.milliTimestamp(),
            .bytes_written_this_second = 0,
        };
    }
    
    pub fn write(self: *ThrottledWriter, data: []const u8) !void {
        const now = std.time.milliTimestamp();
        
        // Reset counter if we're in a new second
        if (now - self.last_write_time >= 1000) {
            self.last_write_time = now;
            self.bytes_written_this_second = 0;
        }
        
        // Throttle if we've exceeded limit
        if (self.bytes_written_this_second + data.len > self.bytes_per_second) {
            const sleep_ms = 1000 - @as(u64, @intCast(now - self.last_write_time));
            std.time.sleep(sleep_ms * std.time.ns_per_ms);
            self.last_write_time = std.time.milliTimestamp();
            self.bytes_written_this_second = 0;
        }
        
        try self.file.writeAll(data);
        self.bytes_written_this_second += data.len;
    }
};

test "compaction config" {
    const config = CompactionConfig{};
    try std.testing.expect(config.max_wal_size == 100 * 1024 * 1024);
    try std.testing.expect(config.background == true);
}
