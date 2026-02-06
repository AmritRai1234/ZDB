//! io_uring async I/O engine for Linux
//! Falls back to pread/pwrite on other platforms

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// I/O operation type
pub const OpType = enum {
    read,
    write,
    fsync,
};

/// I/O operation request
pub const IoOp = struct {
    type: OpType,
    fd: std.posix.fd_t,
    offset: u64,
    buffer: []u8,
    user_data: usize,
};

/// I/O completion result
pub const IoResult = struct {
    user_data: usize,
    result: i32, // bytes transferred or negative error
    success: bool,
};

/// io_uring-based I/O engine (Linux only)
pub const IoEngine = struct {
    ring: if (builtin.os.tag == .linux) std.os.linux.IoUring else void,
    cqes: if (builtin.os.tag == .linux) []std.os.linux.io_uring_cqe else void,
    allocator: Allocator,
    pending: usize,

    const QUEUE_DEPTH: u32 = 256;

    pub fn init(allocator: Allocator) !IoEngine {
        if (builtin.os.tag == .linux) {
            const ring = try std.os.linux.IoUring.init(QUEUE_DEPTH, 0);
            const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, QUEUE_DEPTH);
            return .{
                .ring = ring,
                .cqes = cqes,
                .allocator = allocator,
                .pending = 0,
            };
        } else {
            return .{
                .ring = {},
                .cqes = {},
                .allocator = allocator,
                .pending = 0,
            };
        }
    }

    pub fn deinit(self: *IoEngine) void {
        if (builtin.os.tag == .linux) {
            self.ring.deinit();
            self.allocator.free(self.cqes);
        }
    }

    /// Submit a batch of I/O operations
    pub fn submitBatch(self: *IoEngine, ops: []const IoOp) !usize {
        if (builtin.os.tag == .linux) {
            return self.submitBatchUring(ops);
        } else {
            return self.submitBatchFallback(ops);
        }
    }

    /// Linux io_uring path
    fn submitBatchUring(self: *IoEngine, ops: []const IoOp) !usize {
        var submitted: usize = 0;

        for (ops) |op| {
            const sqe = self.ring.get_sqe() orelse break;

            switch (op.type) {
                .read => {
                    sqe.prep_read(op.fd, op.buffer, op.offset);
                },
                .write => {
                    sqe.prep_write(op.fd, op.buffer, op.offset);
                },
                .fsync => {
                    sqe.prep_fsync(op.fd, 0);
                },
            }
            sqe.user_data = op.user_data;
            submitted += 1;
        }

        if (submitted > 0) {
            _ = try self.ring.submit();
            self.pending += submitted;
        }

        return submitted;
    }

    /// Fallback for non-Linux: synchronous I/O
    fn submitBatchFallback(self: *IoEngine, ops: []const IoOp) !usize {
        _ = self;
        var success: usize = 0;

        for (ops) |op| {
            switch (op.type) {
                .read => {
                    const file = std.fs.File{ .handle = op.fd };
                    _ = file.preadAll(op.buffer, op.offset) catch continue;
                },
                .write => {
                    const file = std.fs.File{ .handle = op.fd };
                    _ = file.pwriteAll(op.buffer, op.offset) catch continue;
                },
                .fsync => {
                    const file = std.fs.File{ .handle = op.fd };
                    file.sync() catch continue;
                },
            }
            success += 1;
        }

        return success;
    }

    /// Wait for completions
    pub fn waitCompletions(self: *IoEngine, min_complete: u32) ![]IoResult {
        if (builtin.os.tag == .linux) {
            return self.waitCompletionsUring(min_complete);
        } else {
            // Fallback is synchronous, completions are immediate
            return &[_]IoResult{};
        }
    }

    fn waitCompletionsUring(self: *IoEngine, min_complete: u32) ![]IoResult {
        const count = try self.ring.copy_cqes(self.cqes, min_complete);
        self.pending -= count;

        // Convert CQEs to results
        var results = try self.allocator.alloc(IoResult, count);
        for (self.cqes[0..count], 0..) |cqe, i| {
            results[i] = .{
                .user_data = cqe.user_data,
                .result = cqe.res,
                .success = cqe.res >= 0,
            };
        }

        return results;
    }

    /// Submit single read
    pub fn read(self: *IoEngine, fd: std.posix.fd_t, buffer: []u8, offset: u64) !void {
        const ops = [_]IoOp{.{
            .type = .read,
            .fd = fd,
            .offset = offset,
            .buffer = buffer,
            .user_data = 0,
        }};
        _ = try self.submitBatch(&ops);
    }

    /// Submit single write
    pub fn write(self: *IoEngine, fd: std.posix.fd_t, buffer: []u8, offset: u64) !void {
        const ops = [_]IoOp{.{
            .type = .write,
            .fd = fd,
            .offset = offset,
            .buffer = buffer,
            .user_data = 0,
        }};
        _ = try self.submitBatch(&ops);
    }

    /// Get pending count
    pub fn getPending(self: *const IoEngine) usize {
        return self.pending;
    }
};

/// Batch I/O helper for common patterns
pub const BatchIO = struct {
    engine: *IoEngine,
    ops: std.ArrayList(IoOp),
    allocator: Allocator,

    pub fn init(allocator: Allocator, engine: *IoEngine) BatchIO {
        return .{
            .engine = engine,
            .ops = std.ArrayList(IoOp).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BatchIO) void {
        self.ops.deinit();
    }

    pub fn addRead(self: *BatchIO, fd: std.posix.fd_t, buffer: []u8, offset: u64, user_data: usize) !void {
        try self.ops.append(.{
            .type = .read,
            .fd = fd,
            .offset = offset,
            .buffer = buffer,
            .user_data = user_data,
        });
    }

    pub fn addWrite(self: *BatchIO, fd: std.posix.fd_t, buffer: []u8, offset: u64, user_data: usize) !void {
        try self.ops.append(.{
            .type = .write,
            .fd = fd,
            .offset = offset,
            .buffer = buffer,
            .user_data = user_data,
        });
    }

    pub fn submit(self: *BatchIO) !usize {
        defer self.ops.clearRetainingCapacity();
        return self.engine.submitBatch(self.ops.items);
    }

    pub fn clear(self: *BatchIO) void {
        self.ops.clearRetainingCapacity();
    }
};

// Tests
test "io engine init/deinit" {
    const allocator = std.testing.allocator;
    var engine = try IoEngine.init(allocator);
    defer engine.deinit();
}

test "batch io builder" {
    const allocator = std.testing.allocator;
    var engine = try IoEngine.init(allocator);
    defer engine.deinit();

    var batch = BatchIO.init(allocator, &engine);
    defer batch.deinit();

    var buf: [64]u8 = undefined;

    // Add operations (won't actually execute without valid fd)
    try batch.addRead(0, &buf, 0, 1);
    try batch.addRead(0, &buf, 64, 2);

    try std.testing.expectEqual(@as(usize, 2), batch.ops.items.len);

    batch.clear();
    try std.testing.expectEqual(@as(usize, 0), batch.ops.items.len);
}
