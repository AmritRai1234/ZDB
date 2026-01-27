/**
 * ZMDB - WebAssembly JavaScript Wrapper
 * High-performance, battery-efficient key-value database for browsers
 */

class ZMDB {
    constructor(wasmInstance, wasmMemory) {
        this.instance = wasmInstance;
        this.memory = wasmMemory;
        this.exports = wasmInstance.exports;
        this.textEncoder = new TextEncoder();
        this.textDecoder = new TextDecoder();
        this.dbHandle = null;
    }

    /**
     * Load and initialize the WASM module
     * @param {string} wasmPath - Path to zmdb.wasm file
     * @returns {Promise<ZMDB>} Initialized ZMDB instance
     */
    static async load(wasmPath = './zmdb.wasm') {
        const response = await fetch(wasmPath);
        const wasmBytes = await response.arrayBuffer();

        const wasmModule = await WebAssembly.compile(wasmBytes);
        const wasmInstance = await WebAssembly.instantiate(wasmModule, {
            env: {
                // Provide any required imports here
            }
        });

        const memory = wasmInstance.exports.memory;
        return new ZMDB(wasmInstance, memory);
    }

    /**
     * Open or create a database
     * @param {string} name - Database name
     * @param {Object} config - Configuration options
     * @returns {Promise<void>}
     */
    async open(name, config = {}) {
        const {
            cacheSize = 4 * 1024 * 1024,
            compression = false,
            syncMode = 1 // 0=none, 1=normal, 2=full
        } = config;

        // Allocate memory for path string
        const pathBytes = this.textEncoder.encode(name);
        const pathPtr = this.exports.zmdb_wasm_alloc(pathBytes.length);
        if (!pathPtr) {
            throw new Error('Failed to allocate memory for database path');
        }

        // Copy path to WASM memory
        // IMPORTANT: Re-read buffer after alloc as memory may have grown
        new Uint8Array(this.memory.buffer, pathPtr, pathBytes.length).set(pathBytes);

        // Create config struct
        const configPtr = this.exports.zmdb_wasm_alloc(12); // 4 + 1 + 1 + padding
        if (!configPtr) {
            this.exports.zmdb_wasm_free(pathPtr, pathBytes.length);
            throw new Error('Failed to allocate memory for config');
        }

        // Re-read buffer after alloc
        const configView = new DataView(this.memory.buffer, configPtr, 12);
        configView.setUint32(0, cacheSize, true);
        configView.setUint8(4, compression ? 1 : 0);
        configView.setUint8(5, syncMode);

        // Allocate error code output
        const errorPtr = this.exports.zmdb_wasm_alloc(4);

        // Open database
        this.dbHandle = this.exports.zmdb_wasm_open(
            pathPtr,
            pathBytes.length,
            configPtr,
            errorPtr
        );

        // CRITICAL: Re-read buffer after WASM call that may grow memory
        const errorCode = new DataView(this.memory.buffer, errorPtr, 4).getInt32(0, true);

        // Free temporary allocations
        this.exports.zmdb_wasm_free(pathPtr, pathBytes.length);
        this.exports.zmdb_wasm_free(configPtr, 12);
        this.exports.zmdb_wasm_free(errorPtr, 4);

        if (!this.dbHandle || errorCode !== 0) {
            throw new Error(`Failed to open database: error code ${errorCode}`);
        }
    }

    /**
     * Store a key-value pair
     * @param {string} key - Key
     * @param {string|Uint8Array} value - Value
     * @returns {Promise<void>}
     */
    async put(key, value) {
        this._checkOpen();

        const keyBytes = this.textEncoder.encode(key);
        const valueBytes = typeof value === 'string'
            ? this.textEncoder.encode(value)
            : value;

        // Allocate memory for key and value
        const keyPtr = this.exports.zmdb_wasm_alloc(keyBytes.length);
        const valuePtr = this.exports.zmdb_wasm_alloc(valueBytes.length);

        if (!keyPtr || !valuePtr) {
            if (keyPtr) this.exports.zmdb_wasm_free(keyPtr, keyBytes.length);
            if (valuePtr) this.exports.zmdb_wasm_free(valuePtr, valueBytes.length);
            throw new Error('Failed to allocate memory');
        }

        // Copy data to WASM memory
        new Uint8Array(this.memory.buffer, keyPtr, keyBytes.length).set(keyBytes);
        new Uint8Array(this.memory.buffer, valuePtr, valueBytes.length).set(valueBytes);

        // Call put
        const errorCode = this.exports.zmdb_wasm_put(
            this.dbHandle,
            keyPtr,
            keyBytes.length,
            valuePtr,
            valueBytes.length
        );

        // Free memory
        this.exports.zmdb_wasm_free(keyPtr, keyBytes.length);
        this.exports.zmdb_wasm_free(valuePtr, valueBytes.length);

        if (errorCode !== 0) {
            throw new Error(`Failed to put key-value: error code ${errorCode}`);
        }
    }

    /**
     * Retrieve a value by key
     * @param {string} key - Key
     * @param {boolean} asString - Return as string (default: true)
     * @returns {Promise<string|Uint8Array|null>} Value or null if not found
     */
    async get(key, asString = true) {
        this._checkOpen();

        const keyBytes = this.textEncoder.encode(key);
        const keyPtr = this.exports.zmdb_wasm_alloc(keyBytes.length);

        if (!keyPtr) {
            throw new Error('Failed to allocate memory for key');
        }

        new Uint8Array(this.memory.buffer, keyPtr, keyBytes.length).set(keyBytes);

        // Allocate for value length output
        const valueLenPtr = this.exports.zmdb_wasm_alloc(8); // size_t

        // Call get
        const valuePtr = this.exports.zmdb_wasm_get(
            this.dbHandle,
            keyPtr,
            keyBytes.length,
            valueLenPtr
        );

        this.exports.zmdb_wasm_free(keyPtr, keyBytes.length);

        if (!valuePtr) {
            this.exports.zmdb_wasm_free(valueLenPtr, 8);
            return null; // Key not found
        }

        const valueLenView = new DataView(this.memory.buffer, valueLenPtr, 8);
        const valueLen = Number(valueLenView.getBigUint64(0, true));
        this.exports.zmdb_wasm_free(valueLenPtr, 8);

        // Copy value from WASM memory
        const valueBytes = new Uint8Array(this.memory.buffer, valuePtr, valueLen).slice();

        // Free the value memory
        this.exports.zmdb_wasm_free(valuePtr, valueLen);

        return asString ? this.textDecoder.decode(valueBytes) : valueBytes;
    }

    /**
     * Delete a key-value pair
     * @param {string} key - Key
     * @returns {Promise<boolean>} True if deleted, false if not found
     */
    async delete(key) {
        this._checkOpen();

        const keyBytes = this.textEncoder.encode(key);
        const keyPtr = this.exports.zmdb_wasm_alloc(keyBytes.length);

        if (!keyPtr) {
            throw new Error('Failed to allocate memory for key');
        }

        new Uint8Array(this.memory.buffer, keyPtr, keyBytes.length).set(keyBytes);

        const errorCode = this.exports.zmdb_wasm_delete(
            this.dbHandle,
            keyPtr,
            keyBytes.length
        );

        this.exports.zmdb_wasm_free(keyPtr, keyBytes.length);

        if (errorCode === 1) { // NOT_FOUND
            return false;
        } else if (errorCode !== 0) {
            throw new Error(`Failed to delete key: error code ${errorCode}`);
        }

        return true;
    }

    /**
     * Check if a key exists
     * @param {string} key - Key
     * @returns {Promise<boolean>}
     */
    async contains(key) {
        this._checkOpen();

        const keyBytes = this.textEncoder.encode(key);
        const keyPtr = this.exports.zmdb_wasm_alloc(keyBytes.length);

        if (!keyPtr) {
            throw new Error('Failed to allocate memory for key');
        }

        new Uint8Array(this.memory.buffer, keyPtr, keyBytes.length).set(keyBytes);

        const result = this.exports.zmdb_wasm_contains(
            this.dbHandle,
            keyPtr,
            keyBytes.length
        );

        this.exports.zmdb_wasm_free(keyPtr, keyBytes.length);

        return result === 1;
    }

    /**
     * Get the number of keys in the database
     * @returns {Promise<number>}
     */
    async count() {
        this._checkOpen();
        return Number(this.exports.zmdb_wasm_count(this.dbHandle));
    }

    /**
     * Get database statistics
     * @returns {Promise<Object>}
     */
    async getStats() {
        this._checkOpen();

        const statsPtr = this.exports.zmdb_wasm_alloc(20); // 5 * 4 bytes (usize on wasm32)
        this.exports.zmdb_wasm_get_stats(this.dbHandle, statsPtr);

        // WASM32 uses 32-bit usize, not 64-bit
        const statsView = new DataView(this.memory.buffer, statsPtr, 20);
        const stats = {
            totalKeys: statsView.getUint32(0, true),
            totalReads: statsView.getUint32(4, true),
            totalWrites: statsView.getUint32(8, true),
            bytesCompressed: statsView.getUint32(12, true),
            bytesUncompressed: statsView.getUint32(16, true)
        };

        this.exports.zmdb_wasm_free(statsPtr, 20);
        return stats;
    }

    /**
     * Close the database
     */
    close() {
        if (this.dbHandle) {
            this.exports.zmdb_wasm_close(this.dbHandle);
            this.dbHandle = null;
        }
    }

    _checkOpen() {
        if (!this.dbHandle) {
            throw new Error('Database is not open. Call open() first.');
        }
    }
}

// Export for both Node.js and browser
if (typeof module !== 'undefined' && module.exports) {
    module.exports = ZMDB;
}
if (typeof window !== 'undefined') {
    window.ZMDB = ZMDB;
}
