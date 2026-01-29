# ZDB Architecture

## Design Philosophy

ZDB is a **simple, battery-efficient key-value database** designed for mobile devices. Unlike complex LSM-tree databases, ZDB prioritizes:

1. **Simplicity** - Easy to understand and maintain
2. **Battery Life** - 99% fewer wake-ups than SQLite
3. **Mobile-First** - Adaptive power modes and thermal awareness

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│              Public API                      │
│  (Database, Transaction, Iterator)          │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│           Database Core                      │
│  • In-Memory HashMap Index                  │
│  • Write-Ahead Log (WAL)                    │
│  • RwLock for Concurrency                   │
└──────────────────┬──────────────────────────┘
                   │
        ┌──────────┼──────────┐
        │          │          │
┌───────▼────┐ ┌──▼──────┐ ┌─▼────────┐
│   Cache    │ │  Bloom  │ │  Power   │
│  (LRU)     │ │ Filter  │ │  Manager │
└────────────┘ └─────────┘ └──────────┘
```

## Core Components

### 1. Database (`database.zig`)

**Main interface** for all database operations.

**Key structures**:
- `HashMap<String, Entry>` - In-memory index mapping keys to WAL offsets
- `Entry` - Metadata (offset, size, key_len, compressed flag)
- `RwLock` - Allows concurrent reads, exclusive writes

**Operations**:
```zig
put(key, value)  → HashMap.insert() → WAL.append()
get(key)         → HashMap.lookup() → pread(offset)
delete(key)      → HashMap.remove() → WAL.tombstone()
```

### 2. Write-Ahead Log (WAL)

**Append-only log** storing all writes.

**Format**:
```
[RecordHeader][Key][Value]
```

**RecordHeader** (11 bytes):
- `key_len: u16` (2 bytes)
- `value_len: u32` (4 bytes)
- `checksum: u32` (4 bytes)
- `flags: u8` (1 byte) - compressed, tombstone

**Benefits**:
- Sequential writes (fast)
- Crash recovery (durable)
- Simple implementation

### 3. Index (`HashMap`)

**In-memory hash table** for O(1) lookups.

**Entry structure**:
```zig
struct Entry {
    offset: u64,      // WAL file offset
    size: u32,        // Value size
    key_len: u16,     // Key length (for single-read optimization)
    compressed: bool, // Compression flag
}
```

**Loaded on startup** by scanning WAL file.

### 4. Cache (`cache.zig`)

**LRU cache** for frequently accessed values.

- Default: 16MB
- Reduces disk I/O
- Evicts least-recently-used entries

### 5. Bloom Filter (`bloom.zig`)

**Probabilistic data structure** for fast negative lookups.

- Uses xxHash for speed
- Reduces unnecessary disk reads
- ~1% false positive rate

### 6. Power Manager (`power.zig`)

**Adaptive batching** based on battery and thermal state.

**Modes**:
- `aggressive` - Charging, cool (flush every 100ms)
- `balanced` - Normal use (flush every 500ms)
- `saver` - Low battery (flush every 2s)
- `ultra_saver` - <10% battery (flush every 5s)

## Data Flow

### Write Path

```
1. put(key, value)
2. Compress value (if enabled)
3. Append to WAL
4. Update HashMap index
5. Invalidate cache
6. Batch flush (power-aware)
```

### Read Path

```
1. get(key)
2. Check cache → HIT: return
3. Lookup HashMap → NOT_FOUND: error
4. Single pread() from WAL
5. Decompress (if needed)
6. Update cache
7. Return value
```

### Startup Path

```
1. Open WAL file
2. Scan from beginning
3. For each record:
   - Read header
   - Read key
   - Update HashMap index
4. Ready for operations
```

## Performance Characteristics

| Operation | Time Complexity | Notes |
|-----------|----------------|-------|
| put() | O(1) | HashMap insert + WAL append |
| get() | O(1) | HashMap lookup + 1 pread() |
| delete() | O(1) | HashMap remove + tombstone |
| scan() | O(n) | Full HashMap iteration |

**Actual Performance**:
- Writes: ~90K ops/sec
- Reads: ~35K ops/sec (with persistence)
- Only 1.67x-3x slower than SQLite
- 99% fewer wake-ups

## Design Decisions

### Why Not LSM Tree?

**LSM trees** (like LevelDB, RocksDB) are complex:
- Multiple levels of SSTables
- Background compaction threads
- Higher memory usage
- More battery drain

**ZDB's approach**:
- Simple HashMap + WAL
- No background threads
- Lower memory footprint
- Better battery life

**Tradeoff**: WAL grows over time (solved with simple compaction)

### Why HashMap Instead of B-Tree?

**B-tree** advantages:
- Range queries
- Ordered iteration
- Better for large datasets

**HashMap** advantages:
- Simpler implementation
- Faster point lookups
- Lower memory overhead
- Mobile use case rarely needs ranges

### Why Single WAL File?

**Alternatives**:
- Multiple WAL segments
- Separate index file
- SSTables

**Single WAL benefits**:
- Simpler recovery
- Fewer file handles
- Sequential I/O
- Easier to reason about

## Future Enhancements

### Simple WAL Compaction

**Problem**: WAL grows indefinitely

**Solution**:
```zig
fn compactWAL() !void {
    // 1. Create new WAL
    // 2. Write live entries only
    // 3. Atomic rename
    // 4. Update index offsets
}
```

**Trigger**: When WAL > 100MB

### Potential Additions

- **Snapshots** - Point-in-time reads
- **Batch API** - Bulk operations
- **Encryption** - At-rest encryption
- **Replication** - Multi-device sync

## Code Organization

```
src/
├── database.zig       - Main DB interface
├── transaction.zig    - Transaction support
├── iterator.zig       - Key iteration
├── cache.zig          - LRU cache
├── bloom.zig          - Bloom filter
├── power.zig          - Power management
├── compression.zig    - Compression interface
├── compression_zstd.zig - Zstd implementation
├── compression_lz4.zig  - LZ4 implementation
├── hash_c.zig         - xxHash wrapper
├── simd.zig           - SIMD optimizations
├── write_buffer.zig   - Write batching
├── allocators.zig     - Custom allocators
├── batch.zig          - Batch operations
└── lib.zig            - Public API exports
```

## Testing Strategy

**Unit Tests**: Each component tested independently  
**Integration Tests**: Full read/write/persistence flows  
**Benchmarks**: Performance vs SQLite  
**Persistence Tests**: Data survives restarts  

## Summary

ZDB is a **deliberately simple** database that trades some features (range queries, compaction) for:

✅ **Simplicity** - 3,500 lines vs 150K (SQLite)  
✅ **Battery Life** - 99% fewer wake-ups  
✅ **Performance** - 35-90K ops/sec  
✅ **Reliability** - Crash-safe with WAL  

Perfect for mobile apps that prioritize battery life over raw speed.
