const std = @import("std");
const Allocator = std.mem.Allocator;

/// LRU Cache for key-value pairs
/// Provides O(1) get/put with automatic eviction
pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        
        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node,
            next: ?*Node,
        };
        
        allocator: Allocator,
        capacity: usize,
        map: std.HashMap(K, *Node, HashContext, std.hash_map.default_max_load_percentage),
        head: ?*Node, // Most recently used
        tail: ?*Node, // Least recently used
        
        // Statistics
        hits: usize,
        misses: usize,
        evictions: usize,
        
        const HashContext = struct {
            pub fn hash(_: HashContext, key: K) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, key);
                return hasher.final();
            }
            
            pub fn eql(_: HashContext, a: K, b: K) bool {
                return std.mem.eql(u8, &a, &b);
            }
        };
        
        pub fn init(allocator: Allocator, capacity: usize) Self {
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .map = std.HashMap(K, *Node, HashContext, std.hash_map.default_max_load_percentage).init(allocator),
                .head = null,
                .tail = null,
                .hits = 0,
                .misses = 0,
                .evictions = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            // Free all nodes
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.map.deinit();
        }
        
        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                self.hits += 1;
                // Move to front (most recently used)
                self.moveToFront(node);
                return node.value;
            }
            self.misses += 1;
            return null;
        }
        
        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.map.get(key)) |node| {
                // Update existing node
                node.value = value;
                self.moveToFront(node);
                return;
            }
            
            // Create new node
            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
                .prev = null,
                .next = self.head,
            };
            
            // Add to front of list
            if (self.head) |head| {
                head.prev = node;
            }
            self.head = node;
            
            if (self.tail == null) {
                self.tail = node;
            }
            
            // Add to map
            try self.map.put(key, node);
            
            // Evict if over capacity
            if (self.map.count() > self.capacity) {
                try self.evictLRU();
            }
        }
        
        pub fn remove(self: *Self, key: K) void {
            if (self.map.fetchRemove(key)) |kv| {
                const node = kv.value;
                self.removeNode(node);
                self.allocator.destroy(node);
            }
        }
        
        pub fn clear(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
        }
        
        pub fn stats(self: *Self) CacheStats {
            const total = self.hits + self.misses;
            const hit_rate = if (total > 0) 
                @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total))
            else 
                0.0;
            
            return .{
                .hits = self.hits,
                .misses = self.misses,
                .evictions = self.evictions,
                .size = self.map.count(),
                .capacity = self.capacity,
                .hit_rate = hit_rate,
            };
        }
        
        fn moveToFront(self: *Self, node: *Node) void {
            if (self.head == node) return; // Already at front
            
            // Remove from current position
            if (node.prev) |prev| {
                prev.next = node.next;
            }
            if (node.next) |next| {
                next.prev = node.prev;
            }
            if (self.tail == node) {
                self.tail = node.prev;
            }
            
            // Move to front
            node.prev = null;
            node.next = self.head;
            if (self.head) |head| {
                head.prev = node;
            }
            self.head = node;
        }
        
        fn removeNode(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }
            
            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }
        
        fn evictLRU(self: *Self) !void {
            if (self.tail) |tail| {
                const key = tail.key;
                _ = self.map.remove(key);
                self.removeNode(tail);
                self.allocator.destroy(tail);
                self.evictions += 1;
            }
        }
    };
}

pub const CacheStats = struct {
    hits: usize,
    misses: usize,
    evictions: usize,
    size: usize,
    capacity: usize,
    hit_rate: f64,
};

test "LRU cache basic operations" {
    const allocator = std.testing.allocator;
    
    var cache = LRUCache([32]u8, u64).init(allocator, 3);
    defer cache.deinit();
    
    var key1: [32]u8 = undefined;
    @memcpy(&key1, "key1" ++ [_]u8{0} ** 28);
    
    var key2: [32]u8 = undefined;
    @memcpy(&key2, "key2" ++ [_]u8{0} ** 28);
    
    // Put and get
    try cache.put(key1, 100);
    try std.testing.expect(cache.get(key1).? == 100);
    
    // Miss
    try std.testing.expect(cache.get(key2) == null);
    
    // Stats
    const s = cache.stats();
    try std.testing.expect(s.hits == 1);
    try std.testing.expect(s.misses == 1);
}

test "LRU cache eviction" {
    const allocator = std.testing.allocator;
    
    var cache = LRUCache([32]u8, u64).init(allocator, 2);
    defer cache.deinit();
    
    var key1: [32]u8 = undefined;
    @memcpy(&key1, "key1" ++ [_]u8{0} ** 28);
    
    var key2: [32]u8 = undefined;
    @memcpy(&key2, "key2" ++ [_]u8{0} ** 28);
    
    var key3: [32]u8 = undefined;
    @memcpy(&key3, "key3" ++ [_]u8{0} ** 28);
    
    try cache.put(key1, 1);
    try cache.put(key2, 2);
    try cache.put(key3, 3); // Should evict key1
    
    try std.testing.expect(cache.get(key1) == null); // Evicted
    try std.testing.expect(cache.get(key2).? == 2);
    try std.testing.expect(cache.get(key3).? == 3);
    
    const s = cache.stats();
    try std.testing.expect(s.evictions == 1);
}
