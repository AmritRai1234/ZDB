const std = @import("std");
const Allocator = std.mem.Allocator;

/// Multi-Version Concurrency Control (MVCC)
/// Enables lock-free reads and snapshot isolation

pub const TransactionId = u64;
pub const Version = u64;

/// Versioned value wrapper
pub fn VersionedValue(comptime T: type) type {
    return struct {
        const Self = @This();
        
        value: T,
        version: Version,
        tx_id: TransactionId,
        deleted: bool,
        
        pub fn init(value: T, version: Version, tx_id: TransactionId) Self {
            return .{
                .value = value,
                .version = version,
                .tx_id = tx_id,
                .deleted = false,
            };
        }
    };
}

/// Version manager for MVCC
pub const VersionManager = struct {
    allocator: Allocator,
    current_version: std.atomic.Value(Version),
    current_tx_id: std.atomic.Value(TransactionId),
    active_snapshots: std.ArrayList(Snapshot),
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: Allocator) VersionManager {
        return .{
            .allocator = allocator,
            .current_version = std.atomic.Value(Version).init(0),
            .current_tx_id = std.atomic.Value(TransactionId).init(0),
            .active_snapshots = std.ArrayList(Snapshot){},
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *VersionManager) void {
        self.active_snapshots.deinit(self.allocator);
    }
    
    /// Get next version number
    pub fn nextVersion(self: *VersionManager) Version {
        return self.current_version.fetchAdd(1, .monotonic) + 1;
    }
    
    /// Get next transaction ID
    pub fn nextTransactionId(self: *VersionManager) TransactionId {
        return self.current_tx_id.fetchAdd(1, .monotonic) + 1;
    }
    
    /// Create a new snapshot for read isolation
    pub fn createSnapshot(self: *VersionManager) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const snapshot = Snapshot{
            .version = self.current_version.load(.monotonic),
            .tx_id = self.nextTransactionId(),
            .timestamp = std.time.milliTimestamp(),
        };
        
        try self.active_snapshots.append(self.allocator, snapshot);
        return snapshot;
    }
    
    /// Release a snapshot
    pub fn releaseSnapshot(self: *VersionManager, snapshot: Snapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.active_snapshots.items, 0..) |s, i| {
            if (s.tx_id == snapshot.tx_id) {
                _ = self.active_snapshots.swapRemove(i);
                break;
            }
        }
    }
    
    /// Get oldest active snapshot version (for garbage collection)
    pub fn oldestActiveVersion(self: *VersionManager) Version {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.active_snapshots.items.len == 0) {
            return self.current_version.load(.monotonic);
        }
        
        var oldest: Version = std.math.maxInt(Version);
        for (self.active_snapshots.items) |snapshot| {
            if (snapshot.version < oldest) {
                oldest = snapshot.version;
            }
        }
        
        return oldest;
    }
};

/// Snapshot for read isolation
pub const Snapshot = struct {
    version: Version,
    tx_id: TransactionId,
    timestamp: i64,
};

/// Version chain for a single key
pub fn VersionChain(comptime T: type) type {
    return struct {
        const Self = @This();
        const VV = VersionedValue(T);
        
        versions: std.ArrayList(VV),
        allocator: Allocator,
        
        pub fn init(allocator: Allocator) Self {
            return .{
                .versions = std.ArrayList(VV){},
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.versions.deinit(self.allocator);
        }
        
        /// Add a new version
        pub fn addVersion(self: *Self, value: T, version: Version, tx_id: TransactionId) !void {
            const vv = VV.init(value, version, tx_id);
            try self.versions.append(self.allocator, vv);
            
            // Keep versions sorted by version number (newest first)
            std.mem.sort(VV, self.versions.items, {}, struct {
                fn lessThan(_: void, a: VV, b: VV) bool {
                    return a.version > b.version;
                }
            }.lessThan);
        }
        
        /// Get value visible to a snapshot
        pub fn getVersion(self: *Self, snapshot: Snapshot) ?T {
            for (self.versions.items) |vv| {
                // Return first version <= snapshot version that's not deleted
                if (vv.version <= snapshot.version and !vv.deleted) {
                    return vv.value;
                }
            }
            return null;
        }
        
        /// Mark latest version as deleted
        pub fn markDeleted(self: *Self, version: Version, tx_id: TransactionId) !void {
            // Add a tombstone version
            var vv = VV.init(undefined, version, tx_id);
            vv.deleted = true;
            try self.versions.append(self.allocator, vv);
        }
        
        /// Garbage collect old versions
        pub fn gc(self: *Self, oldest_active_version: Version) void {
            // Remove versions older than oldest active snapshot
            var i: usize = 0;
            while (i < self.versions.items.len) {
                if (self.versions.items[i].version < oldest_active_version) {
                    _ = self.versions.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    };
}

test "version manager" {
    const allocator = std.testing.allocator;
    
    var vm = VersionManager.init(allocator);
    defer vm.deinit();
    
    const v1 = vm.nextVersion();
    const v2 = vm.nextVersion();
    
    try std.testing.expect(v2 > v1);
    
    const snapshot = try vm.createSnapshot();
    try std.testing.expect(snapshot.version >= v2);
    
    vm.releaseSnapshot(snapshot);
}

test "version chain" {
    const allocator = std.testing.allocator;
    
    var chain = VersionChain(u64).init(allocator);
    defer chain.deinit();
    
    // Add versions
    try chain.addVersion(100, 1, 1);
    try chain.addVersion(200, 2, 2);
    try chain.addVersion(300, 3, 3);
    
    // Read from different snapshots
    const snapshot1 = Snapshot{ .version = 1, .tx_id = 1, .timestamp = 0 };
    const snapshot2 = Snapshot{ .version = 2, .tx_id = 2, .timestamp = 0 };
    const snapshot3 = Snapshot{ .version = 3, .tx_id = 3, .timestamp = 0 };
    
    try std.testing.expect(chain.getVersion(snapshot1).? == 100);
    try std.testing.expect(chain.getVersion(snapshot2).? == 200);
    try std.testing.expect(chain.getVersion(snapshot3).? == 300);
    
    // GC old versions
    chain.gc(2);
    try std.testing.expect(chain.versions.items.len == 2); // Keeps versions 2 and 3
}
