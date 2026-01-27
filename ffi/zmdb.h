#ifndef ZMDB_H
#define ZMDB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle types
typedef struct zmdb_database zmdb_database_t;
typedef struct zmdb_transaction zmdb_transaction_t;
typedef struct zmdb_iterator zmdb_iterator_t;

// Error codes
typedef enum {
    ZMDB_OK = 0,
    ZMDB_ERROR_NOT_FOUND = 1,
    ZMDB_ERROR_CORRUPTION = 2,
    ZMDB_ERROR_INVALID_KEY = 3,
    ZMDB_ERROR_OUT_OF_MEMORY = 4,
    ZMDB_ERROR_IO = 5,
} zmdb_error_t;

// Configuration
typedef struct {
    size_t cache_size;
    int compression_enabled;
    int sync_mode; // 0=none, 1=normal, 2=full
} zmdb_config_t;

// Database operations
zmdb_error_t zmdb_open(const char* path, zmdb_config_t* config, zmdb_database_t** db);
void zmdb_close(zmdb_database_t* db);

zmdb_error_t zmdb_put(zmdb_database_t* db, const uint8_t* key, size_t key_len, 
                      const uint8_t* value, size_t value_len);
zmdb_error_t zmdb_get(zmdb_database_t* db, const uint8_t* key, size_t key_len,
                      uint8_t** value, size_t* value_len);
zmdb_error_t zmdb_delete(zmdb_database_t* db, const uint8_t* key, size_t key_len);
int zmdb_contains(zmdb_database_t* db, const uint8_t* key, size_t key_len);
size_t zmdb_count(zmdb_database_t* db);

// Memory management
void zmdb_free(void* ptr);

// Transaction operations
zmdb_error_t zmdb_begin_transaction(zmdb_database_t* db, zmdb_transaction_t** tx);
zmdb_error_t zmdb_transaction_put(zmdb_transaction_t* tx, const uint8_t* key, size_t key_len,
                                  const uint8_t* value, size_t value_len);
zmdb_error_t zmdb_transaction_delete(zmdb_transaction_t* tx, const uint8_t* key, size_t key_len);
zmdb_error_t zmdb_transaction_commit(zmdb_transaction_t* tx);
void zmdb_transaction_rollback(zmdb_transaction_t* tx);

// Iterator operations
zmdb_error_t zmdb_iterator_create(zmdb_database_t* db, const uint8_t* start, size_t start_len,
                                  const uint8_t* end, size_t end_len, zmdb_iterator_t** iter);
int zmdb_iterator_next(zmdb_iterator_t* iter, uint8_t** key, size_t* key_len,
                       uint8_t** value, size_t* value_len);
void zmdb_iterator_destroy(zmdb_iterator_t* iter);

#ifdef __cplusplus
}
#endif

#endif // ZMDB_H
