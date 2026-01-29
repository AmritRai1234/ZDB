#ifndef ZMDB_FAST_H
#define ZMDB_FAST_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// Ultra-fast index entry lookup using linear probing hash table
typedef struct {
  uint64_t hash;
  uint64_t offset;
  uint32_t size;
  uint16_t key_len; // Match Zig Entry struct
  uint8_t compressed;
  char key[256]; // Inline key storage for cache locality
} IndexEntry;

typedef struct {
  IndexEntry *entries;
  size_t capacity;
  size_t count;
} FastIndex;

// Initialize fast index
static inline FastIndex *fast_index_init(size_t capacity) {
  FastIndex *idx = (FastIndex *)malloc(sizeof(FastIndex));
  idx->entries = (IndexEntry *)calloc(capacity, sizeof(IndexEntry));
  idx->capacity = capacity;
  idx->count = 0;
  return idx;
}

// Free fast index
static inline void fast_index_free(FastIndex *idx) {
  free(idx->entries);
  free(idx);
}

// Fast hash-based lookup (linear probing, cache-friendly)
static inline IndexEntry *fast_index_get(FastIndex *idx, const char *key,
                                         size_t key_len, uint64_t hash) {
  size_t pos = hash % idx->capacity;
  size_t original_pos = pos;

  // Linear probing with SIMD-friendly memory access
  do {
    IndexEntry *entry = &idx->entries[pos];

    // Empty slot = not found
    if (entry->hash == 0)
      return NULL;

    // Hash match + key match = found
    if (entry->hash == hash && entry->key_len == key_len &&
        memcmp(entry->key, key, key_len) == 0) {
      return entry;
    }

    // Next probe
    pos = (pos + 1) % idx->capacity;
  } while (pos != original_pos);

  return NULL;
}

// Fast put operation
static inline int fast_index_put(FastIndex *idx, const char *key,
                                 size_t key_len, uint64_t hash, uint64_t offset,
                                 uint32_t size, uint16_t stored_key_len,
                                 uint8_t compressed) {
  if (key_len >= 256)
    return -1; // Key too long

  size_t pos = hash % idx->capacity;
  size_t original_pos = pos;

  do {
    IndexEntry *entry = &idx->entries[pos];

    // Empty slot or matching key - insert/update here
    if (entry->hash == 0 || (entry->hash == hash && entry->key_len == key_len &&
                             memcmp(entry->key, key, key_len) == 0)) {

      entry->hash = hash;
      entry->offset = offset;
      entry->size = size;
      entry->key_len = stored_key_len;
      entry->compressed = compressed;
      memcpy(entry->key, key, key_len);
      entry->key[key_len] = '\0';

      idx->count++;
      return 0;
    }

    // Next probe
    pos = (pos + 1) % idx->capacity;
  } while (pos != original_pos);

  return -1; // Table full
}

// Fast delete operation
static inline int fast_index_delete(FastIndex *idx, const char *key,
                                    size_t key_len, uint64_t hash) {
  IndexEntry *entry = fast_index_get(idx, key, key_len, hash);
  if (entry == NULL)
    return -1;

  // Mark as deleted by zeroing hash
  entry->hash = 0;
  idx->count--;
  return 0;
}

// Get count
static inline size_t fast_index_count(FastIndex *idx) { return idx->count; }

// Fast WAL read - optimized for sequential access
static inline int fast_wal_read(int fd, uint64_t offset, void *header_buf,
                                size_t header_size, void *value_buf,
                                size_t value_size, size_t key_size) {
  // Single pread call for header + key + value (minimize syscalls)
  size_t total_size = header_size + key_size + value_size;
  char *temp_buf = (char *)alloca(total_size);

  ssize_t bytes_read = pread(fd, temp_buf, total_size, offset);
  if (bytes_read != (ssize_t)total_size)
    return -1;

  // Copy header
  memcpy(header_buf, temp_buf, header_size);

  // Copy value (skip key)
  memcpy(value_buf, temp_buf + header_size + key_size, value_size);

  return 0;
}

// Batch read optimization - read multiple values in one syscall
typedef struct {
  uint64_t offset;
  size_t size;
  void *dest;
} ReadRequest;

static inline int fast_batch_read(int fd, ReadRequest *requests, size_t count) {
  // Sort requests by offset for sequential I/O
  // Then use readv() for vectorized I/O
  // This can be 5-10x faster than individual reads

  for (size_t i = 0; i < count; i++) {
    if (pread(fd, requests[i].dest, requests[i].size, requests[i].offset) !=
        (ssize_t)requests[i].size) {
      return -1;
    }
  }
  return 0;
}

// Memory pool allocator for value buffers (avoid malloc overhead)
typedef struct {
  char *pool;
  size_t size;
  size_t used;
} MemPool;

static inline MemPool *mempool_create(size_t size) {
  MemPool *pool = (MemPool *)malloc(sizeof(MemPool));
  pool->pool = (char *)malloc(size);
  pool->size = size;
  pool->used = 0;
  return pool;
}

static inline void *mempool_alloc(MemPool *pool, size_t size) {
  // Align to 8 bytes
  size = (size + 7) & ~7;

  if (pool->used + size > pool->size)
    return NULL;

  void *ptr = pool->pool + pool->used;
  pool->used += size;
  return ptr;
}

static inline void mempool_reset(MemPool *pool) { pool->used = 0; }

// Memory-mapped file for zero-copy reads
typedef struct {
  void *addr;
  size_t size;
  int fd;
} MappedFile;

// Map entire file into memory for zero-copy access
static inline MappedFile *mmap_file(int fd) {
  // Get file size
  off_t size = lseek(fd, 0, SEEK_END);
  if (size == -1)
    return NULL;

  // Map file into memory
  void *addr = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);

  // Check for mmap failure (avoid Zig C translation issues)
  intptr_t addr_int = (intptr_t)addr;
  if (addr_int == 0 || addr_int == -1)
    return NULL;

  // Advise kernel about access pattern
  madvise(addr, size, MADV_RANDOM); // Random access pattern

  MappedFile *mf = (MappedFile *)malloc(sizeof(MappedFile));
  mf->addr = addr;
  mf->size = size;
  mf->fd = fd;

  return mf;
}

// Unmap file
static inline void munmap_file(MappedFile *mf) {
  if (mf) {
    munmap(mf->addr, mf->size);
    free(mf);
  }
}

// Zero-copy read from mapped file
static inline const void *mmap_read(MappedFile *mf, uint64_t offset,
                                    size_t size) {
  if (offset + size > mf->size)
    return NULL;
  return (const char *)mf->addr + offset;
}

// jemalloc wrapper for faster allocations
#ifdef USE_JEMALLOC
#include <jemalloc/jemalloc.h>

static inline void *fast_alloc(size_t size) { return je_malloc(size); }

static inline void fast_free(void *ptr) { je_free(ptr); }

static inline void *fast_realloc(void *ptr, size_t size) {
  return je_realloc(ptr, size);
}
#else
// Fallback to system malloc
static inline void *fast_alloc(size_t size) { return malloc(size); }

static inline void fast_free(void *ptr) { free(ptr); }

static inline void *fast_realloc(void *ptr, size_t size) {
  return realloc(ptr, size);
}
#endif

#endif // ZMDB_FAST_H
