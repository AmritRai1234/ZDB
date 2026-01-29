const std = @import("std");

/// Battery and power management for mobile devices
/// Optimizes database operations based on power state
pub const PowerManager = struct {
    is_charging: bool,
    battery_level: f32, // 0.0 to 1.0
    thermal_state: ThermalState,
    power_mode: PowerMode,
    
    // Statistics
    wake_ups_saved: usize,
    bytes_saved_by_compression: usize,
    operations_deferred: usize,
    
    pub const ThermalState = enum {
        normal,      // < 40°C
        warm,        // 40-50°C
        hot,         // 50-60°C
        critical,    // > 60°C
    };
    
    pub const PowerMode = enum {
        aggressive,   // Charging + high battery
        balanced,     // Normal operation
        saver,        // Low battery (20-10%)
        ultra_saver,  // Critical battery (<10%)
        deep_sleep,   // Idle, minimize everything
    };
    
    pub fn init() PowerManager {
        return .{
            .is_charging = false,
            .battery_level = 1.0,
            .thermal_state = .normal,
            .power_mode = .balanced,
            .wake_ups_saved = 0,
            .bytes_saved_by_compression = 0,
            .operations_deferred = 0,
        };
    }
    
    /// Update power state (call periodically or on system events)
    pub fn update(self: *PowerManager) void {
        // Read battery state from system
        self.is_charging = self.readChargingState();
        self.battery_level = self.readBatteryLevel();
        self.thermal_state = self.readThermalState();
        
        // Determine power mode
        self.power_mode = self.calculatePowerMode();
    }
    
    /// Should we do aggressive background work?
    pub fn shouldDoBackgroundWork(self: *PowerManager) bool {
        return switch (self.power_mode) {
            .aggressive => true,   // Charging, go wild!
            .balanced => self.thermal_state == .normal,
            .saver => false,       // Defer everything
            .ultra_saver => false, // Absolutely no background work
            .deep_sleep => false,  // Don't wake up
        };
    }
    
    /// Should we flush writes to disk?
    pub fn shouldFlush(self: *PowerManager, pending_bytes: usize, time_since_last_flush_ms: i64) bool {
        return switch (self.power_mode) {
            .aggressive => pending_bytes > 16 * 1024,  // 16KB threshold when charging
            .balanced => pending_bytes > 64 * 1024 or time_since_last_flush_ms > 60_000,
            .saver => pending_bytes > 256 * 1024 or time_since_last_flush_ms > 300_000,  // 5 min
            .ultra_saver => pending_bytes > 1024 * 1024 or time_since_last_flush_ms > 600_000,  // 10 min, 1MB
            .deep_sleep => false,  // Only flush on explicit commit
        };
    }
    
    /// Should we compress this value?
    pub fn shouldCompress(self: *PowerManager, size: usize) bool {
        // Always compress in saver mode (save I/O)
        // Compress larger values in other modes
        return switch (self.power_mode) {
            .aggressive => size > 256,
            .balanced => size > 128,
            .saver => size > 64,   // Aggressive compression
            .ultra_saver => size > 32,  // Maximum compression
            .deep_sleep => size > 64,
        };
    }
    
    /// Get compaction frequency (ms between compactions)
    pub fn getCompactionInterval(self: *PowerManager) i64 {
        return switch (self.power_mode) {
            .aggressive => 60_000,       // 1 minute (charging)
            .balanced => 300_000,        // 5 minutes
            .saver => 1_800_000,         // 30 minutes
            .ultra_saver => 7_200_000,   // 2 hours
            .deep_sleep => 86_400_000,   // 24 hours (basically never)
        };
    }
    
    /// Get batch size for writes
    pub fn getBatchSize(self: *PowerManager) usize {
        return switch (self.power_mode) {
            .aggressive => 16 * 1024,    // 16KB (small batches, quick flush)
            .balanced => 64 * 1024,      // 64KB
            .saver => 256 * 1024,        // 256KB (huge batches, rare flush)
            .ultra_saver => 1024 * 1024, // 1MB (maximum batching)
            .deep_sleep => 1024 * 1024,  // 1MB (almost never flush)
        };
    }
    
    /// Get compression level based on power mode
    pub fn getCompressionLevel(self: *PowerManager) i32 {
        return switch (self.power_mode) {
            .aggressive => 1,      // Fastest
            .balanced => 3,        // Fast
            .saver => 6,           // Default
            .ultra_saver => 9,     // Best compression
            .deep_sleep => 9,      // Best compression
        };
    }
    
    /// Record that we saved a wake-up
    pub fn recordWakeUpSaved(self: *PowerManager) void {
        self.wake_ups_saved += 1;
    }
    
    /// Record compression savings
    pub fn recordCompressionSavings(self: *PowerManager, bytes_saved: usize) void {
        self.bytes_saved_by_compression += bytes_saved;
    }
    
    /// Record deferred operation
    pub fn recordDeferredOperation(self: *PowerManager) void {
        self.operations_deferred += 1;
    }
    
    // Platform-specific implementations
    
    fn readChargingState(self: *PowerManager) bool {
        _ = self;
        // Linux: /sys/class/power_supply/BAT0/status
        const status_file = std.fs.openFileAbsolute(
            "/sys/class/power_supply/BAT0/status",
            .{},
        ) catch return false;
        defer status_file.close();
        
        var buf: [32]u8 = undefined;
        const bytes_read = status_file.read(&buf) catch return false;
        const status = buf[0..bytes_read];
        
        return std.mem.indexOf(u8, status, "Charging") != null or
               std.mem.indexOf(u8, status, "Full") != null;
    }
    
    fn readBatteryLevel(self: *PowerManager) f32 {
        _ = self;
        // Linux: /sys/class/power_supply/BAT0/capacity
        const capacity_file = std.fs.openFileAbsolute(
            "/sys/class/power_supply/BAT0/capacity",
            .{},
        ) catch return 1.0;
        defer capacity_file.close();
        
        var buf: [8]u8 = undefined;
        const bytes_read = capacity_file.read(&buf) catch return 1.0;
        const capacity_str = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);
        const capacity = std.fmt.parseInt(u8, capacity_str, 10) catch return 1.0;
        
        return @as(f32, @floatFromInt(capacity)) / 100.0;
    }
    
    fn readThermalState(self: *PowerManager) ThermalState {
        _ = self;
        // Linux: /sys/class/thermal/thermal_zone0/temp (millidegrees C)
        const temp_file = std.fs.openFileAbsolute(
            "/sys/class/thermal/thermal_zone0/temp",
            .{},
        ) catch return .normal;
        defer temp_file.close();
        
        var buf: [16]u8 = undefined;
        const bytes_read = temp_file.read(&buf) catch return .normal;
        const temp_str = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);
        const temp_millidegrees = std.fmt.parseInt(i32, temp_str, 10) catch return .normal;
        const temp_celsius = @divTrunc(temp_millidegrees, 1000);
        
        if (temp_celsius > 60) return .critical;
        if (temp_celsius > 50) return .hot;
        if (temp_celsius > 40) return .warm;
        return .normal;
    }
    
    fn calculatePowerMode(self: *PowerManager) PowerMode {
        // Ultra saver: <10% battery (critical)
        // Saver: <20% battery (low)
        // Aggressive: charging + high battery + cool
        // Balanced: everything else
        
        if (self.battery_level < 0.1) {
            return .ultra_saver;  // < 10% battery - critical!
        }
        
        if (self.battery_level < 0.2) {
            return .saver;  // < 20% battery
        }
        
        if (self.is_charging and self.battery_level > 0.5 and self.thermal_state == .normal) {
            return .aggressive;  // Charging, cool, good battery
        }
        
        if (self.thermal_state == .hot or self.thermal_state == .critical) {
            return .saver;  // Too hot, slow down
        }
        
        return .balanced;
    }
    
    pub fn getStats(self: *PowerManager) Stats {
        return .{
            .wake_ups_saved = self.wake_ups_saved,
            .bytes_saved_by_compression = self.bytes_saved_by_compression,
            .operations_deferred = self.operations_deferred,
            .current_mode = self.power_mode,
            .battery_level = self.battery_level,
            .is_charging = self.is_charging,
            .thermal_state = self.thermal_state,
        };
    }
    
    pub const Stats = struct {
        wake_ups_saved: usize,
        bytes_saved_by_compression: usize,
        operations_deferred: usize,
        current_mode: PowerMode,
        battery_level: f32,
        is_charging: bool,
        thermal_state: ThermalState,
    };
};

test "power manager modes" {
    var pm = PowerManager.init();
    
    // Test saver mode (low battery)
    pm.battery_level = 0.15;
    pm.is_charging = false;
    pm.update();
    try std.testing.expect(pm.power_mode == .saver);
    try std.testing.expect(!pm.shouldDoBackgroundWork());
    
    // Test aggressive mode (charging)
    pm.battery_level = 0.8;
    pm.is_charging = true;
    pm.thermal_state = .normal;
    pm.update();
    try std.testing.expect(pm.power_mode == .aggressive);
    try std.testing.expect(pm.shouldDoBackgroundWork());
}

test "power manager compression" {
    var pm = PowerManager.init();
    
    // Aggressive mode: compress > 256 bytes
    pm.power_mode = .aggressive;
    try std.testing.expect(!pm.shouldCompress(200));
    try std.testing.expect(pm.shouldCompress(300));
    
    // Saver mode: compress > 64 bytes
    pm.power_mode = .saver;
    try std.testing.expect(!pm.shouldCompress(50));
    try std.testing.expect(pm.shouldCompress(100));
}
