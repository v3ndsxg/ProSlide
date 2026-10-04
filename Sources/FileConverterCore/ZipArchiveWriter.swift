import Foundation

/// A minimal streaming ZIP writer, used to build ProPresenter's `.probundle`
/// container.
///
/// Only what a bundle needs: entries stored uncompressed, written straight to
/// disk as they are added so a multi-gigabyte deck never has to fit in memory,
/// with ZIP64 records throughout so the 4 GB and 65535-entry ceilings of the
/// classic format cannot be reached.
///
/// Storing rather than deflating is deliberate. ProPresenter's own bundles store
/// their assets, and the assets here are JPEGs, which are already compressed —
/// deflating them costs time and saves nothing.
final class ZipArchiveWriter {

    enum Failure: Error, LocalizedError, Equatable {
        case cannotCreate(String)
        case cannotRead(String)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let path): "Could not create \(path)."
            case .cannotRead(let path): "Could not read \(path)."
            case .cannotWrite(let path): "Could not write \(path)."
            }
        }
    }

    private struct CentralRecord {
        let nameBytes: [UInt8]
        let crc32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    /// 64 KiB is comfortably larger than a pipe buffer and keeps the syscall
    /// count low without holding anything meaningful in memory.
    private static let chunkSize = 64 * 1024

    private let destination: URL
    private var handle: FileHandle?
    private var records: [CentralRecord] = []
    private var offset: UInt64 = 0

    /// Creates (or replaces) `url` and opens it for writing. Nothing is written
    /// until the first entry is added.
    init(to url: URL) throws {
        destination = url
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw Failure.cannotCreate(url.path)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cannotCreate(url.path)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        // Best effort only. A caller that forgets `close()` still gets a
        // readable file on Apple platforms, but the central directory would be
        // missing, so `close()` is the supported path.
        try? handle?.close()
    }

    // MARK: - Adding entries

    func addEntry(path: String, data: Data) throws {
        try beginEntry(path: path, crc32: CRC32.checksum(data), size: UInt64(data.count))
        try write(data)
    }

    func addFile(at url: URL, path: String) throws {
        guard let reader = try? FileHandle(forReadingFrom: url) else {
            throw Failure.cannotRead(url.path)
        }
        defer { try? reader.close() }

        // The CRC is in the header, which has to be written before the data, so
        // the file is measured first and then copied through in chunks.
        var crc = CRC32()
        var size: UInt64 = 0
        do {
            while let chunk = try reader.read(upToCount: ZipArchiveWriter.chunkSize), !chunk.isEmpty {
                crc.update(chunk)
                size &+= UInt64(chunk.count)
            }
            try beginEntry(path: path, crc32: crc.checksum, size: size)
            try reader.seek(toOffset: 0)
            while let chunk = try reader.read(upToCount: ZipArchiveWriter.chunkSize), !chunk.isEmpty {
                try write(chunk)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cannotRead(url.path)
        }
    }

    // MARK: - Finishing

    /// Writes the central directory and end-of-central-directory records, then
    /// closes the file.
    func close() throws {
        guard let handle else { return }
        var directory = Data()
        for record in records {
            appendCentralRecord(record, to: &directory)
        }
        let directoryOffset = offset
        let directorySize = UInt64(directory.count)
        let count = UInt64(records.count)

        // ZIP64 end of central directory record.
        directory.append(contentsOf: [0x50, 0x4B, 0x06, 0x06])
        appendLittleEndian(UInt64(44), to: &directory)   // this record's size, minus 12
        appendLittleEndian(UInt16(2), to: &directory)    // version made by
        appendLittleEndian(UInt16(45), to: &directory)   // version needed
        appendLittleEndian(UInt32(0), to: &directory)    // this disk
        appendLittleEndian(UInt32(0), to: &directory)    // disk holding the directory
        appendLittleEndian(count, to: &directory)
        appendLittleEndian(count, to: &directory)
        appendLittleEndian(directorySize, to: &directory)
        appendLittleEndian(directoryOffset, to: &directory)

        // ZIP64 end of central directory locator.
        directory.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])
        appendLittleEndian(UInt32(0), to: &directory)
        appendLittleEndian(directoryOffset + directorySize, to: &directory)
        appendLittleEndian(UInt32(1), to: &directory)

        // Classic end of central directory record, carrying the placeholders
        // that point at the ZIP64 records above.
        directory.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendLittleEndian(UInt16(0), to: &directory)
        appendLittleEndian(UInt16(0), to: &directory)
        let clamped = UInt16(min(records.count, Int(UInt16.max)))
        appendLittleEndian(clamped, to: &directory)
        appendLittleEndian(clamped, to: &directory)
        appendLittleEndian(UInt32(min(directorySize, UInt64(UInt32.max))), to: &directory)
        appendLittleEndian(UInt32(min(directoryOffset, UInt64(UInt32.max))), to: &directory)
        appendLittleEndian(UInt16(0), to: &directory)

        do {
            try handle.write(contentsOf: directory)
            try handle.close()
        } catch {
            throw Failure.cannotWrite(destination.path)
        }
        self.handle = nil
    }

    // MARK: - Layout

    /// Every entry carries a ZIP64 extra field even when its values would fit
    /// without one, because the central directory has to describe all of them.
    ///
    /// A local header only has sizes to record, so it carries two values. The
    /// central directory also records where the local header starts, so it
    /// carries three — readers index into this field positionally once they see
    /// the 0x0001 tag, and stop as soon as a value they expect is missing.
    private static let localExtraByteCount = 20
    private static let centralExtraByteCount = 28

    private func beginEntry(path: String, crc32: UInt32, size: UInt64) throws {
        let nameBytes = Array(path.utf8)
        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        appendLittleEndian(UInt16(45), to: &header)          // version needed to extract
        appendLittleEndian(UInt16(0), to: &header)           // general purpose flags
        appendLittleEndian(UInt16(0), to: &header)           // method: stored
        appendLittleEndian(UInt16(0), to: &header)           // modification time
        appendLittleEndian(UInt16(0), to: &header)           // modification date
        appendLittleEndian(crc32, to: &header)
        appendLittleEndian(UInt32.max, to: &header)          // compressed size: see extra
        appendLittleEndian(UInt32.max, to: &header)          // uncompressed size: see extra
        appendLittleEndian(UInt16(nameBytes.count), to: &header)
        appendLittleEndian(UInt16(ZipArchiveWriter.localExtraByteCount), to: &header)
        header.append(contentsOf: nameBytes)
        header.append(contentsOf: [0x01, 0x00, 0x10, 0x00])
        appendLittleEndian(size, to: &header)
        appendLittleEndian(size, to: &header)

        records.append(
            CentralRecord(
                nameBytes: nameBytes,
                crc32: crc32,
                size: size,
                localHeaderOffset: offset
            )
        )
        try write(header)
    }

    private func appendCentralRecord(_ record: CentralRecord, to output: inout Data) {
        output.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        appendLittleEndian(UInt16(3), to: &output)      // version made by: UNIX
        appendLittleEndian(UInt16(45), to: &output)     // version needed
        appendLittleEndian(UInt16(0), to: &output)      // flags
        appendLittleEndian(UInt16(0), to: &output)      // method: stored
        appendLittleEndian(UInt16(0), to: &output)      // modification time
        appendLittleEndian(UInt16(0), to: &output)      // modification date
        appendLittleEndian(record.crc32, to: &output)
        appendLittleEndian(UInt32.max, to: &output)     // compressed size
        appendLittleEndian(UInt32.max, to: &output)     // uncompressed size
        appendLittleEndian(UInt16(record.nameBytes.count), to: &output)
        appendLittleEndian(UInt16(ZipArchiveWriter.centralExtraByteCount), to: &output)
        appendLittleEndian(UInt16(0), to: &output)      // comment length
        appendLittleEndian(UInt16(0), to: &output)      // disk number start
        appendLittleEndian(UInt16(0), to: &output)      // internal attributes
        appendLittleEndian(UInt32(0o100644 << 16), to: &output)  // external attributes
        appendLittleEndian(UInt32.max, to: &output)     // local header offset
        output.append(contentsOf: record.nameBytes)
        output.append(contentsOf: [0x01, 0x00, 0x18, 0x00])
        appendLittleEndian(record.size, to: &output)
        appendLittleEndian(record.size, to: &output)
        appendLittleEndian(record.localHeaderOffset, to: &output)
    }

    private func write(_ data: Data) throws {
        guard let handle else { throw Failure.cannotWrite(destination.path) }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw Failure.cannotWrite(destination.path)
        }
        offset &+= UInt64(data.count)
    }

    private func appendLittleEndian(_ value: UInt16, to output: inout Data) {
        output.append(UInt8(truncatingIfNeeded: value))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendLittleEndian(_ value: UInt32, to output: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            output.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private func appendLittleEndian(_ value: UInt64, to output: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            output.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

/// CRC-32 as ZIP defines it: reflected, polynomial 0xEDB88320.
struct CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    private var running: UInt32 = 0xFFFF_FFFF

    mutating func update<Data: Sequence>(_ data: Data) where Data.Element == UInt8 {
        for byte in data {
            running = Self.table[Int((running ^ UInt32(byte)) & 0xFF)] ^ (running >> 8)
        }
    }

    var checksum: UInt32 { running ^ 0xFFFF_FFFF }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.checksum
    }
}