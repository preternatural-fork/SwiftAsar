import Foundation

// MARK: - Pickle Constants

/// Constants defining the Pickle binary format specification.
/// These values must match the Chromium Pickle implementation for compatibility.
private enum PickleConstants {
    /// Size of 32-bit integer in bytes (little-endian)
    static let sizeInt32: Int = 4
    
    /// Size of 32-bit unsigned integer in bytes (little-endian)  
    static let sizeUInt32: Int = 4
    
    /// Size of 64-bit integer in bytes (little-endian)
    static let sizeInt64: Int = 8
    
    /// Size of 64-bit unsigned integer in bytes (little-endian)
    static let sizeUInt64: Int = 8
    
    /// Size of 32-bit IEEE 754 float in bytes (little-endian)
    static let sizeFloat: Int = 4
    
    /// Size of 64-bit IEEE 754 double in bytes (little-endian)
    static let sizeDouble: Int = 8
    
    /// Memory allocation granularity for payload data (64-byte alignment)
    /// This ensures efficient memory access patterns and matches Chromium's implementation
    static let payloadUnit: Int = 64
    
    /// Maximum safe integer value in JavaScript (2^53 - 1)
    /// Used to detect read-only pickle buffers in the original Chromium implementation
    static let capacityReadOnly: Int = 9007199254740992
}

// MARK: - Pickle Errors

public enum PickleError: Error, Sendable {
    case insufficientData(requested: Int, available: Int)
    case invalidAlignment
    case bufferTooSmall
    case readPastEnd
    case invalidStringData
}

// MARK: - Pickle Reader

public struct PickleReader: Sendable {
    private let data: Data
    private let payloadOffset: Int
    private var readIndex: Int
    private let endIndex: Int
    
    /// Initialize a PickleReader with binary data.
    /// 
    /// The data format follows Chromium's Pickle specification:
    /// - First 4 bytes: UInt32 payload size (little-endian)
    /// - Remaining bytes: Pickled data payload
    ///
    /// - Parameter data: Binary data containing a complete pickle
    /// - Throws: `PickleError` if data is malformed or insufficient
    public init(data: Data) throws {
        guard data.count >= PickleConstants.sizeUInt32 else {
            throw PickleError.insufficientData(requested: PickleConstants.sizeUInt32, available: data.count)
        }
        
        self.data = data
        
        // Read payload size from first 4 bytes (little-endian UInt32)
        // This header size indicates how many bytes follow containing the actual pickled data
        let payloadSize = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        
        // Payload starts after the 4-byte size header
        self.payloadOffset = PickleConstants.sizeUInt32
        self.readIndex = 0
        self.endIndex = Int(payloadSize)
        
        guard self.payloadOffset + self.endIndex <= data.count else {
            throw PickleError.insufficientData(
                requested: self.payloadOffset + self.endIndex,
                available: data.count
            )
        }
    }
    
    // MARK: - Reading Methods
    
    public mutating func readBool() throws -> Bool {
        return try readInt32() != 0
    }
    
    public mutating func readInt32() throws -> Int32 {
        return try readBytes(count: PickleConstants.sizeInt32) { bytes in
            bytes.loadUnaligned(as: Int32.self).littleEndian
        }
    }
    
    public mutating func readUInt32() throws -> UInt32 {
        return try readBytes(count: PickleConstants.sizeUInt32) { bytes in
            bytes.loadUnaligned(as: UInt32.self).littleEndian
        }
    }
    
    public mutating func readInt64() throws -> Int64 {
        return try readBytes(count: PickleConstants.sizeInt64) { bytes in
            bytes.loadUnaligned(as: Int64.self).littleEndian
        }
    }
    
    public mutating func readUInt64() throws -> UInt64 {
        return try readBytes(count: PickleConstants.sizeUInt64) { bytes in
            bytes.loadUnaligned(as: UInt64.self).littleEndian
        }
    }
    
    public mutating func readFloat() throws -> Float {
        return try readBytes(count: PickleConstants.sizeFloat) { bytes in
            Float(bitPattern: bytes.loadUnaligned(as: UInt32.self).littleEndian)
        }
    }
    
    public mutating func readDouble() throws -> Double {
        return try readBytes(count: PickleConstants.sizeDouble) { bytes in
            Double(bitPattern: bytes.loadUnaligned(as: UInt64.self).littleEndian)
        }
    }
    
    public mutating func readString() throws -> String {
        let length = try readInt32()
        guard length >= 0 else {
            throw PickleError.invalidStringData
        }
        
        let stringData = try readRawBytes(count: Int(length))
        guard let string = String(data: stringData, encoding: .utf8) else {
            throw PickleError.invalidStringData
        }
        
        return string
    }
    
    public mutating func readRawBytes(count: Int) throws -> Data {
        let offset = try getReadPayloadOffsetAndAdvance(length: count)
        return data.subdata(in: offset..<(offset + count))
    }
    
    // MARK: - Private Helpers
    
    private mutating func readBytes<T>(count: Int, loader: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        let offset = try getReadPayloadOffsetAndAdvance(length: count)
        return try data.withUnsafeBytes { bytes in
            let range = offset..<(offset + count)
            guard range.upperBound <= bytes.count else {
                throw PickleError.readPastEnd
            }
            return try loader(UnsafeRawBufferPointer(rebasing: bytes[range]))
        }
    }
    
    private mutating func getReadPayloadOffsetAndAdvance(length: Int) throws -> Int {
        guard length <= endIndex - readIndex else {
            readIndex = endIndex
            throw PickleError.insufficientData(requested: length, available: endIndex - readIndex)
        }
        
        let readPayloadOffset = payloadOffset + readIndex
        try advance(size: length)
        return readPayloadOffset
    }
    
    /// Advance the read position by the specified number of bytes.
    /// Data is always aligned to 4-byte boundaries per Pickle specification.
    ///
    /// - Parameter size: Number of bytes to advance
    private mutating func advance(size: Int) throws {
        // All pickle data must be aligned to 4-byte (UInt32) boundaries
        // This matches Chromium's pickle implementation and ensures consistent layout
        let alignedSize = alignInt(size, alignment: PickleConstants.sizeUInt32)
        if endIndex - readIndex < alignedSize {
            readIndex = endIndex
        } else {
            readIndex += alignedSize
        }
    }
}

// MARK: - Pickle Writer

public struct PickleWriter: Sendable {
    private var data: Data
    private let headerSize: Int
    private var writeOffset: Int
    
    public init() {
        self.headerSize = PickleConstants.sizeUInt32
        self.data = Data(count: headerSize + PickleConstants.payloadUnit)
        self.writeOffset = 0
        
        // Initialize payload size to 0
        setPayloadSize(0)
    }
    
    public func toData() -> Data {
        return data.prefix(headerSize + getPayloadSize())
    }
    
    // MARK: - Writing Methods
    
    public mutating func writeBool(_ value: Bool) throws {
        try writeInt32(value ? 1 : 0)
    }
    
    public mutating func writeInt32(_ value: Int32) throws {
        try writeBytes(count: PickleConstants.sizeInt32) { pointer in
            pointer.storeBytes(of: value.littleEndian, as: Int32.self)
        }
    }
    
    public mutating func writeUInt32(_ value: UInt32) throws {
        try writeBytes(count: PickleConstants.sizeUInt32) { pointer in
            pointer.storeBytes(of: value.littleEndian, as: UInt32.self)
        }
    }
    
    public mutating func writeInt64(_ value: Int64) throws {
        try writeBytes(count: PickleConstants.sizeInt64) { pointer in
            pointer.storeBytes(of: value.littleEndian, as: Int64.self)
        }
    }
    
    public mutating func writeUInt64(_ value: UInt64) throws {
        try writeBytes(count: PickleConstants.sizeUInt64) { pointer in
            pointer.storeBytes(of: value.littleEndian, as: UInt64.self)
        }
    }
    
    public mutating func writeFloat(_ value: Float) throws {
        try writeUInt32(value.bitPattern)
    }
    
    public mutating func writeDouble(_ value: Double) throws {
        try writeUInt64(value.bitPattern)
    }
    
    public mutating func writeString(_ value: String) throws {
        let stringData = Data(value.utf8)
        try writeInt32(Int32(stringData.count))
        try writeRawBytes(stringData)
    }
    
    public mutating func writeRawBytes(_ bytes: Data) throws {
        let length = bytes.count
        let alignedLength = alignInt(length, alignment: PickleConstants.sizeUInt32)
        let newSize = writeOffset + alignedLength
        
        // Resize if necessary
        while newSize > data.count - headerSize {
            let newCapacity = max((data.count - headerSize) * 2, newSize)
            data.count = headerSize + alignInt(newCapacity, alignment: PickleConstants.payloadUnit)
        }
        
        // Write the data
        let writeRange = (headerSize + writeOffset)..<(headerSize + writeOffset + length)
        data.replaceSubrange(writeRange, with: bytes)
        
        // Zero-fill alignment padding
        if alignedLength > length {
            let paddingRange = (headerSize + writeOffset + length)..<(headerSize + writeOffset + alignedLength)
            data.resetBytes(in: paddingRange)
        }
        
        setPayloadSize(newSize)
        writeOffset = newSize
    }
    
    // MARK: - Private Helpers
    
    private mutating func writeBytes(count: Int, writer: (UnsafeMutableRawPointer) -> Void) throws {
        let alignedCount = alignInt(count, alignment: PickleConstants.sizeUInt32)
        let newSize = writeOffset + alignedCount
        
        // Resize if necessary
        while newSize > data.count - headerSize {
            let newCapacity = max((data.count - headerSize) * 2, newSize)
            data.count = headerSize + alignInt(newCapacity, alignment: PickleConstants.payloadUnit)
        }
        
        // Write the data
        data.withUnsafeMutableBytes { bytes in
            let writePointer = bytes.baseAddress!.advanced(by: headerSize + writeOffset)
            writer(writePointer)
            
            // Zero-fill alignment padding
            if alignedCount > count {
                let paddingPointer = writePointer.advanced(by: count)
                paddingPointer.initializeMemory(as: UInt8.self, repeating: 0, count: alignedCount - count)
            }
        }
        
        setPayloadSize(newSize)
        writeOffset = newSize
    }
    
    private mutating func setPayloadSize(_ size: Int) {
        data.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt32(size).littleEndian, toByteOffset: 0, as: UInt32.self)
        }
    }
    
    private func getPayloadSize() -> Int {
        return data.withUnsafeBytes { bytes in
            Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian)
        }
    }
}

// MARK: - Utility Functions

/// Align an integer value to the specified boundary.
/// 
/// This ensures data is properly aligned for efficient memory access and 
/// maintains compatibility with Chromium's Pickle format which requires
/// 4-byte alignment for all data elements.
///
/// - Parameters:
///   - value: The value to align
///   - alignment: The alignment boundary (typically 4 for UInt32 alignment)
/// - Returns: The aligned value (always >= original value)
private func alignInt(_ value: Int, alignment: Int) -> Int {
    return value + ((alignment - (value % alignment)) % alignment)
}