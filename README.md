# 🔋 ZDB - Battery-First Database

**A high-performance embedded database designed for mobile devices and battery efficiency.**

ZDB is built from the ground up with a unique vision: **optimize for battery life first, speed second**. It's not trying to be the fastest database - it's trying to be the smartest about power consumption while still delivering excellent performance.

## 🎯 Philosophy

Traditional databases optimize for raw throughput. ZDB optimizes for:
- **Battery efficiency** - Adaptive power modes, write batching, minimal wake-ups
- **Storage efficiency** - Real compression (40-70% savings)
- **Developer experience** - Simple, clean API with powerful features

## ✨ Features

### � Battery-First Design
- Adaptive power modes (aggressive → balanced → ultra_saver)
- Write batching reduces syscalls and wake-ups
- Blocked bloom filters for cache efficiency

### ⚡ Zero-Copy Performance
- Memory-mapped I/O for instant reads
- `getBorrowed()` API for zero-allocation reads (4.9M ops/sec)
- C-optimized hash table (5M lookups/sec)

### 💾 Storage Efficiency
- Built-in zstd compression (40-70% savings)
- Compact WAL format
- Efficient index structure

### 🎨 Developer Experience
- Simple key-value API
- Thread-safe operations (concurrent reads, exclusive writes)
- Zero-copy reads when you need them

## 🚀 Quick Start

```zig
const Database = @import("database.zig").Database;

var db = try Database.init(allocator, "mydb.db", .{});
defer db.deinit();

// Write
try db.put("user:123", "Alice");

// Read (owned copy)
const value = try db.get("user:123", allocator);
defer allocator.free(value);

// Read (zero-copy, borrowed from mmap)
const borrowed = try db.getBorrowed("user:123");
// Don't free borrowed slices!
```

## � Performance

| Operation | Throughput |
|-----------|------------|
| Writes | 71K ops/sec |
| Reads (standard) | 76K ops/sec |
| Reads (zero-copy) | **4.9M ops/sec** ⚡ |
| Index lookups | 5M ops/sec |

## 🏗️ Architecture

- **C Hash Table**: Linear probing for cache-friendly lookups
- **Memory-Mapped I/O**: Zero-copy reads from WAL
- **Write Batching**: Reduces syscalls and power consumption
- **Adaptive Compression**: zstd for values when beneficial

## 🛠️ Building

```bash
zig build
zig build test
zig build bench-simple     # Standard benchmark
zig build bench-zerocopy   # Zero-copy performance
```

## 🎯 Use Cases

Perfect for:
- Mobile applications (iOS, Android)
- Embedded systems
- Battery-powered devices
- Applications that need fast reads with minimal power draw

## 📜 License

MIT
