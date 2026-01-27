package com.zmdb;

/**
 * ZMDB - Zig Mobile Database for Android
 * High-performance embedded database optimized for mobile devices
 */
public class ZMDB {
    
    static {
        System.loadLibrary("zmdb");
    }
    
    private long nativeHandle;
    
    public static class Config {
        public int cacheSize = 4 * 1024 * 1024; // 4MB
        public boolean compressionEnabled = true;
        public int syncMode = 1; // 0=none, 1=normal, 2=full
    }
    
    public enum Error {
        OK(0),
        NOT_FOUND(1),
        CORRUPTION(2),
        INVALID_KEY(3),
        OUT_OF_MEMORY(4),
        IO_ERROR(5);
        
        private final int code;
        
        Error(int code) {
            this.code = code;
        }
        
        public static Error fromCode(int code) {
            for (Error e : values()) {
                if (e.code == code) return e;
            }
            return IO_ERROR;
        }
    }
    
    public static class ZMDBException extends Exception {
        private final Error error;
        
        public ZMDBException(Error error) {
            super("ZMDB Error: " + error.name());
            this.error = error;
        }
        
        public Error getError() {
            return error;
        }
    }
    
    /**
     * Open a database
     */
    public ZMDB(String path, Config config) throws ZMDBException {
        int result = nativeOpen(path, config.cacheSize, 
                               config.compressionEnabled ? 1 : 0,
                               config.syncMode);
        if (result != 0) {
            throw new ZMDBException(Error.fromCode(result));
        }
    }
    
    /**
     * Open a database with default configuration
     */
    public ZMDB(String path) throws ZMDBException {
        this(path, new Config());
    }
    
    /**
     * Close the database
     */
    public void close() {
        if (nativeHandle != 0) {
            nativeClose(nativeHandle);
            nativeHandle = 0;
        }
    }
    
    /**
     * Store a key-value pair
     */
    public void put(byte[] key, byte[] value) throws ZMDBException {
        int result = nativePut(nativeHandle, key, value);
        if (result != 0) {
            throw new ZMDBException(Error.fromCode(result));
        }
    }
    
    /**
     * Retrieve a value by key
     */
    public byte[] get(byte[] key) throws ZMDBException {
        byte[] value = nativeGet(nativeHandle, key);
        if (value == null) {
            throw new ZMDBException(Error.NOT_FOUND);
        }
        return value;
    }
    
    /**
     * Delete a key-value pair
     */
    public void delete(byte[] key) throws ZMDBException {
        int result = nativeDelete(nativeHandle, key);
        if (result != 0) {
            throw new ZMDBException(Error.fromCode(result));
        }
    }
    
    /**
     * Check if a key exists
     */
    public boolean contains(byte[] key) {
        return nativeContains(nativeHandle, key);
    }
    
    /**
     * Get the number of entries
     */
    public long count() {
        return nativeCount(nativeHandle);
    }
    
    @Override
    protected void finalize() throws Throwable {
        close();
        super.finalize();
    }
    
    // Native methods
    private native int nativeOpen(String path, int cacheSize, int compression, int syncMode);
    private native void nativeClose(long handle);
    private native int nativePut(long handle, byte[] key, byte[] value);
    private native byte[] nativeGet(long handle, byte[] key);
    private native int nativeDelete(long handle, byte[] key);
    private native boolean nativeContains(long handle, byte[] key);
    private native long nativeCount(long handle);
}
