# 🔋 ZDB - Ultra-Fast Battery-First Database

**1.5x faster than RocksDB** | Zero dependencies | Battery-optimized

[![License](https://img.shields.io/badge/License-Dual%20(Apache%202.0%20%2B%20Commercial)-blue.svg)](LICENSE)

ZDB is built from the ground up with a unique vision: **optimize for battery life first, speed second**. It delivers excellent performance while being smart about power consumption.

## ⚡ Performance (YCSB Benchmark)

Tested head-to-head against RocksDB 9.10 on the same machine:

| Workload | ZDB | RocksDB | Winner |
|----------|-----|---------|--------|
| **Load (writes)** | 791K ops/sec | 495K ops/sec | **ZDB 1.6x faster** |
| **A (50/50 R/W)** | 318K ops/sec | 251K ops/sec | **ZDB 1.27x faster** |
| **B (95/5 R/W)** | 310K ops/sec | 204K ops/sec | **ZDB 1.52x faster** |
| **C (100% Read)** | 359K ops/sec | 235K ops/sec | **ZDB 1.52x faster** |
| **F (Read-Mod-Write)** | 247K ops/sec | 162K ops/sec | **ZDB 1.52x faster** |

```bash
zig build ycsb              # ZDB YCSB benchmark
./bench/rocksdb_bench       # RocksDB comparison
```

## 🎯 Philosophy

Traditional databases optimize for raw throughput. ZDB optimizes for:
- **Battery efficiency** - Adaptive power modes, write batching, minimal wake-ups
- **Storage efficiency** - LZ4/zstd compression (40-70% savings)
- **Developer experience** - Simple, clean API with powerful features

## ✨ Features

### 🔋 Battery-First Design
- Adaptive power modes (aggressive → balanced → ultra_saver)
- Write batching reduces syscalls and wake-ups
- Lock-free sharded index (64 shards)

### ⚡ Zero-Copy Performance
- Memory-mapped I/O for instant reads
- `getInto()` for zero-allocation reads (3.8M ops/sec)
- `getBorrowed()` for borrowed slices

### � Storage Efficiency
- Built-in LZ4 compression
- Compact WAL format
- Efficient index structure

## �🚀 Quick Start

```zig
const TurboDatabase = @import("turbo_database.zig").TurboDatabase;

var db = try TurboDatabase.init(allocator, .{ .path = "mydb.db" });
defer db.deinit();

// Write
try db.put("user:123", "Alice");

// Fast read (zero-allocation)
var buf: [1024]u8 = undefined;
const len = try db.getInto("user:123", &buf);
// buf[0..len] contains "Alice" - no allocation!

// Zero-copy read (borrowed from mmap)
const borrowed = try db.getBorrowed("user:123");
// Don't free borrowed slices!
```

## 🛠️ Building

```bash
zig build                   # Build library
zig build test              # Run tests
zig build bench-turbo       # Performance benchmark
zig build ycsb              # YCSB industry benchmark
zig build build-turbo-wasm  # WebAssembly build
```

## 🎯 Use Cases

- Mobile applications (iOS, Android via FFI)
- Embedded systems & IoT
- Battery-powered devices
- WebAssembly applications
- High-performance caching

## 📜 License

**Dual License Model:**

| Use Case | License | Cost |
|----------|---------|------|
| Open source projects | Apache 2.0 | **Free** |
| Non-profit organizations | Apache 2.0 | **Free** |
| Educational/Academic | Apache 2.0 | **Free** |
| Personal projects | Apache 2.0 | **Free** |
| Commercial/For-profit | Commercial | Contact for pricing |

See [LICENSE](LICENSE) for full details.
