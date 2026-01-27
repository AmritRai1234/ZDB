const std = @import("std");
const Database = @import("database_wasm.zig").Database;
const Config = @import("database_wasm.zig").Config;
const SyncMode = @import("database_wasm.zig").SyncMode;

/// WASM-specific allocator (uses page allocator for simplicity)
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

/// Error codes compatible with existing FFI
pub const Error = enum(i32) {
    OK = 0,
    NOT_FOUND = 1,
    CORRUPTION = 2,
    INVALID_KEY = 3,
    OUT_OF_MEMORY = 4,
    IO_ERROR = 5,
    UNKNOWN = 99,
};

/// Opaque database handle (pointer to Database)
pub const DatabaseHandle = *Database;

/// Configuration struct for WASM
pub const WasmConfig = extern struct {
    cache_size: u32,
    compression: u8, // 0 = false, 1 = true
    sync_mode: u8,   // 0 = none, 1 = normal, 2 = full
};

/// Convert WASM error to error code
fn errorToCode(err: anyerror) Error {
    return switch (err) {
        error.NotFound => .NOT_FOUND,
        error.Corruption => .CORRUPTION,
        error.InvalidKey => .INVALID_KEY,
        error.InvalidValue => .INVALID_KEY,
        error.OutOfMemory => .OUT_OF_MEMORY,
        else => .UNKNOWN,
    };
}

/// Open or create a database
/// Returns database handle or null on error
/// Error code is written to error_out if provided
export fn zmdb_wasm_open(
    path_ptr: [*]const u8,
    path_len: usize,
    config_ptr: ?*const WasmConfig,
    error_out: ?*i32,
) ?DatabaseHandle {
    const path = path_ptr[0..path_len];
    
    // Convert WASM config to native config
    const config = if (config_ptr) |cfg| Config{
        .cache_size = cfg.cache_size,
        .compression = cfg.compression != 0,
        .sync_mode = switch (cfg.sync_mode) {
            0 => .none,
            2 => .full,
            else => .normal,
        },
    } else Config{};
    
    const db = allocator.create(Database) catch {
        if (error_out) |err| err.* = @intFromEnum(Error.OUT_OF_MEMORY);
        return null;
    };
    
    db.* = Database.init(allocator, path, config) catch |err| {
        allocator.destroy(db);
        if (error_out) |e| e.* = @intFromEnum(errorToCode(err));
        return null;
    };
    
    if (error_out) |err| err.* = @intFromEnum(Error.OK);
    return db;
}

/// Close database and free resources
export fn zmdb_wasm_close(db: DatabaseHandle) void {
    db.deinit();
    allocator.destroy(db);
}

/// Store a key-value pair
export fn zmdb_wasm_put(
    db: DatabaseHandle,
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) i32 {
    const key = key_ptr[0..key_len];
    const value = value_ptr[0..value_len];
    
    db.put(key, value) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(Error.OK);
}

/// Retrieve a value by key
/// Returns pointer to value data (caller must free with zmdb_wasm_free)
/// value_len_out receives the length of the value
/// Returns null if key not found or error
export fn zmdb_wasm_get(
    db: DatabaseHandle,
    key_ptr: [*]const u8,
    key_len: usize,
    value_len_out: *usize,
) ?[*]u8 {
    const key = key_ptr[0..key_len];
    
    const value = db.get(key, allocator) catch {
        value_len_out.* = 0;
        return null;
    };
    
    value_len_out.* = value.len;
    return value.ptr;
}

/// Delete a key-value pair
export fn zmdb_wasm_delete(
    db: DatabaseHandle,
    key_ptr: [*]const u8,
    key_len: usize,
) i32 {
    const key = key_ptr[0..key_len];
    
    db.delete(key) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(Error.OK);
}

/// Check if a key exists
/// Returns 1 if exists, 0 if not
export fn zmdb_wasm_contains(
    db: DatabaseHandle,
    key_ptr: [*]const u8,
    key_len: usize,
) i32 {
    const key = key_ptr[0..key_len];
    return if (db.contains(key)) 1 else 0;
}

/// Get the number of keys in the database
export fn zmdb_wasm_count(db: DatabaseHandle) usize {
    return db.count();
}

/// Allocate memory (for passing data from JS to WASM)
export fn zmdb_wasm_alloc(size: usize) ?[*]u8 {
    const mem = allocator.alloc(u8, size) catch return null;
    return mem.ptr;
}

/// Free memory allocated by WASM functions
export fn zmdb_wasm_free(ptr: [*]u8, len: usize) void {
    const slice = ptr[0..len];
    allocator.free(slice);
}

/// Get statistics (for debugging/monitoring)
pub const Stats = extern struct {
    total_keys: usize,
    total_reads: usize,
    total_writes: usize,
    bytes_compressed: usize,
    bytes_uncompressed: usize,
};

export fn zmdb_wasm_get_stats(db: DatabaseHandle, stats_out: *Stats) void {
    stats_out.* = .{
        .total_keys = db.count(),
        .total_reads = db.total_reads,
        .total_writes = db.total_writes,
        .bytes_compressed = db.bytes_compressed,
        .bytes_uncompressed = db.bytes_uncompressed,
    };
}
