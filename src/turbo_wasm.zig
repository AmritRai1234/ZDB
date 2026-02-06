//! TurboDatabase - WebAssembly Version
//! HIGH-PERFORMANCE in-memory database for browsers
//! Optimized for speed: inline hash, large tables, zero-copy

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Number of shards (power of 2 for fast modulo)
const NUM_SHARDS = 32;
const SHARD_MASK = NUM_SHARDS - 1;

/// Large initial capacity to reduce resizing
const INITIAL_CAPACITY = 1024;

/// Entry in the hash map
pub const Entry = struct {
    key_hash: u64,
    key_ptr: [*]const u8,
    key_len: u16,
    value_ptr: [*]u8,
    value_len: u32,
    tombstone: bool,
};

/// Single shard of the hash table (cache-line aligned)
const Shard = struct {
    entries: []?Entry,
    count: usize,
    capacity_mask: usize, // Store mask for fast modulo
    allocator: Allocator,
    
    inline fn init(allocator: Allocator) !Shard {
        const entries = try allocator.alloc(?Entry, INITIAL_CAPACITY);
        @memset(entries, null);
        return .{
            .entries = entries,
            .count = 0,
            .capacity_mask = INITIAL_CAPACITY - 1,
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *Shard) void {
        // Free all stored data
        for (self.entries) |entry_opt| {
            if (entry_opt) |entry| {
                if (!entry.tombstone) {
                    self.allocator.free(entry.key_ptr[0..entry.key_len]);
                    self.allocator.free(entry.value_ptr[0..entry.value_len]);
                }
            }
        }
        self.allocator.free(self.entries);
    }
    
    inline fn get(self: *const Shard, key: []const u8, hash: u64) ?[]const u8 {
        var idx: usize = @intCast(hash & self.capacity_mask);
        const capacity = self.entries.len;
        var probes: usize = 0;
        
        while (probes < capacity) : (probes += 1) {
            const entry_opt = self.entries[idx];
            if (entry_opt) |entry| {
                if (!entry.tombstone and entry.key_hash == hash) {
                    const stored_key = entry.key_ptr[0..entry.key_len];
                    if (std.mem.eql(u8, stored_key, key)) {
                        return entry.value_ptr[0..entry.value_len];
                    }
                }
            } else {
                return null; // Empty slot = not found
            }
            idx = (idx + 1) % capacity;
        }
        return null;
    }
    
    inline fn put(self: *Shard, key: []const u8, hash: u64, value: []const u8) !void {
        // Check load factor and resize if needed
        if (self.count * 4 >= self.entries.len * 3) {
            try self.resize();
        }
        
        var idx: usize = @intCast(hash & self.capacity_mask);
        const capacity = self.entries.len;
        var probes: usize = 0;
        
        while (probes < capacity) : (probes += 1) {
            if (self.entries[idx]) |*entry| {
                if (entry.tombstone or (entry.key_hash == hash and
                    std.mem.eql(u8, entry.key_ptr[0..entry.key_len], key)))
                {
                    // Update existing or use tombstone
                    if (!entry.tombstone) {
                        // Free old value
                        self.allocator.free(entry.value_ptr[0..entry.value_len]);
                    } else {
                        // Using tombstone, allocate new key
                        const key_copy = try self.allocator.dupe(u8, key);
                        entry.key_ptr = key_copy.ptr;
                        entry.key_len = @intCast(key.len);
                        entry.key_hash = hash;
                        self.count += 1;
                    }
                    
                    // Allocate new value
                    const value_copy = try self.allocator.dupe(u8, value);
                    entry.value_ptr = value_copy.ptr;
                    entry.value_len = @intCast(value.len);
                    entry.tombstone = false;
                    return;
                }
            } else {
                // Empty slot - insert new entry
                const key_copy = try self.allocator.dupe(u8, key);
                const value_copy = try self.allocator.dupe(u8, value);
                
                self.entries[idx] = Entry{
                    .key_hash = hash,
                    .key_ptr = key_copy.ptr,
                    .key_len = @intCast(key.len),
                    .value_ptr = value_copy.ptr,
                    .value_len = @intCast(value.len),
                    .tombstone = false,
                };
                self.count += 1;
                return;
            }
            idx = (idx + 1) % capacity;
        }
        return error.TableFull;
    }
    
    inline fn delete(self: *Shard, key: []const u8, hash: u64) bool {
        var idx: usize = @intCast(hash & self.capacity_mask);
        const capacity = self.entries.len;
        var probes: usize = 0;
        
        while (probes < capacity) : (probes += 1) {
            if (self.entries[idx]) |*entry| {
                if (!entry.tombstone and entry.key_hash == hash) {
                    const stored_key = entry.key_ptr[0..entry.key_len];
                    if (std.mem.eql(u8, stored_key, key)) {
                        // Free data
                        self.allocator.free(entry.key_ptr[0..entry.key_len]);
                        self.allocator.free(entry.value_ptr[0..entry.value_len]);
                        
                        // Mark as tombstone
                        entry.tombstone = true;
                        self.count -= 1;
                        return true;
                    }
                }
            } else {
                return false;
            }
            idx = (idx + 1) % capacity;
        }
        return false;
    }
    
    fn resize(self: *Shard) !void {
        const old_entries = self.entries;
        const new_capacity = old_entries.len * 2;
        const new_mask = new_capacity - 1;
        
        const new_entries = try self.allocator.alloc(?Entry, new_capacity);
        @memset(new_entries, null);
        
        self.entries = new_entries;
        self.capacity_mask = new_mask;
        self.count = 0;
        
        // Rehash all entries
        for (old_entries) |entry_opt| {
            if (entry_opt) |entry| {
                if (!entry.tombstone) {
                    // Find new position using fast mask
                    var idx: usize = @intCast(entry.key_hash & new_mask);
                    while (self.entries[idx] != null) {
                        idx = (idx + 1) & new_mask;
                    }
                    self.entries[idx] = entry;
                    self.count += 1;
                }
            }
        }
        
        self.allocator.free(old_entries);
    }
};

/// TurboWasm - High-performance in-memory database
pub const TurboWasm = struct {
    shards: [NUM_SHARDS]Shard,
    allocator: Allocator,
    
    // Statistics
    reads: usize,
    writes: usize,
    
    pub fn init(allocator: Allocator) !*TurboWasm {
        const db = try allocator.create(TurboWasm);
        
        for (&db.shards) |*shard| {
            shard.* = try Shard.init(allocator);
        }
        
        db.allocator = allocator;
        db.reads = 0;
        db.writes = 0;
        
        return db;
    }
    
    pub fn deinit(self: *TurboWasm) void {
        for (&self.shards) |*shard| {
            shard.deinit();
        }
        self.allocator.destroy(self);
    }
    
    inline fn shardIndex(hash: u64) usize {
        return @intCast(hash & SHARD_MASK);
    }
    
    /// Put key-value pair
    pub fn put(self: *TurboWasm, key: []const u8, value: []const u8) !void {
        if (key.len == 0 or key.len > 65535) return error.InvalidKey;
        
        const hash = std.hash.Wyhash.hash(0, key);
        const shard = &self.shards[shardIndex(hash)];
        
        try shard.put(key, hash, value);
        self.writes += 1;
    }
    
    /// Get value (returns borrowed slice - do not free!)
    pub fn get(self: *TurboWasm, key: []const u8) ?[]const u8 {
        const hash = std.hash.Wyhash.hash(0, key);
        const shard = &self.shards[shardIndex(hash)];
        
        self.reads += 1;
        return shard.get(key, hash);
    }
    
    /// Get value (returns copy - caller must free)
    pub fn getCopy(self: *TurboWasm, key: []const u8, allocator: Allocator) ![]u8 {
        const value = self.get(key) orelse return error.NotFound;
        return try allocator.dupe(u8, value);
    }
    
    /// Delete key
    pub fn delete(self: *TurboWasm, key: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0, key);
        const shard = &self.shards[shardIndex(hash)];
        return shard.delete(key, hash);
    }
    
    /// Check if key exists
    pub fn contains(self: *TurboWasm, key: []const u8) bool {
        return self.get(key) != null;
    }
    
    /// Get total count
    pub fn count(self: *const TurboWasm) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            total += shard.count;
        }
        return total;
    }
    
    // ========================================================================
    // Batch APIs
    // ========================================================================
    
    pub const KV = struct {
        key: []const u8,
        value: []const u8,
    };
    
    /// Batch put
    pub fn putBatch(self: *TurboWasm, entries: []const KV) usize {
        var success: usize = 0;
        for (entries) |kv| {
            self.put(kv.key, kv.value) catch continue;
            success += 1;
        }
        return success;
    }
    
    /// Batch get
    pub fn getBatch(self: *TurboWasm, keys: []const []const u8, results: []?[]const u8) void {
        for (keys, 0..) |key, i| {
            results[i] = self.get(key);
        }
    }
    
    /// Get stats
    pub fn getStats(self: *const TurboWasm) struct { keys: usize, reads: usize, writes: usize } {
        return .{
            .keys = self.count(),
            .reads = self.reads,
            .writes = self.writes,
        };
    }
};

// ============================================================================
// WASM Exports
// ============================================================================

var global_allocator: std.mem.Allocator = undefined;
var allocator_initialized: bool = false;

fn getWasmAllocator() std.mem.Allocator {
    if (!allocator_initialized) {
        global_allocator = std.heap.wasm_allocator;
        allocator_initialized = true;
    }
    return global_allocator;
}

/// Allocate memory for WASM
export fn turbo_wasm_alloc(size: usize) ?[*]u8 {
    const allocator = getWasmAllocator();
    const slice = allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

/// Free memory for WASM
export fn turbo_wasm_free(ptr: [*]u8, size: usize) void {
    const allocator = getWasmAllocator();
    allocator.free(ptr[0..size]);
}

/// Create new database
export fn turbo_wasm_create() ?*TurboWasm {
    const allocator = getWasmAllocator();
    return TurboWasm.init(allocator) catch null;
}

/// Destroy database
export fn turbo_wasm_destroy(db: *TurboWasm) void {
    db.deinit();
}

/// Put key-value pair
export fn turbo_wasm_put(
    db: *TurboWasm,
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) i32 {
    const key = key_ptr[0..key_len];
    const value = value_ptr[0..value_len];
    
    db.put(key, value) catch |err| {
        return switch (err) {
            error.InvalidKey => -1,
            error.OutOfMemory => -3,
            else => -99,
        };
    };
    return 0;
}

/// Get value
export fn turbo_wasm_get(
    db: *TurboWasm,
    key_ptr: [*]const u8,
    key_len: usize,
    value_len_out: *usize,
) ?[*]const u8 {
    const key = key_ptr[0..key_len];
    const value = db.get(key) orelse return null;
    value_len_out.* = value.len;
    return value.ptr;
}

/// Get value (copy)
export fn turbo_wasm_get_copy(
    db: *TurboWasm,
    key_ptr: [*]const u8,
    key_len: usize,
    value_len_out: *usize,
) ?[*]u8 {
    const allocator = getWasmAllocator();
    const key = key_ptr[0..key_len];
    
    const value = db.getCopy(key, allocator) catch return null;
    value_len_out.* = value.len;
    return value.ptr;
}

/// Delete key
export fn turbo_wasm_delete(db: *TurboWasm, key_ptr: [*]const u8, key_len: usize) i32 {
    const key = key_ptr[0..key_len];
    return if (db.delete(key)) 0 else 1;
}

/// Check if key exists
export fn turbo_wasm_contains(db: *TurboWasm, key_ptr: [*]const u8, key_len: usize) i32 {
    const key = key_ptr[0..key_len];
    return if (db.contains(key)) 1 else 0;
}

/// Get count
export fn turbo_wasm_count(db: *const TurboWasm) usize {
    return db.count();
}

/// Get stats (writes to stats_out: [keys, reads, writes])
export fn turbo_wasm_get_stats(db: *const TurboWasm, stats_out: [*]usize) void {
    const stats = db.getStats();
    stats_out[0] = stats.keys;
    stats_out[1] = stats.reads;
    stats_out[2] = stats.writes;
}

// Unit tests (only for native builds)
test "turbo wasm basic operations" {
    const allocator = std.testing.allocator;
    
    const db = try TurboWasm.init(allocator);
    defer db.deinit();
    
    // Put
    try db.put("test_key", "test_value");
    
    // Get
    const value = db.get("test_key").?;
    try std.testing.expectEqualStrings("test_value", value);
    
    // Count
    try std.testing.expectEqual(@as(usize, 1), db.count());
    
    // Delete
    try std.testing.expect(db.delete("test_key"));
    try std.testing.expectEqual(@as(usize, 0), db.count());
}

test "turbo wasm batch operations" {
    const allocator = std.testing.allocator;
    
    const db = try TurboWasm.init(allocator);
    defer db.deinit();
    
    const entries = [_]TurboWasm.KV{
        .{ .key = "key1", .value = "value1" },
        .{ .key = "key2", .value = "value2" },
        .{ .key = "key3", .value = "value3" },
    };
    
    const success = db.putBatch(&entries);
    try std.testing.expectEqual(@as(usize, 3), success);
    try std.testing.expectEqual(@as(usize, 3), db.count());
}
