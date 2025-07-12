import CryptoKit
import Foundation

// MARK: - Asar Errors

public enum AsarError: Error, Sendable {
    case fileNotFound(String)
    case invalidArchive(String)
    case corruptedHeader
    case unsupportedVersion
    case invalidOffset(UInt64)
    case integrityCheckFailed(String)
    case permissionDenied(String)
    case diskFull
    case ioError(String)
    case invalidPath(String)
}

// MARK: - Archive Header

public struct ArchiveHeader: Sendable {
    public let headerSize: Int
    public let filesystem: AsarFilesystem

    public init(headerSize: Int, filesystem: AsarFilesystem) {
        self.headerSize = headerSize
        self.filesystem = filesystem
    }
}

// MARK: - Create Options

public struct CreateOptions: Sendable {
    public let includeDotFiles: Bool
    public let ordering: String?
    public let pattern: String?
    public let unpackPattern: String?
    public let unpackDirPattern: String?

    public init(
        includeDotFiles: Bool = false,
        ordering: String? = nil,
        pattern: String? = nil,
        unpackPattern: String? = nil,
        unpackDirPattern: String? = nil
    ) {
        self.includeDotFiles = includeDotFiles
        self.ordering = ordering
        self.pattern = pattern
        self.unpackPattern = unpackPattern
        self.unpackDirPattern = unpackDirPattern
    }
}

// MARK: - List Options

public struct ListOptions: Sendable {
    public let transform: (@Sendable (String) -> String)?

    public init(transform: (@Sendable (String) -> String)? = nil) {
        self.transform = transform
    }
}

// MARK: - Asar Archive

public class AsarArchive: @unchecked Sendable {
    public let archivePath: String
    public let header: ArchiveHeader

    public init(archivePath: String) async throws {
        self.archivePath = archivePath
        header = try await AsarArchive.readHeader(archivePath: archivePath)
    }

    // MARK: - Archive Reading

    public static func readHeader(archivePath: String) async throws -> ArchiveHeader {
        // Check cache first
        if let cachedFilesystem = await AsarFilesystemCache.shared.getFilesystem(for: archivePath) {
            return ArchiveHeader(headerSize: 0, filesystem: cachedFilesystem) // headerSize will be properly set
        }

        let url = URL(fileURLWithPath: archivePath)

        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw AsarError.fileNotFound(archivePath)
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        // Read the size pickle (first 8 bytes)
        // Asar format: [4-byte payload size][4-byte payload][header pickle][file data]
        // The first pickle contains a UInt32 indicating the size of the header pickle
        let sizePickleData = try fileHandle.read(upToCount: 8)
        guard sizePickleData?.count == 8 else {
            throw AsarError.invalidArchive("Could not read size pickle")
        }

        var sizePickleReader = try PickleReader(data: sizePickleData!)
        let headerSize = try sizePickleReader.readUInt32()

        // Read the header pickle
        let headerPickleData = try fileHandle.read(upToCount: Int(headerSize))
        guard headerPickleData?.count == Int(headerSize) else {
            throw AsarError.invalidArchive("Could not read header pickle")
        }

        var headerPickleReader = try PickleReader(data: headerPickleData!)
        let headerJsonString = try headerPickleReader.readString()

        // Parse the filesystem JSON
        let headerJsonData = Data(headerJsonString.utf8)
        let filesystem = try AsarFilesystem(from: headerJsonData)

        // Cache the filesystem
        await AsarFilesystemCache.shared.setFilesystem(filesystem, for: archivePath)

        return ArchiveHeader(headerSize: Int(headerSize), filesystem: filesystem)
    }

    public func statFile(filename: String, followLinks: Bool = true) async throws -> FilesystemEntry {
        return try header.filesystem.findEntry(at: filename, followSymlinks: followLinks)
    }

    public func listPackage(options: ListOptions = ListOptions()) async throws -> [String] {
        let files = try header.filesystem.listFiles(recursive: true)

        if let transform = options.transform {
            return files.map(transform)
        }

        return files
    }

    public func extractFile(filename: String, followLinks: Bool = true) async throws -> Data {
        let entry = try header.filesystem.findEntry(at: filename, followSymlinks: followLinks)

        guard case let .file(fileEntry) = entry else {
            throw AsarError.invalidPath("Path is not a file: \(filename)")
        }

        if fileEntry.unpacked {
            // File is unpacked, read from .asar.unpacked directory
            let unpackedPath = "\(archivePath).unpacked/\(filename)"
            let url = URL(fileURLWithPath: unpackedPath)
            return try Data(contentsOf: url)
        } else {
            // File is packed, read from archive
            let url = URL(fileURLWithPath: archivePath)
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }

            // Calculate the actual file offset in the archive
            // Format: [8-byte size pickle][header pickle data][file data]
            // File offset = size pickle (8) + header size + file's relative offset
            let actualOffset = 8 + UInt64(header.headerSize) + fileEntry.offset
            try fileHandle.seek(toOffset: actualOffset)

            let fileData = try fileHandle.read(upToCount: fileEntry.size)
            guard fileData?.count == fileEntry.size else {
                throw AsarError.ioError("Could not read complete file data for \(filename)")
            }

            // Verify integrity if available
            if let integrity = fileEntry.integrity {
                try await verifyIntegrity(data: fileData!, integrity: integrity)
            }

            return fileData!
        }
    }

    public func extractAll(to destinationPath: String) async throws {
        let files = try header.filesystem.listFiles(recursive: true)

        let destinationURL = URL(fileURLWithPath: destinationPath)
        let fileManager = FileManager.default

        // Create destination directory if it doesn't exist
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        for filename in files {
            let entry = try header.filesystem.findEntry(at: filename)
            let destinationFileURL = destinationURL.appendingPathComponent(filename)

            // Create parent directories if needed
            let parentURL = destinationFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

            switch entry {
            case .file:
                let fileData = try await extractFile(filename: filename)
                try fileData.write(to: destinationFileURL)

            case .directory:
                try fileManager.createDirectory(at: destinationFileURL, withIntermediateDirectories: true)

            case let .symlink(symlinkEntry):
                // Create symlink
                try fileManager.createSymbolicLink(atPath: destinationFileURL.path, withDestinationPath: symlinkEntry.link)
            }
        }
    }

    // MARK: - Cache Management

    public func uncache() async {
        await AsarFilesystemCache.shared.removeFilesystem(for: archivePath)
    }

    public static func uncacheAll() async {
        await AsarFilesystemCache.shared.clearCache()
    }

    // MARK: - Private Helpers

    private func verifyIntegrity(data: Data, integrity: FileIntegrity) async throws {
        guard integrity.algorithm == "SHA256" else {
            // Only SHA256 is supported for now
            return
        }

        // Verify full file hash
        let fullHash = SHA256.hash(data: data)
        let fullHashString = fullHash.compactMap { String(format: "%02x", $0) }.joined()

        guard fullHashString == integrity.hash else {
            throw AsarError.integrityCheckFailed("File hash mismatch")
        }

        // Verify block hashes
        let blockSize = integrity.blockSize
        var offset = 0

        for (index, expectedBlockHash) in integrity.blocks.enumerated() {
            let endOffset = min(offset + blockSize, data.count)
            let blockData = data.subdata(in: offset ..< endOffset)

            let blockHash = SHA256.hash(data: blockData)
            let blockHashString = blockHash.compactMap { String(format: "%02x", $0) }.joined()

            guard blockHashString == expectedBlockHash else {
                throw AsarError.integrityCheckFailed("Block \(index) hash mismatch")
            }

            offset = endOffset
        }
    }
}
