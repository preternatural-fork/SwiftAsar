# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftAsar is a Swift parser for Asar archives. This project includes a reference TypeScript implementation from the Electron Asar project (`electron-asar/` directory) that serves as the specification and inspiration for the Swift implementation.

## Development Commands

### Building
```bash
swift build
```

### Testing
```bash
# Run all tests
swift test

# Run tests with specific filter patterns
swift test --filter <pattern>
```

### Project Structure
```bash
# Generate Xcode project (if needed for IDE support)
swift package generate-xcodeproj
```

## Asar Format Architecture

The Asar format consists of:

1. **Header Structure**: Uses Pickle serialization with a 4-byte header size followed by JSON metadata
2. **File Data**: Concatenated file contents with offset/size tracking
3. **Key Components**:
   - `Pickle`: Binary serialization format (similar to Chrome's pickle.h)
   - `Filesystem`: JSON structure containing file metadata (offset, size, integrity, executable flags)
   - File integrity verification with SHA256 hashes and block-based validation

### Reference Implementation Modules

The TypeScript reference implementation in `electron-asar/src/` provides these key modules:

- `pickle.ts`: Binary serialization/deserialization (Pickle format)
- `filesystem.ts`: File metadata structure and manipulation
- `disk.ts`: Low-level archive read/write operations
- `asar.ts`: Main API for creating and extracting archives
- `integrity.ts`: File integrity verification with SHA256
- `crawlfs.ts`: File system traversal utilities

### Asar Archive Format

```
| UInt32: header_size | String: header | Bytes: file1 | ... | Bytes: fileN |
```

The header is JSON containing a nested file structure with:
- `offset`: String representation of UInt64 byte offset
- `size`: File size in bytes (JavaScript Number, max 8PB)
- `integrity`: SHA256 hash and block-based verification
- `executable`: Boolean flag for executable files
- `unpacked`: Boolean for files stored outside the archive

## Swift Implementation Status

### ✅ Phase 1 Complete: Core Infrastructure
1. **AsarPickle**: Complete binary serialization with `PickleReader` and `PickleWriter` structs
2. **AsarFilesystem**: JSON-based filesystem structure with path navigation and security validation  
3. **AsarArchive**: Main API with async methods for reading archives
4. **Error Handling**: Comprehensive error types with proper Swift patterns
5. **Testing**: Full test suite covering all core functionality

### 🏗️ Next Implementation Phases
1. **Archive Creation**: File discovery, integrity calculation, and archive writing
2. **Advanced Features**: File transformations, symlink validation, and performance optimizations
3. **Compatibility Testing**: Validation against TypeScript reference implementation test fixtures

### Modern Swift Features Used
- **Sendable**: All data structures are safe for concurrency
- **Actors**: `AsarFilesystemCache` for thread-safe caching
- **Async/Await**: All I/O operations use modern concurrency
- **CryptoKit**: SHA256 integrity verification
- **Structured Concurrency**: Proper resource management
- **Value Semantics**: Immutable data structures where appropriate
