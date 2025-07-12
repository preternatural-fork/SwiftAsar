import Foundation
import CryptoKit

// MARK: - File Integrity

/// File integrity information for verifying archive contents.
/// 
/// Asar uses SHA256 hashing with block-based verification to detect corruption
/// and ensure file authenticity. Files are split into blocks for incremental
/// verification of large files.
public struct FileIntegrity: Codable, Sendable, Hashable {
    /// Hashing algorithm used (currently only "SHA256" is supported)
    public let algorithm: String
    
    /// SHA256 hash of the entire file content (hex-encoded)
    public let hash: String
    
    /// Size of each block for incremental verification (default: 4MB)
    /// This matches Electron's default block size for efficient streaming
    public let blockSize: Int
    
    /// SHA256 hashes of individual blocks (hex-encoded)
    /// Allows verification of large files without loading them entirely into memory
    public let blocks: [String]
    
    /// Initialize file integrity information.
    ///
    /// - Parameters:
    ///   - algorithm: Hash algorithm ("SHA256")
    ///   - hash: Full file SHA256 hash
    ///   - blockSize: Block size in bytes (default: 4MB)
    ///   - blocks: Array of block hashes
    public init(algorithm: String = "SHA256", hash: String, blockSize: Int = 4 * 1024 * 1024, blocks: [String]) {
        self.algorithm = algorithm
        self.hash = hash
        self.blockSize = blockSize
        self.blocks = blocks
    }
}

// MARK: - Filesystem Entry Types

public enum FilesystemEntry: Sendable, Hashable {
    case directory(DirectoryEntry)
    case file(FileEntry)
    case symlink(SymlinkEntry)
    
    public var isUnpacked: Bool {
        switch self {
        case .directory(let entry):
            return entry.unpacked
        case .file(let entry):
            return entry.unpacked
        case .symlink(let entry):
            return entry.unpacked
        }
    }
}

public struct DirectoryEntry: Sendable, Hashable {
    public let files: [String: FilesystemEntry]
    public let unpacked: Bool
    
    public init(files: [String: FilesystemEntry] = [:], unpacked: Bool = false) {
        self.files = files
        self.unpacked = unpacked
    }
}

public struct FileEntry: Sendable, Hashable {
    public let unpacked: Bool
    public let executable: Bool
    public let offset: UInt64
    public let size: Int
    public let integrity: FileIntegrity
    
    public init(unpacked: Bool, executable: Bool, offset: UInt64, size: Int, integrity: FileIntegrity) {
        self.unpacked = unpacked
        self.executable = executable
        self.offset = offset
        self.size = size
        self.integrity = integrity
    }
}

public struct SymlinkEntry: Sendable, Hashable {
    public let link: String
    public let unpacked: Bool
    
    public init(link: String, unpacked: Bool = false) {
        self.link = link
        self.unpacked = unpacked
    }
}

// MARK: - Codable Support for FilesystemEntry

extension FilesystemEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case files
        case unpacked
        case executable
        case offset
        case size
        case integrity
        case link
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if container.contains(.files) {
            // Directory entry
            let files = try container.decode([String: FilesystemEntry].self, forKey: .files)
            let unpacked = try container.decodeIfPresent(Bool.self, forKey: .unpacked) ?? false
            self = .directory(DirectoryEntry(files: files, unpacked: unpacked))
        } else if container.contains(.link) {
            // Symlink entry
            let link = try container.decode(String.self, forKey: .link)
            let unpacked = try container.decodeIfPresent(Bool.self, forKey: .unpacked) ?? false
            self = .symlink(SymlinkEntry(link: link, unpacked: unpacked))
        } else {
            // File entry
            let unpacked = try container.decode(Bool.self, forKey: .unpacked)
            let executable = try container.decode(Bool.self, forKey: .executable)
            let offsetString = try container.decode(String.self, forKey: .offset)
            let size = try container.decode(Int.self, forKey: .size)
            let integrity = try container.decode(FileIntegrity.self, forKey: .integrity)
            
            guard let offset = UInt64(offsetString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .offset,
                    in: container,
                    debugDescription: "Invalid offset value: \(offsetString)"
                )
            }
            
            self = .file(FileEntry(
                unpacked: unpacked,
                executable: executable,
                offset: offset,
                size: size,
                integrity: integrity
            ))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .directory(let entry):
            try container.encode(entry.files, forKey: .files)
            if entry.unpacked {
                try container.encode(entry.unpacked, forKey: .unpacked)
            }
            
        case .file(let entry):
            try container.encode(entry.unpacked, forKey: .unpacked)
            try container.encode(entry.executable, forKey: .executable)
            try container.encode(String(entry.offset), forKey: .offset)
            try container.encode(entry.size, forKey: .size)
            try container.encode(entry.integrity, forKey: .integrity)
            
        case .symlink(let entry):
            try container.encode(entry.link, forKey: .link)
            if entry.unpacked {
                try container.encode(entry.unpacked, forKey: .unpacked)
            }
        }
    }
}

// MARK: - Filesystem Navigation

public enum FilesystemError: Error, Sendable {
    case fileNotFound(String)
    case notADirectory(String)
    case invalidPath(String)
    case symlinkLoop(String)
    case symlinkEscapesPackage(String)
}

public struct AsarFilesystem: Sendable {
    public let root: FilesystemEntry
    
    public init(root: FilesystemEntry) {
        self.root = root
    }
    
    public init(from jsonData: Data) throws {
        let decoder = JSONDecoder()
        self.root = try decoder.decode(FilesystemEntry.self, from: jsonData)
    }
    
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(root)
    }
    
    // MARK: - Path Navigation
    
    public func findEntry(at path: String, followSymlinks: Bool = true) throws -> FilesystemEntry {
        var visitedPaths: Set<String> = []
        return try findEntryRecursive(at: normalizePath(path), followSymlinks: followSymlinks, visitedPaths: &visitedPaths)
    }
    
    private func findEntryRecursive(at path: String, followSymlinks: Bool, visitedPaths: inout Set<String>) throws -> FilesystemEntry {
        // Check for symlink loops
        if visitedPaths.contains(path) {
            throw FilesystemError.symlinkLoop(path)
        }
        visitedPaths.insert(path)
        
        let components = pathComponents(path)
        var currentEntry = root
        var currentPath = ""
        
        for component in components {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            
            switch currentEntry {
            case .directory(let dir):
                guard let nextEntry = dir.files[component] else {
                    throw FilesystemError.fileNotFound(currentPath)
                }
                currentEntry = nextEntry
                
            case .file:
                throw FilesystemError.notADirectory(currentPath)
                
            case .symlink(let symlink):
                if !followSymlinks {
                    throw FilesystemError.fileNotFound(currentPath)
                }
                
                let targetPath = try resolveSymlink(symlink.link, relativeTo: String(currentPath.dropLast(component.count + 1)))
                try validateSymlinkTarget(targetPath)
                
                let remainingPath = components.dropFirst(components.firstIndex(of: component)!.advanced(by: 1)).joined(separator: "/")
                let fullTargetPath = remainingPath.isEmpty ? targetPath : "\(targetPath)/\(remainingPath)"
                
                return try findEntryRecursive(at: fullTargetPath, followSymlinks: followSymlinks, visitedPaths: &visitedPaths)
            }
        }
        
        // Handle final symlink resolution
        if followSymlinks, case .symlink(let symlink) = currentEntry {
            let targetPath = try resolveSymlink(symlink.link, relativeTo: String(path.dropLast(pathComponents(path).last!.count + 1)))
            try validateSymlinkTarget(targetPath)
            return try findEntryRecursive(at: targetPath, followSymlinks: followSymlinks, visitedPaths: &visitedPaths)
        }
        
        return currentEntry
    }
    
    public func listFiles(at path: String = "", recursive: Bool = false) throws -> [String] {
        let entry = try findEntry(at: path)
        
        guard case .directory(let dir) = entry else {
            throw FilesystemError.notADirectory(path)
        }
        
        var files: [String] = []
        let basePath = path.isEmpty ? "" : "\(path)/"
        
        for (name, childEntry) in dir.files.sorted(by: { $0.key < $1.key }) {
            let fullPath = "\(basePath)\(name)"
            files.append(fullPath)
            
            if recursive, case .directory = childEntry {
                let subFiles = try listFiles(at: fullPath, recursive: true)
                files.append(contentsOf: subFiles)
            }
        }
        
        return files
    }
    
    // MARK: - Path Utilities
    
    private func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        let normalized = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }
    
    private func pathComponents(_ path: String) -> [String] {
        let normalized = normalizePath(path)
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: "/").filter { !$0.isEmpty }
    }
    
    private func resolveSymlink(_ target: String, relativeTo basePath: String) throws -> String {
        if target.hasPrefix("/") {
            // Absolute symlink - relative to package root
            return normalizePath(target)
        } else {
            // Relative symlink
            let resolvedPath = basePath.isEmpty ? target : "\(basePath)/\(target)"
            return normalizePath(resolvedPath)
        }
    }
    
    private func validateSymlinkTarget(_ target: String) throws {
        // Prevent directory traversal attacks
        let components = pathComponents(target)
        var depth = 0
        
        for component in components {
            if component == ".." {
                depth -= 1
                if depth < 0 {
                    throw FilesystemError.symlinkEscapesPackage(target)
                }
            } else if component != "." {
                depth += 1
            }
        }
    }
}

// MARK: - Filesystem Cache Actor

@globalActor
public actor AsarFilesystemCache {
    public static let shared = AsarFilesystemCache()
    
    private var cache: [String: AsarFilesystem] = [:]
    
    private init() {}
    
    public func getFilesystem(for archivePath: String) -> AsarFilesystem? {
        return cache[archivePath]
    }
    
    public func setFilesystem(_ filesystem: AsarFilesystem, for archivePath: String) {
        cache[archivePath] = filesystem
    }
    
    public func removeFilesystem(for archivePath: String) {
        cache.removeValue(forKey: archivePath)
    }
    
    public func clearCache() {
        cache.removeAll()
    }
}