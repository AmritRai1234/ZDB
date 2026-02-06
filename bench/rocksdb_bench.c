// RocksDB Benchmark - Direct comparison with ZDB
// Uses the same YCSB-style workloads

#include <math.h>
#include <rocksdb/c.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RECORD_COUNT 100000
#define OPERATION_COUNT 100000
#define VALUE_SIZE 1000
#define KEY_SIZE 24

// Simple timer
static inline uint64_t get_nanos() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

// Simple PRNG
static uint64_t rng_state = 42;
static inline uint64_t next_random() {
  rng_state ^= rng_state >> 12;
  rng_state ^= rng_state << 25;
  rng_state ^= rng_state >> 27;
  return rng_state * 0x2545F4914F6CDD1DULL;
}

// Zipfian-ish distribution (simplified)
static inline uint64_t zipfian_next(uint64_t n) {
  double u = (double)(next_random() % 1000000) / 1000000.0;
  return (uint64_t)(n * (1.0 - pow(u, 0.5)));
}

int main() {
  printf("\n");
  printf("╔══════════════════════════════════════════════════════════════╗\n");
  printf("║     RocksDB YCSB-Style Benchmark                             ║\n");
  printf("║     Direct comparison with ZDB                               ║\n");
  printf("╠══════════════════════════════════════════════════════════════╣\n");
  printf("║  Records: %-8d  Operations: %-8d  Value: %d bytes    ║\n",
         RECORD_COUNT, OPERATION_COUNT, VALUE_SIZE);
  printf(
      "╚══════════════════════════════════════════════════════════════╝\n\n");

  // Setup RocksDB
  rocksdb_options_t *options = rocksdb_options_create();
  rocksdb_options_set_create_if_missing(options, 1);
  rocksdb_options_set_write_buffer_size(options, 64 * 1024 * 1024);
  rocksdb_options_set_max_write_buffer_number(options, 3);
  rocksdb_options_set_target_file_size_base(options, 64 * 1024 * 1024);
  rocksdb_options_increase_parallelism(options, 4);
  rocksdb_options_optimize_level_style_compaction(options, 512 * 1024 * 1024);

  char *err = NULL;
  system("rm -rf /tmp/rocksdb_bench");
  rocksdb_t *db = rocksdb_open(options, "/tmp/rocksdb_bench", &err);
  if (err) {
    fprintf(stderr, "Failed to open RocksDB: %s\n", err);
    return 1;
  }

  rocksdb_writeoptions_t *wopts = rocksdb_writeoptions_create();
  rocksdb_writeoptions_disable_WAL(wopts, 1); // Fair comparison - no sync

  rocksdb_readoptions_t *ropts = rocksdb_readoptions_create();

  // Generate value
  char value[VALUE_SIZE];
  for (int i = 0; i < VALUE_SIZE; i++)
    value[i] = 'x';

  char key[KEY_SIZE];

  // ========== LOAD PHASE ==========
  printf("⏳ Loading %d records...\n", RECORD_COUNT);
  uint64_t start = get_nanos();

  for (int i = 0; i < RECORD_COUNT; i++) {
    snprintf(key, KEY_SIZE, "user%016d", i);
    rocksdb_put(db, wopts, key, strlen(key), value, VALUE_SIZE, &err);
    if (err) {
      fprintf(stderr, "Put error: %s\n", err);
      return 1;
    }
  }

  uint64_t load_time = get_nanos() - start;
  double load_ops = (double)RECORD_COUNT / ((double)load_time / 1e9);
  printf("✅ Loaded in %.1fms (%.0f ops/sec)\n\n", (double)load_time / 1e6,
         load_ops);

  // ========== WORKLOAD A: Update Heavy (50/50) ==========
  printf("Workload A: Update heavy (50/50 read/update)\n");
  start = get_nanos();
  size_t vallen;

  for (int i = 0; i < OPERATION_COUNT; i++) {
    uint64_t idx = zipfian_next(RECORD_COUNT);
    snprintf(key, KEY_SIZE, "user%016lu", idx);

    if (i % 2 == 0) {
      char *val = rocksdb_get(db, ropts, key, strlen(key), &vallen, &err);
      if (val)
        free(val);
    } else {
      rocksdb_put(db, wopts, key, strlen(key), value, VALUE_SIZE, &err);
    }
  }

  uint64_t wa_time = get_nanos() - start;
  printf("  Throughput: %12.0f ops/sec\n",
         (double)OPERATION_COUNT / ((double)wa_time / 1e9));
  printf("  Avg Latency: %10.2f μs/op\n\n",
         ((double)wa_time / 1e3) / OPERATION_COUNT);

  // ========== WORKLOAD B: Read Mostly (95/5) ==========
  printf("Workload B: Read mostly (95/5 read/update)\n");
  start = get_nanos();

  for (int i = 0; i < OPERATION_COUNT; i++) {
    uint64_t idx = zipfian_next(RECORD_COUNT);
    snprintf(key, KEY_SIZE, "user%016lu", idx);

    if (i % 20 == 0) {
      rocksdb_put(db, wopts, key, strlen(key), value, VALUE_SIZE, &err);
    } else {
      char *val = rocksdb_get(db, ropts, key, strlen(key), &vallen, &err);
      if (val)
        free(val);
    }
  }

  uint64_t wb_time = get_nanos() - start;
  printf("  Throughput: %12.0f ops/sec\n",
         (double)OPERATION_COUNT / ((double)wb_time / 1e9));
  printf("  Avg Latency: %10.2f μs/op\n\n",
         ((double)wb_time / 1e3) / OPERATION_COUNT);

  // ========== WORKLOAD C: Read Only (100%) ==========
  printf("Workload C: Read only (100%% read)\n");
  start = get_nanos();

  for (int i = 0; i < OPERATION_COUNT; i++) {
    uint64_t idx = zipfian_next(RECORD_COUNT);
    snprintf(key, KEY_SIZE, "user%016lu", idx);
    char *val = rocksdb_get(db, ropts, key, strlen(key), &vallen, &err);
    if (val)
      free(val);
  }

  uint64_t wc_time = get_nanos() - start;
  printf("  Throughput: %12.0f ops/sec\n",
         (double)OPERATION_COUNT / ((double)wc_time / 1e9));
  printf("  Avg Latency: %10.2f μs/op\n\n",
         ((double)wc_time / 1e3) / OPERATION_COUNT);

  // ========== WORKLOAD F: Read-Modify-Write ==========
  printf("Workload F: Read-modify-write (50/50 read/rmw)\n");
  start = get_nanos();

  for (int i = 0; i < OPERATION_COUNT; i++) {
    uint64_t idx = zipfian_next(RECORD_COUNT);
    snprintf(key, KEY_SIZE, "user%016lu", idx);

    if (i % 2 == 0) {
      char *val = rocksdb_get(db, ropts, key, strlen(key), &vallen, &err);
      if (val)
        free(val);
    } else {
      // Read-modify-write
      char *val = rocksdb_get(db, ropts, key, strlen(key), &vallen, &err);
      if (val) {
        val[0] = 'Y';
        rocksdb_put(db, wopts, key, strlen(key), val, vallen, &err);
        free(val);
      }
    }
  }

  uint64_t wf_time = get_nanos() - start;
  printf("  Throughput: %12.0f ops/sec\n",
         (double)OPERATION_COUNT / ((double)wf_time / 1e9));
  printf("  Avg Latency: %10.2f μs/op\n\n",
         ((double)wf_time / 1e3) / OPERATION_COUNT);

  // Cleanup
  rocksdb_readoptions_destroy(ropts);
  rocksdb_writeoptions_destroy(wopts);
  rocksdb_close(db);
  rocksdb_options_destroy(options);
  system("rm -rf /tmp/rocksdb_bench");

  printf("═══════════════════════════════════════════════════════════════\n");
  printf("                        ROCKSDB COMPLETE                       \n");
  printf("═══════════════════════════════════════════════════════════════\n");

  return 0;
}
