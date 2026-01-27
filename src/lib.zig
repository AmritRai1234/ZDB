const std = @import("std");

pub const Database = @import("database.zig").Database;
pub const Config = @import("database.zig").Config;
pub const Transaction = @import("transaction.zig").Transaction;
pub const Iterator = @import("iterator.zig").Iterator;

// Error types
pub const Error = error{
    NotFound,
    Corruption,
    InvalidKey,
    InvalidValue,
    TransactionConflict,
    OutOfSpace,
};

test {
    std.testing.refAllDecls(@This());
}
