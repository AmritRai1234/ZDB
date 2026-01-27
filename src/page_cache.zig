const std = @import("std");
const Allocator = std.mem.Allocator;

/// Page Cache - LRU cache for disk pages (4-64KB blocks)
/// Reduces disk I/O by caching frequently accessed pages
pub const PageCache = struct {
    const PAGE_SIZE = 16 * 1024; // 16KB pages
    const MAX_PAGES = 256; // 4MB total cache
    
    const Page = struct {
        id: u64,
        data: []u8,
        dirty: bool,
        access_time: i64,
    };
    
    const Node = struct {
        page: Page,
        prev: ?*Node,
        next: ?*Node,
    };
    
    allocator: Allocator,
    pages: std.AutoHashMap(u64, *Node),
    head: ?*Node, // Most recently used
    tail: ?*Node, // Least recently used
    size: usize,
    
    // Statistics
    hits: usize,
    misses: usize,
    evictions: usize,
    
    pub fn init(allocator: Allocator) PageCache {
        return .{
            .allocator = allocator,
            .pages = std.AutoHashMap(u64, *Node).init(allocator),
            .head = null,
            .tail = null,
            .size = 0,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
        };
    }
    
    pub fn deinit(self: *PageCache) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.free(node.page.data);
            self.allocator.destroy(node);
            current = next;
        }
        self.pages.deinit();
    }
    
    /// Get page from cache (returns null if not cached)
    pub fn get(self: *PageCache, page_id: u64) ?[]const u8 {
        if (self.pages.get(page_id)) |node| {
            self.hits += 1;
            self.moveToHead(node);
            return node.page.data;
        }
        self.misses += 1;
        return null;
    }
    
    /// Put page into cache
    pub fn put(self: *PageCache, page_id: u64, data: []const u8) !void {
        // Check if already exists
        if (self.pages.get(page_id)) |node| {
            // Update existing
            @memcpy(node.page.data, data);
            node.page.dirty = true;
            self.moveToHead(node);
            return;
        }
        
        // Evict if full
        if (self.size >= MAX_PAGES) {
            try self.evictLRU();
        }
        
        // Create new node
        const node = try self.allocator.create(Node);
        const page_data = try self.allocator.alloc(u8, PAGE_SIZE);
        @memcpy(page_data[0..data.len], data);
        
        node.* = .{
            .page = .{
                .id = page_id,
                .data = page_data,
                .dirty = false,
                .access_time = std.time.milliTimestamp(),
            },
            .prev = null,
            .next = self.head,
        };
        
        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;
        
        if (self.tail == null) {
            self.tail = node;
        }
        
        try self.pages.put(page_id, node);
        self.size += 1;
    }
    
    /// Prefetch pages (hint for sequential access)
    pub fn prefetch(self: *PageCache, page_ids: []const u64) void {
        // In a real implementation, this would trigger async I/O
        // For now, just mark intent
        _ = self;
        _ = page_ids;
    }
    
    fn moveToHead(self: *PageCache, node: *Node) void {
        if (node == self.head) return;
        
        // Remove from current position
        if (node.prev) |prev| {
            prev.next = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        }
        if (node == self.tail) {
            self.tail = node.prev;
        }
        
        // Move to head
        node.prev = null;
        node.next = self.head;
        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;
    }
    
    fn evictLRU(self: *PageCache) !void {
        const tail = self.tail orelse return;
        
        // Remove from list
        if (tail.prev) |prev| {
            prev.next = null;
            self.tail = prev;
        } else {
            self.head = null;
            self.tail = null;
        }
        
        // Remove from map
        _ = self.pages.remove(tail.page.id);
        
        // Free memory
        self.allocator.free(tail.page.data);
        self.allocator.destroy(tail);
        
        self.size -= 1;
        self.evictions += 1;
    }
    
    pub fn stats(self: *PageCache) Stats {
        const total_accesses = self.hits + self.misses;
        const hit_rate = if (total_accesses > 0)
            @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total_accesses))
        else
            0.0;
        
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .hit_rate = hit_rate,
            .size = self.size,
        };
    }
    
    pub const Stats = struct {
        hits: usize,
        misses: usize,
        evictions: usize,
        hit_rate: f64,
        size: usize,
    };
};

test "page cache basic operations" {
    const allocator = std.testing.allocator;
    
    var cache = PageCache.init(allocator);
    defer cache.deinit();
    
    const data = "test page data";
    try cache.put(1, data);
    
    const retrieved = cache.get(1);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(std.mem.startsWith(u8, retrieved.?, data));
    
    const s = cache.stats();
    try std.testing.expect(s.hits == 1);
    try std.testing.expect(s.misses == 0);
}

test "page cache LRU eviction" {
    const allocator = std.testing.allocator;
    
    var cache = PageCache.init(allocator);
    defer cache.deinit();
    
    // Fill cache beyond capacity
    var i: u64 = 0;
    while (i < PageCache.MAX_PAGES + 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "page_{d}", .{i});
        try cache.put(i, data);
    }
    
    const s = cache.stats();
    try std.testing.expect(s.evictions >= 10);
    try std.testing.expect(s.size == PageCache.MAX_PAGES);
}
