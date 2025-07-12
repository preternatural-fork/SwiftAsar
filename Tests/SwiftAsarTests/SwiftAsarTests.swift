import Foundation
@testable import SwiftAsar
import Testing

@Suite("Pickle Binary Serialization Tests")
struct PickleTests {
    @Test("Basic type serialization and deserialization")
    func basicTypes() throws {
        var writer = PickleWriter()

        // Write various types
        try writer.writeBool(true)
        try writer.writeInt32(-42)
        try writer.writeUInt32(42)
        try writer.writeInt64(-1_234_567_890)
        try writer.writeUInt64(1_234_567_890)
        try writer.writeFloat(3.14159)
        try writer.writeDouble(2.718281828)
        try writer.writeString("Hello, Swift Asar!")

        let data = writer.toData()
        var reader = try PickleReader(data: data)

        // Read and verify
        #expect(try reader.readBool() == true)
        #expect(try reader.readInt32() == -42)
        #expect(try reader.readUInt32() == 42)
        #expect(try reader.readInt64() == -1_234_567_890)
        #expect(try reader.readUInt64() == 1_234_567_890)
        #expect(try abs(reader.readFloat() - 3.14159) < 0.00001)
        #expect(try abs(reader.readDouble() - 2.718281828) < 0.000000001)
        #expect(try reader.readString() == "Hello, Swift Asar!")
    }

    @Test("String encoding with Unicode and emoji support")
    func stringEncoding() throws {
        var writer = PickleWriter()

        let testStrings = [
            "",
            "ASCII text",
            "Unicode: 你好世界",
            "Emoji: 🚀🎉",
            "Mixed: Hello 世界 🌍",
        ]

        for string in testStrings {
            try writer.writeString(string)
        }

        let data = writer.toData()
        var reader = try PickleReader(data: data)

        for expectedString in testStrings {
            let readString = try reader.readString()
            #expect(readString == expectedString)
        }
    }

    @Test("Raw byte data serialization")
    func rawBytes() throws {
        var writer = PickleWriter()

        let testData = Data([0x01, 0x02, 0x03, 0x04, 0xFF, 0xFE, 0xFD, 0xFC])
        try writer.writeRawBytes(testData)

        let writerData = writer.toData()
        var reader = try PickleReader(data: writerData)

        let readData = try reader.readRawBytes(count: testData.count)
        #expect(readData == testData)
    }
}

@Suite("Asar Filesystem Structure Tests")
struct FilesystemTests {
    @Test("JSON encoding and decoding of filesystem entries")
    func entryEncoding() throws {
        // Create a sample filesystem structure
        let integrity = FileIntegrity(
            hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            blocks: ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
        )

        let fileEntry = FileEntry(
            unpacked: false,
            executable: false,
            offset: 0,
            size: 100,
            integrity: integrity
        )

        let symlinkEntry = SymlinkEntry(link: "../target.txt")

        let directoryEntry = DirectoryEntry(files: [
            "file.txt": .file(fileEntry),
            "link.txt": .symlink(symlinkEntry),
        ])

        let rootEntry = FilesystemEntry.directory(directoryEntry)

        // Test encoding/decoding
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(rootEntry)

        let decoder = JSONDecoder()
        let decodedEntry = try decoder.decode(FilesystemEntry.self, from: jsonData)

        #expect(rootEntry == decodedEntry)
    }

    @Test("Path navigation and file discovery")
    func pathNavigation() throws {
        // Create a test filesystem
        let integrity = FileIntegrity(
            hash: "test",
            blocks: ["test"]
        )

        let fileEntry = FileEntry(
            unpacked: false,
            executable: false,
            offset: 0,
            size: 100,
            integrity: integrity
        )

        let nestedDir = DirectoryEntry(files: [
            "nested-file.txt": .file(fileEntry),
        ])

        let rootDir = DirectoryEntry(files: [
            "root-file.txt": .file(fileEntry),
            "nested": .directory(nestedDir),
        ])

        let filesystem = AsarFilesystem(root: .directory(rootDir))

        // Test finding files
        let rootFile = try filesystem.findEntry(at: "root-file.txt")
        if case .file = rootFile {
            // Test passes
        } else {
            #expect(Bool(false), "Expected file entry")
        }

        let nestedFile = try filesystem.findEntry(at: "nested/nested-file.txt")
        if case .file = nestedFile {
            // Test passes
        } else {
            #expect(Bool(false), "Expected file entry")
        }

        // Test directory listing
        let files = try filesystem.listFiles(recursive: true)
        #expect(files.contains("root-file.txt"))
        #expect(files.contains("nested"))
        #expect(files.contains("nested/nested-file.txt"))
    }

    @Test("Error handling for invalid paths and missing files")
    func errorHandling() throws {
        let rootDir = DirectoryEntry(files: [:])
        let filesystem = AsarFilesystem(root: .directory(rootDir))

        // Test file not found
        #expect(throws: FilesystemError.self) {
            try filesystem.findEntry(at: "nonexistent.txt")
        }

        // Test invalid path
        #expect(throws: FilesystemError.self) {
            try filesystem.listFiles(at: "nonexistent")
        }
    }
}
