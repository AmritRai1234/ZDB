const std = @import("std");
const Allocator = std.mem.Allocator;

/// Epoch-based memory reclamation for lock-free data structures
/// Allows safe concurrent access without traditional locks
pub const EpochManager = struct {
    global_epoch: std.atomic.Value(u64),
    garbage: std.ArrayList(GarbageEntry),
    mutex: std.Thread.Mutex,
    
    const GarbageEntry = struct {
        ptr: *anyopaque,
        epoch: u64,
        free_fn: *const fn (*anyopaque, Allocator) void,
    };
    
    pub fn init(allocator: Allocator) EpochManager {
        return .{
            .global_epoch = std.atomic.Value(u64).init(0),
            .garbage = std.ArrayList(GarbageEntry).init(allocator),
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *EpochManager, allocator: Allocator) void {
        // Free all remaining garbage
        for (self.garbage.items) |entry| {
            entry.free_fn(entry.ptr, allocator);
        }
        self.garbage.deinit();
    }
    
    /// Pin current thread to epoch (start read operation)
    pub fn pin(self: *EpochManager) Guard {
        const epoch = self.global_epoch.load(.acquire);
        return Guard{ .epoch = epoch, .manager = self };
    }
    
    /// Advance global epoch (call periodically from writer)
    pub fn advance(self: *EpochManager) void {
        _ = self.global_epoch.fetchAdd(1, .release);
    }
    
    /// Defer freeing pointer until safe
    pub fn deferFree(
        self: *EpochManager,
        ptr: *anyopaque,
        free_fn: *const fn (*anyopaque, Allocator) void,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current_epoch = self.global_epoch.load(.monotonic);
        try self.garbage.append(.{
            .ptr = ptr,
            .epoch = current_epoch,
            .free_fn = free_fn,
        });
    }
    
    /// Collect garbage from old epochs
    pub fn collect(self: *EpochManager, allocator: Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current_epoch = self.global_epoch.load(.monotonic);
        const safe_epoch = if (current_epoch >= 2) current_epoch - 2 else 0;
        
        var i: usize = 0;
        while (i < self.garbage.items.len) {
            if (self.garbage.items[i].epoch < safe_epoch) {
                const entry = self.garbage.swapRemove(i);
                entry.free_fn(entry.ptr, allocator);
            } else {
                i += 1;
            }
        }
    }
    
    pub const Guard = struct {
        epoch: u64,
        manager: *EpochManager,
        
        pub fn unpin(self: *Guard) void {
            _ = self;
            // In production, would track active guards per epoch
        }
    };
};

/// Lock-free HashMap using atomic operations
pub fn LockFreeHashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        
        const Entry = struct {
            key: K,
            value: std.atomic.Value(V),
            next: std.atomic.Value(?*Entry),
        };
        
        buckets: []std.atomic.Value(?*Entry),
        allocator: Allocator,
        epoch: EpochManager,
        
        pub fn init(allocator: Allocator, size: usize) !Self {
            const buckets = try allocator.alloc(std.atomic.Value(?*Entry), size);
            for (buckets) |*bucket| {
                bucket.* = std.atomic.Value(?*Entry).init(null);
            }
            
            return .{
                .buckets = buckets,
                .allocator = allocator,
                .epoch = EpochManager.init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.epoch.deinit(self.allocator);
            self.allocator.free(self.buckets);
        }
        
        pub fn get(self: *Self, key: K) ?V {
            var guard = self.epoch.pin();
            defer guard.unpin();
            
            const hash = hashKey(key);
            const bucket = &self.buckets[hash % self.buckets.len];
            
            var entry = bucket.load(.acquire);
            while (entry) |e| {
                if (keysEqual(e.key, key)) {
                    return e.value.load(.acquire);
                }
                entry = e.next.load(.acquire);
            }
            return null;
        }
        
        pub fn put(self: *Self, key: K, value: V) !void {
            const hash = hashKey(key);
            const bucket = &self.buckets[hash % self.buckets.len];
            
            // Create new entry
            const entry = try self.allocator.create(Entry);
            entry.* = .{
                .key = key,
                .value = std.atomic.Value(V).init(value),
                .next = std.atomic.Value(?*Entry).init(null),
            };
            
            // CAS loop to insert
            while (true) {
                const head = bucket.load(.acquire);
                entry.next.store(head, .release);
                
                if (bucket.cmpxchgWeak(
                    head,
                    entry,
                    .release,
                    .acquire,
                )) |_| {
                    continue; // Retry
                } else {
                    break; // Success
                }
            }
            
            self.epoch.advance();
        }
        
        fn hashKey(key: K) u64 {
            if (K == []const u8 or K == []u8) {
                var h = std.hash.Wyhash.init(0);
                h.update(key);
                return h.final();
            } else {
                return @as(u64, @intCast(key));
            }
        }
        
        fn keysEqual(a: K, b: K) bool {
            if (K == []const u8 or K == []u8) {
                return std.mem.eql(u8, a, b);
            } else {
                return a == b;
            }
        }
    };
}

test "lock-free hashmap basic" {
    const allocator = std.testing.allocator;
    
    var map = try LockFreeHashMap(u64, u64).init(allocator, 16);
    defer map.deinit();
    
    try map.put(1, 100);
    try map.put(2, 200);
    
    try std.testing.expect(map.get(1).? == 100);
    try std.testing.expect(map.get(2).? == 200);
    try std.testing.expect(map.get(999) == null);
}
