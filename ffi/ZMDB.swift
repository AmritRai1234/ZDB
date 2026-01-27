// Swift wrapper for ZMDB
// Usage: import this file in your iOS project

import Foundation

public enum ZMDBError: Error {
    case notFound
    case corruption
    case invalidKey
    case outOfMemory
    case ioError
    case unknown(Int32)
}

public class ZMDBConfig {
    public var cacheSize: Int = 4 * 1024 * 1024
    public var compressionEnabled: Bool = true
    public var syncMode: Int32 = 1 // 0=none, 1=normal, 2=full
    
    public init() {}
}

public class ZMDBDatabase {
    private var handle: OpaquePointer?
    
    public init(path: String, config: ZMDBConfig = ZMDBConfig()) throws {
        var cConfig = zmdb_config_t(
            cache_size: config.cacheSize,
            compression_enabled: config.compressionEnabled ? 1 : 0,
            sync_mode: config.syncMode
        )
        
        var db: OpaquePointer?
        let result = path.withCString { pathPtr in
            zmdb_open(pathPtr, &cConfig, &db)
        }
        
        guard result == ZMDB_OK else {
            throw ZMDBError.from(result)
        }
        
        self.handle = db
    }
    
    deinit {
        if let handle = handle {
            zmdb_close(handle)
        }
    }
    
    public func put(key: Data, value: Data) throws {
        guard let handle = handle else { throw ZMDBError.unknown(-1) }
        
        let result = key.withUnsafeBytes { keyPtr in
            value.withUnsafeBytes { valuePtr in
                zmdb_put(handle, 
                        keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        key.count,
                        valuePtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        value.count)
            }
        }
        
        guard result == ZMDB_OK else {
            throw ZMDBError.from(result)
        }
    }
    
    public func get(key: Data) throws -> Data {
        guard let handle = handle else { throw ZMDBError.unknown(-1) }
        
        var valuePtr: UnsafeMutablePointer<UInt8>?
        var valueLen: Int = 0
        
        let result = key.withUnsafeBytes { keyPtr in
            zmdb_get(handle,
                    keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    key.count,
                    &valuePtr,
                    &valueLen)
        }
        
        guard result == ZMDB_OK else {
            throw ZMDBError.from(result)
        }
        
        guard let ptr = valuePtr else {
            throw ZMDBError.notFound
        }
        
        let data = Data(bytes: ptr, count: valueLen)
        zmdb_free(ptr)
        
        return data
    }
    
    public func delete(key: Data) throws {
        guard let handle = handle else { throw ZMDBError.unknown(-1) }
        
        let result = key.withUnsafeBytes { keyPtr in
            zmdb_delete(handle,
                       keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                       key.count)
        }
        
        guard result == ZMDB_OK else {
            throw ZMDBError.from(result)
        }
    }
    
    public func contains(key: Data) -> Bool {
        guard let handle = handle else { return false }
        
        return key.withUnsafeBytes { keyPtr in
            zmdb_contains(handle,
                         keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                         key.count) != 0
        }
    }
    
    public var count: Int {
        guard let handle = handle else { return 0 }
        return zmdb_count(handle)
    }
}

extension ZMDBError {
    static func from(_ code: zmdb_error_t) -> ZMDBError {
        switch code {
        case ZMDB_ERROR_NOT_FOUND: return .notFound
        case ZMDB_ERROR_CORRUPTION: return .corruption
        case ZMDB_ERROR_INVALID_KEY: return .invalidKey
        case ZMDB_ERROR_OUT_OF_MEMORY: return .outOfMemory
        case ZMDB_ERROR_IO: return .ioError
        default: return .unknown(code)
        }
    }
}
