const std = @import("std");
const sstable = @import("sstable.zig");

test "sstable write and read" {
    const allocator = std.testing.allocator;
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/test.sst") catch {};
    
    // Write SSTable
    {
        var writer = try sstable.SSTableWriter.init(allocator, "/tmp/test.sst", 100);
        defer writer.deinit();
        
        try writer.add("apple", "red fruit");
        try writer.add("banana", "yellow fruit");
        try writer.add("cherry", "red fruit");
        try writer.add("date", "brown fruit");
        try writer.add("elderberry", "purple fruit");
        
        try writer.finish();
    }
    
    // Read SSTable
    {
        var sst = try sstable.SSTable.init(allocator, "/tmp/test.sst");
        defer sst.deinit();
        
        // Test point lookups
        const apple = sst.get("apple");
        try std.testing.expect(apple != null);
        try std.testing.expectEqualStrings("red fruit", apple.?);
        
        const banana = sst.get("banana");
        try std.testing.expect(banana != null);
        try std.testing.expectEqualStrings("yellow fruit", banana.?);
        
        // Test non-existent key
        const grape = sst.get("grape");
        try std.testing.expect(grape == null);
    }
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/test.sst") catch {};
}

test "sstable range scan" {
    const allocator = std.testing.allocator;
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/test_range.sst") catch {};
    
    // Write SSTable with many keys
    {
        var writer = try sstable.SSTableWriter.init(allocator, "/tmp/test_range.sst", 100);
        defer writer.deinit();
        
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "key_{d:0>5}", .{i});
            
            var value_buf: [64]u8 = undefined;
            const value = try std.fmt.bufPrint(&value_buf, "value_{d}", .{i});
            
            try writer.add(key, value);
        }
        
        try writer.finish();
    }
    
    // Read and scan
    {
        var sst = try sstable.SSTable.init(allocator, "/tmp/test_range.sst");
        defer sst.deinit();
        
        // Scan range [key_00010, key_00020)
        var iter = sst.scan("key_00010", "key_00020");
        
        var count: usize = 0;
        while (iter.next()) |kv| {
            _ = kv;
            count += 1;
        }
        
        // Should find 10 keys: key_00010 through key_00019
        try std.testing.expectEqual(@as(usize, 10), count);
    }
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/test_range.sst") catch {};
}

test "sstable bloom filter effectiveness" {
    const allocator = std.testing.allocator;
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/test_bloom.sst") catch {};
    
    // Write SSTable
    {
        var writer = try sstable.SSTableWriter.init(allocator, "/tmp/test_bloom.sst", 1000);
        defer writer.deinit();
        
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "exists_{d}", .{i});
            try writer.add(key, "value");
        }
        
        try writer.finish();
    }
    
    // Test bloom filter
    {
        var sst = try sstable.SSTable.init(allocator, "/tmp/test_bloom.sst");
        defer sst.deinit();
        
        // Keys that exist should return non-null
        const exists = sst.get("exists_500");
        try std.testing.expect(exists != null);
        
        // Keys that don't exist should mostly return null
        // (bloom filter should filter most of them out)
        var false_positives: usize = 0;
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "missing_{d}", .{i});
            if (sst.get(key) != null) {
                false_positives += 1;
            }
        }
        
        // With 10 bits per key, false positive rate should be ~1%
        // Allow up to 5% for this test
        const fp_rate = @as(f64, @floatFromInt(false_positives)) / 1000.0;
        try std.testing.expect(fp_rate < 0.05);
    }
    
    // Clean up
    std.fs.cwd().deleteFile("/tmp/test_bloom.sst") catch {};
}
