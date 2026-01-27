const std = @import("std");
const Allocator = std.mem.Allocator;

/// B-tree file header
const BTreeHeader = extern struct {
    magic: u32,
    version: u32,
    size: usize,
    order: usize,
};

/// B+ Tree implementation for sorted key-value indexing
/// Optimized for mobile with configurable node sizes
pub fn BTree(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        
        /// B-tree node order (max children per node)
        const ORDER = 32; // Optimized for cache lines on mobile
        
        const Node = struct {
            keys: [ORDER - 1]K,
            values: [ORDER - 1]V,
            children: [ORDER]?*Node,
            parent: ?*Node,
            num_keys: usize,
            is_leaf: bool,
            
            fn init(allocator: Allocator, is_leaf: bool) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .keys = undefined,
                    .values = undefined,
                    .children = [_]?*Node{null} ** ORDER,
                    .parent = null,
                    .num_keys = 0,
                    .is_leaf = is_leaf,
                };
                return node;
            }
            
            fn deinit(self: *Node, allocator: Allocator) void {
                if (!self.is_leaf) {
                    for (self.children[0..self.num_keys + 1]) |child| {
                        if (child) |c| {
                            c.deinit(allocator);
                        }
                    }
                }
                allocator.destroy(self);
            }
        };
        
        allocator: Allocator,
        root: ?*Node,
        size: usize,
        
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .size = 0,
            };
        }
        
        /// Save B-tree to disk
        pub fn saveToDisk(self: *Self, file: std.fs.File) !void {
            // Write header
            const header = BTreeHeader{
                .magic = 0x5A4D4442, // "ZMDB"
                .version = 1,
                .size = self.size,
                .order = ORDER,
            };
            try file.writeAll(std.mem.asBytes(&header));
            
            // Serialize tree nodes
            if (self.root) |root| {
                try self.serializeNode(file, root);
            }
        }
        
        /// Load B-tree from disk
        pub fn loadFromDisk(allocator: Allocator, file: std.fs.File) !Self {
            // Read header
            var header: BTreeHeader = undefined;
            const bytes_read = try file.read(std.mem.asBytes(&header));
            if (bytes_read != @sizeOf(BTreeHeader)) return error.CorruptedIndex;
            if (header.magic != 0x5A4D4442) return error.InvalidMagic;
            if (header.order != ORDER) return error.IncompatibleOrder;
            
            var tree = Self.init(allocator);
            tree.size = header.size;
            
            // Deserialize tree nodes
            if (header.size > 0) {
                tree.root = try tree.deserializeNode(file, null);
            }
            
            return tree;
        }
        
        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                root.deinit(self.allocator);
            }
        }
        
        /// Insert a key-value pair
        pub fn insert(self: *Self, key: K, value: V) !void {
            if (self.root == null) {
                self.root = try Node.init(self.allocator, true);
            }
            
            const root = self.root.?;
            
            // If root is full, split it
            if (root.num_keys == ORDER - 1) {
                const new_root = try Node.init(self.allocator, false);
                new_root.children[0] = root;
                root.parent = new_root;
                try self.splitChild(new_root, 0);
                self.root = new_root;
            }
            
            try self.insertNonFull(self.root.?, key, value);
            self.size += 1;
        }
        
        /// Search for a key and return its value
        pub fn search(self: *Self, key: K) ?V {
            if (self.root == null) return null;
            return self.searchNode(self.root.?, key);
        }
        
        /// Get the number of entries
        pub fn count(self: *Self) usize {
            return self.size;
        }
        
        // Internal methods
        
        fn searchNode(self: *Self, node: *Node, key: K) ?V {
            _ = self;
            var i: usize = 0;
            while (i < node.num_keys and std.mem.order(u8, &key, &node.keys[i]) == .gt) {
                i += 1;
            }
            
            if (i < node.num_keys and std.mem.eql(u8, &key, &node.keys[i])) {
                return node.values[i];
            }
            
            if (node.is_leaf) {
                return null;
            }
            
            return self.searchNode(node.children[i].?, key);
        }
        
        fn insertNonFull(self: *Self, node: *Node, key: K, value: V) !void {
            var i: isize = @intCast(node.num_keys);
            i -= 1;
            
            if (node.is_leaf) {
                // Insert in sorted order
                while (i >= 0 and std.mem.order(u8, &key, &node.keys[@intCast(i)]) == .lt) : (i -= 1) {
                    node.keys[@intCast(i + 1)] = node.keys[@intCast(i)];
                    node.values[@intCast(i + 1)] = node.values[@intCast(i)];
                }
                node.keys[@intCast(i + 1)] = key;
                node.values[@intCast(i + 1)] = value;
                node.num_keys += 1;
            } else {
                // Find child to insert into
                while (i >= 0 and std.mem.order(u8, &key, &node.keys[@intCast(i)]) == .lt) : (i -= 1) {}
                i += 1;
                
                const child = node.children[@intCast(i)].?;
                if (child.num_keys == ORDER - 1) {
                    try self.splitChild(node, @intCast(i));
                    if (std.mem.order(u8, &key, &node.keys[@intCast(i)]) == .gt) {
                        i += 1;
                    }
                }
                try self.insertNonFull(node.children[@intCast(i)].?, key, value);
            }
        }
        
        fn splitChild(self: *Self, parent: *Node, index: usize) !void {
            const full_child = parent.children[index].?;
            const new_child = try Node.init(self.allocator, full_child.is_leaf);
            
            const mid = ORDER / 2;
            new_child.num_keys = ORDER - 1 - mid;
            
            // Copy upper half of keys/values
            var j: usize = 0;
            while (j < new_child.num_keys) : (j += 1) {
                new_child.keys[j] = full_child.keys[mid + j];
                new_child.values[j] = full_child.values[mid + j];
            }
            
            // Copy children if not leaf
            if (!full_child.is_leaf) {
                j = 0;
                while (j <= new_child.num_keys) : (j += 1) {
                    new_child.children[j] = full_child.children[mid + j];
                    if (new_child.children[j]) |child| {
                        child.parent = new_child;
                    }
                }
            }
            
            full_child.num_keys = mid;
            
            // Insert new child into parent
            j = parent.num_keys;
            while (j > index) : (j -= 1) {
                parent.children[j + 1] = parent.children[j];
            }
            parent.children[index + 1] = new_child;
            new_child.parent = parent;
            
            j = parent.num_keys;
            while (j > index) : (j -= 1) {
                parent.keys[j] = parent.keys[j - 1];
                parent.values[j] = parent.values[j - 1];
            }
            parent.keys[index] = full_child.keys[mid - 1];
            parent.values[index] = full_child.values[mid - 1];
            parent.num_keys += 1;
        }
        
        // Serialization helpers
        fn serializeNode(self: *Self, file: std.fs.File, node: *Node) !void {
            _ = self;
            // Write node metadata
            try file.writeInt(u8, if (node.is_leaf) 1 else 0, .little);
            try file.writeInt(usize, node.num_keys, .little);
            
            // Write keys and values
            for (0..node.num_keys) |i| {
                try file.writeAll(std.mem.asBytes(&node.keys[i]));
                try file.writeAll(std.mem.asBytes(&node.values[i]));
            }
            
            // Recursively serialize children
            if (!node.is_leaf) {
                for (0..node.num_keys + 1) |i| {
                    if (node.children[i]) |child| {
                        try self.serializeNode(file, child);
                    }
                }
            }
        }
        
        fn deserializeNode(self: *Self, file: std.fs.File, parent: ?*Node) !*Node {
            // Read node metadata
            const is_leaf = (try file.readInt(u8, .little)) == 1;
            const num_keys = try file.readInt(usize, .little);
            
            const node = try Node.init(self.allocator, is_leaf);
            node.parent = parent;
            node.num_keys = num_keys;
            
            // Read keys and values
            for (0..num_keys) |i| {
                _ = try file.read(std.mem.asBytes(&node.keys[i]));
                _ = try file.read(std.mem.asBytes(&node.values[i]));
            }
            
            // Recursively deserialize children
            if (!is_leaf) {
                for (0..num_keys + 1) |i| {
                    node.children[i] = try self.deserializeNode(file, node);
                }
            }
            
            return node;
        }
    };
}

test "btree basic operations" {
    const allocator = std.testing.allocator;
    
    var tree = BTree([32]u8, u64).init(allocator);
    defer tree.deinit();
    
    var key1: [32]u8 = undefined;
    @memcpy(&key1, "key1" ++ [_]u8{0} ** 28);
    
    try tree.insert(key1, 100);
    try std.testing.expect(tree.count() == 1);
    
    const value = tree.search(key1);
    try std.testing.expect(value != null);
    try std.testing.expect(value.? == 100);
}
