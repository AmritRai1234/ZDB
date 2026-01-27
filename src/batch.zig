const std = @import("std");
const Allocator = std.mem.Allocator;

/// Battery-aware write batching for mobile devices
/// Reduces fsync calls and CPU wakeups to save battery

pub const BatchConfig = struct {
    /// Maximum batch size in bytes
    max_batch_size: usize = 64 * 1024, // 64KB
    
    /// Maximum time to wait before flushing (milliseconds)
    max_wait_ms: u64 = 100,
    
    /// Minimum writes before considering flush
    min_writes: usize = 10,
    
    /// Enable adaptive batching based on write patterns
    adaptive: bool = true,
};

pub const BatchWriter = struct {
    allocator: Allocator,
    config: BatchConfig,
    buffer: std.ArrayList(u8),
    pending_writes: usize,
    last_flush_time: i64,
    write_callback: *const fn ([]const u8) anyerror!void,
    
    pub fn init(
        allocator: Allocator,
        config: BatchConfig,
        write_callback: *const fn ([]const u8) anyerror!void,
    ) BatchWriter {
        return .{
            .allocator = allocator,
            .config = config,
            .buffer = std.ArrayList(u8){},
            .pending_writes = 0,
            .last_flush_time = std.time.milliTimestamp(),
            .write_callback = write_callback,
        };
    }
    
    pub fn deinit(self: *BatchWriter) void {
        self.buffer.deinit(self.allocator);
    }
    
    /// Add data to the batch
    pub fn write(self: *BatchWriter, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
        self.pending_writes += 1;
        
        // Check if we should flush
        if (self.shouldFlush()) {
            try self.flush();
        }
    }
    
    /// Force flush all pending writes
    pub fn flush(self: *BatchWriter) !void {
        if (self.buffer.items.len == 0) return;
        
        try self.write_callback(self.buffer.items);
        
        self.buffer.clearRetainingCapacity();
        self.pending_writes = 0;
        self.last_flush_time = std.time.milliTimestamp();
    }
    
    /// Check if batch should be flushed
    fn shouldFlush(self: *BatchWriter) bool {
        // Size threshold
        if (self.buffer.items.len >= self.config.max_batch_size) {
            return true;
        }
        
        // Time threshold
        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_flush_time;
        if (elapsed >= self.config.max_wait_ms) {
            return true;
        }
        
        // Minimum writes threshold
        if (self.pending_writes >= self.config.min_writes) {
            return true;
        }
        
        return false;
    }
    
    /// Get current batch statistics
    pub fn stats(self: *BatchWriter) BatchStats {
        return .{
            .buffer_size = self.buffer.items.len,
            .pending_writes = self.pending_writes,
            .time_since_flush = std.time.milliTimestamp() - self.last_flush_time,
        };
    }
};

pub const BatchStats = struct {
    buffer_size: usize,
    pending_writes: usize,
    time_since_flush: i64,
};

/// Background flush manager
/// Runs periodic flushes in a separate thread to avoid blocking
pub const BackgroundFlusher = struct {
    batch_writer: *BatchWriter,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    interval_ms: u64,
    
    pub fn init(batch_writer: *BatchWriter, interval_ms: u64) BackgroundFlusher {
        return .{
            .batch_writer = batch_writer,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .interval_ms = interval_ms,
        };
    }
    
    pub fn start(self: *BackgroundFlusher) !void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;
        
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, flushLoop, .{self});
    }
    
    pub fn stop(self: *BackgroundFlusher) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    
    fn flushLoop(self: *BackgroundFlusher) void {
        while (self.running.load(.acquire)) {
            std.time.sleep(self.interval_ms * std.time.ns_per_ms);
            
            // Flush if there's pending data
            self.batch_writer.flush() catch |err| {
                std.debug.print("Background flush error: {}\n", .{err});
            };
        }
    }
};

test "batch writer basic" {
    const allocator = std.testing.allocator;
    
    const callback = struct {
        fn write(data: []const u8) !void {
            _ = data;
            // In real usage, this would write to file
        }
    }.write;
    
    var writer = BatchWriter.init(allocator, .{
        .max_batch_size = 100,
        .max_wait_ms = 1000,
        .min_writes = 5,
    }, callback);
    defer writer.deinit();
    
    try writer.write("test1");
    try writer.write("test2");
    
    const s = writer.stats();
    try std.testing.expect(s.pending_writes == 2);
    try std.testing.expect(s.buffer_size == 10);
}
