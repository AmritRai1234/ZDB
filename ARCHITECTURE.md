# ZDB Architecture - Hybrid Design

## Philosophy

ZDB combines the best parts of proven database architectures to create the ultimate **battery-first** embedded database:

- **Hash Table** - Very fast point lookups (5M/sec)
- **LSM Tree** - Excellent write batching and space efficiency
- **Columnar** - Superior compression for cold data
- **Memory-Mapped I/O** - Zero-copy reads (4.9M/sec)

## Current Architecture (v0.1)

### Layer 1: Hot Path ✅
**Hash Table + mmap for recent data**

```
┌─────────────────────────────────────┐
│  C Hash Table (5M lookups/sec)     │
│  - Linear probing                   │
│  - Cache-friendly                   │
│  - Inline keys (256 bytes)          │
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│  Memory-Mapped WAL                  │
│  - Zero-copy reads (4.9M/sec)       │
│  - getBorrowed() API                │
│  - Lazy initialization              │
└─────────────────────────────────────┘
```

**Performance:**
- Point reads: 4.9M/sec (zero-copy)
- Point reads: 76K/sec (with allocation)
- Writes: 71K/sec
- Index lookups: 5M/sec

## Future Architecture (v0.2+)

### Layer 2: Warm Path (LSM-inspired)
**SSTables for historical data**

```
┌─────────────────────────────────────┐
│  Sorted String Tables (SSTables)    │
│  - Sorted key-value pairs           │
│  - Bloom filters per table          │
│  - Memory-mapped for zero-copy      │
│  - Range query support              │
└─────────────────────────────────────┘
```

**Benefits:**
- Range queries (currently missing)
- Better space efficiency (60-80% compression)
- Faster writes (batched)

### Layer 3: Cold Path (Columnar-inspired)
**Column storage for archived data**

```
┌─────────────────────────────────────┐
│  Columnar Storage                   │
│  - Column-oriented layout           │
│  - Per-column compression           │
│  - Analytics-friendly               │
│  - 70-90% compression               │
└─────────────────────────────────────┘
```

**Benefits:**
- Superior compression
- Fast analytical queries
- Minimal battery impact

## Data Flow

### Write Path
```
1. Write to WAL (append-only)
2. Update hash table index
3. Background: Flush to SSTables (battery-aware)
4. Background: Compact to columnar (battery-aware)
```

### Read Path
```
1. Check hash table (hot data) → 4.9M/sec
2. Check SSTables (warm data) → 100K/sec
3. Check columnar (cold data) → fast analytics
```

## Key Components

### 1. C Hash Table
- **Linear probing** for cache-friendly lookups
- **Inline keys** (256 bytes) for locality
- **Wyhash** for fast hashing
- **5M lookups/sec**

### 2. Memory-Mapped I/O
- **Zero-copy reads** from WAL
- **Lazy initialization** (works with growing files)
- **getBorrowed() API** for borrowed slices
- **4.9M reads/sec**

### 3. Write-Ahead Log (WAL)
- **Append-only** for fast writes
- **Compact format** for efficiency
- **Memory-mapped** for zero-copy reads

### 4. Battery-Aware Scheduling
- **Adaptive power modes** (aggressive → ultra_saver)
- **Thermal throttling** awareness
- **Background compaction** only when safe

## Performance Characteristics

| Operation | Current | Target (v0.2) |
|-----------|---------|---------------|
| Point reads (zero-copy) | 4.9M/sec | 5M/sec |
| Point reads (standard) | 76K/sec | 100K/sec |
| Range scans | N/A | 100K/sec |
| Writes | 71K/sec | 200K/sec |
| Compression | 40-70% | 70-90% |

## Design Principles

1. **Battery First** - Minimize wake-ups, adaptive scheduling
2. **Zero-Copy** - mmap everywhere possible
3. **Simple API** - Key-value with optional zero-copy
4. **Hybrid Storage** - Best architecture for each use case
5. **Adaptive** - Automatic hot→warm→cold migration

## Concurrency Model

- **Concurrent reads** - Multiple readers with shared lock
- **Exclusive writes** - Single writer with exclusive lock
- **Lock-free index** - C hash table with atomic operations

## File Format

### WAL Format (Current)
```
[RecordHeader][Key][Value]
- RecordHeader: offset, size, key_len, compressed
- Key: variable length
- Value: variable length (optionally compressed)
```

### SSTable Format (Future)
```
[Index Block][Data Blocks][Bloom Filter]
- Sorted by key
- Block-based for efficient range scans
- Bloom filter for fast negative lookups
```

### Columnar Format (Future)
```
[Column 1][Column 2][...]
- Per-column compression
- Optimized for analytics
- Minimal battery impact
```

## Why This Architecture?

### vs Pure Hash Table
✅ **Keep:** Fast point lookups  
✅ **Add:** Range queries (LSM)  
✅ **Add:** Better compression (Columnar)

### vs Pure LSM
✅ **Keep:** Write batching  
✅ **Add:** Faster point lookups (Hash)  
✅ **Add:** Zero-copy reads (mmap)

### vs Pure B-Tree
✅ **Keep:** Range queries  
✅ **Add:** Faster writes (LSM)  
✅ **Skip:** Complex balancing (battery drain)

### vs Pure Columnar
✅ **Keep:** Compression  
✅ **Add:** Fast point lookups (Hash)  
✅ **Add:** Fast writes (LSM)

## Future Roadmap

- [ ] **v0.2**: LSM integration (range queries, better compression)
- [ ] **v0.3**: Columnar storage (analytics, cold data)
- [ ] **v0.4**: Adaptive tiering (automatic optimization)
- [ ] **v1.0**: Production-ready hybrid database

**ZDB: The world's first battery-first hybrid database!** 🔋⚡
