const std = @import("std");
const Allocator = std.mem.Allocator;

/// SkipList - Fast in-memory sorted data structure for LSM memtable
/// O(log n) insert, search, delete with probabilistic balancing
pub fn SkipList(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const MAX_LEVEL = 16;
        
        const Node = struct {
            key: K,
            value: V,
            forward: [MAX_LEVEL]?*Node,
            level: usize,
        };
        
        allocator: Allocator,
        head: *Node,
        level: usize,
        size_bytes: usize,
        count: usize,
        rng: std.Random.DefaultPrng,
        
        pub fn init(allocator: Allocator) !Self {
            const head = try allocator.create(Node);
            head.* = .{
                .key = undefined,
                .value = undefined,
                .forward = [_]?*Node{null} ** MAX_LEVEL,
                .level = MAX_LEVEL,
            };
            
            return .{
                .allocator = allocator,
                .head = head,
                .level = 1,
                .size_bytes = 0,
                .count = 0,
                .rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp())),
            };
        }
        
        pub fn deinit(self: *Self) void {
            var current = self.head.forward[0];
            while (current) |node| {
                const next = node.forward[0];
                self.allocator.destroy(node);
                current = next;
            }
            self.allocator.destroy(self.head);
        }
        
        fn randomLevel(self: *Self) usize {
            var lvl: usize = 1;
            while (lvl < MAX_LEVEL and self.rng.random().int(u32) % 4 == 0) {
                lvl += 1;
            }
            return lvl;
        }
        
        pub fn insert(self: *Self, key: K, value: V) !void {
            var update: [MAX_LEVEL]?*Node = [_]?*Node{null} ** MAX_LEVEL;
            var current = self.head;
            
            // Find position
            var i: usize = self.level;
            while (i > 0) {
                i -= 1;
                while (current.forward[i]) |next| {
                    if (compareKeys(next.key, key) < 0) {
                        current = next;
                    } else {
                        break;
                    }
                }
                update[i] = current;
            }
            
            current = current.forward[0] orelse blk: {
                // Insert new node
                const new_level = self.randomLevel();
                const node = try self.allocator.create(Node);
                node.* = .{
                    .key = key,
                    .value = value,
                    .forward = [_]?*Node{null} ** MAX_LEVEL,
                    .level = new_level,
                };
                
                // Update pointers
                for (0..new_level) |lvl| {
                    if (update[lvl]) |prev| {
                        node.forward[lvl] = prev.forward[lvl];
                        prev.forward[lvl] = node;
                    }
                }
                
                if (new_level > self.level) {
                    self.level = new_level;
                }
                
                self.size_bytes += @sizeOf(Node) + @sizeOf(K) + @sizeOf(V);
                self.count += 1;
                return;
            };
            
            // Update existing
            if (compareKeys(current.key, key) == 0) {
                current.value = value;
            }
        }
        
        pub fn get(self: *Self, key: K) ?V {
            var current = self.head;
            
            var i: usize = self.level;
            while (i > 0) {
                i -= 1;
                while (current.forward[i]) |next| {
                    const cmp = compareKeys(next.key, key);
                    if (cmp < 0) {
                        current = next;
                    } else if (cmp == 0) {
                        return next.value;
                    } else {
                        break;
                    }
                }
            }
            
            return null;
        }
        
        pub fn size(self: *Self) usize {
            return self.size_bytes;
        }
        
        pub fn len(self: *Self) usize {
            return self.count;
        }
        
        /// Iterator for sorted traversal
        pub const Iterator = struct {
            current: ?*Node,
            
            pub fn next(self: *Iterator) ?struct { key: K, value: V } {
                if (self.current) |node| {
                    const result = .{ .key = node.key, .value = node.value };
                    self.current = node.forward[0];
                    return result;
                }
                return null;
            }
        };
        
        pub fn iterator(self: *Self) Iterator {
            return .{ .current = self.head.forward[0] };
        }
        
        fn compareKeys(a: K, b: K) i32 {
            if (K == []const u8 or K == []u8) {
                return std.mem.order(u8, a, b).compare(std.math.Order.eq);
            } else {
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            }
        }
    };
}

test "skiplist basic operations" {
    const allocator = std.testing.allocator;
    
    var list = try SkipList(u64, []const u8).init(allocator);
    defer list.deinit();
    
    try list.insert(5, "five");
    try list.insert(3, "three");
    try list.insert(7, "seven");
    try list.insert(1, "one");
    
    try std.testing.expect(std.mem.eql(u8, list.get(5).?, "five"));
    try std.testing.expect(std.mem.eql(u8, list.get(3).?, "three"));
    try std.testing.expect(list.get(99) == null);
    try std.testing.expect(list.len() == 4);
}

test "skiplist sorted iteration" {
    const allocator = std.testing.allocator;
    
    var list = try SkipList(u64, u64).init(allocator);
    defer list.deinit();
    
    try list.insert(5, 50);
    try list.insert(3, 30);
    try list.insert(7, 70);
    try list.insert(1, 10);
    
    var iter = list.iterator();
    try std.testing.expect(iter.next().?.key == 1);
    try std.testing.expect(iter.next().?.key == 3);
    try std.testing.expect(iter.next().?.key == 5);
    try std.testing.expect(iter.next().?.key == 7);
    try std.testing.expect(iter.next() == null);
}
