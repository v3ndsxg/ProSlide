import Foundation

/// Writes a `.zip` archive that stores its files without compressing them —
/// the container a `.probundle` is.
///
/// ProPresenter's own bundles are stored rather than deflated, and the payload
/// is JPEGs, which deflate cannot shrink anyway, so storing costs nothing and
/// keeps this to the headers and a checksum. It is written here rather than by
/// shelling out to `zip` or `ditto` so a bundle is one function call that the
/// tests can exercise, with no process to launch.
///
/// Two choices differ from what ProPresenter writes, deliberately:
///
/// - Every name is flagged as UTF-8. ProPresenter's exports leave the flag
///   off, which leaves a reader to guess the encoding of a name like
///   `Ти є тут`. ProPresenter imports the flagged names correctly.
/// - The directory records are correct. ProPresenter's bundles declare a central
///   directory 98 bytes longer than the one they contain, which strict readers
///   refuse; there is no reason to copy that.
///
/// No Zip64. A bundle over 4 GB, or with more than 65,535 files, is refused:
/// a 300-page deck at 4K is a small fraction of either limit.
enum ZipWriter {

    struct Entry {
        enum Source {
            case data(Data)
            case file(URL)
        }

        /// The path inside the archive, `/`-separated.
        let name: String
        let source: Source
    }

    enum ZipError: Error, Equatable {
        case tooLarge
        case unreadable(String)
    }

    /// Writes `entries`, in order, to a new archive at `url`, replacing anything
    /// already there.
    ///
    /// Files are read one at a time, so memory holds one image rather than the
    /// whole deck.
    static func write(_ entries: [Entry], to url: URL, modified: Date = Date()) throws {
        guard entries.count <= Int(UInt16.max) else { throw ZipError.tooLarge }
        let (time, date) = dosTimestamp(modified)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var directory = Data()
        for entry in entries {
            let contents: Data
            switch entry.source {
            case .data(let data):
                contents = data
            case .file(let file):
                guard let data = try? Data(contentsOf: file) else {
                    throw ZipError.unreadable(file.lastPathComponent)
                }
                contents = data
            }
            let name = Data(entry.name.utf8)
            let size = UInt64(contents.count)
            guard size <= UInt64(UInt32.max), offset <= UInt64(UInt32.max) else { throw ZipError.tooLarge }
            let checksum = crc32(contents)

            var local = Data()
            local.append(le32: 0x0403_4B50)
            local.append(le16: versionNeeded)
            local.append(le16: utf8Flag)
            local.append(le16: 0)  // stored
            local.append(le16: time)
            local.append(le16: date)
            local.append(le32: checksum)
            local.append(le32: UInt32(size))  // compressed size: stored, so the same
            local.append(le32: UInt32(size))
            local.append(le16: UInt16(name.count))
            local.append(le16: 0)  // no extra field
            local.append(name)
            try handle.write(contentsOf: local)
            try handle.write(contentsOf: contents)

            directory.append(le32: 0x0201_4B50)
            directory.append(le16: versionMadeBy)
            directory.append(le16: versionNeeded)
            directory.append(le16: utf8Flag)
            directory.append(le16: 0)
            directory.append(le16: time)
            directory.append(le16: date)
            directory.append(le32: checksum)
            directory.append(le32: UInt32(size))
            directory.append(le32: UInt32(size))
            directory.append(le16: UInt16(name.count))
            directory.append(le16: 0)  // extra field
            directory.append(le16: 0)  // comment
            directory.append(le16: 0)  // disk number
            directory.append(le16: 0)  // internal attributes
            directory.append(le32: regularFileAttributes)
            directory.append(le32: UInt32(offset))
            directory.append(name)

            offset += UInt64(local.count) + size
        }

        guard offset + UInt64(directory.count) <= UInt64(UInt32.max) else { throw ZipError.tooLarge }
        var end = Data()
        end.append(le32: 0x0605_4B50)
        end.append(le16: 0)  // this disk
        end.append(le16: 0)  // disk holding the directory
        end.append(le16: UInt16(entries.count))
        end.append(le16: UInt16(entries.count))
        end.append(le32: UInt32(directory.count))
        end.append(le32: UInt32(offset))
        end.append(le16: 0)  // comment
        try handle.write(contentsOf: directory)
        try handle.write(contentsOf: end)
    }

    // MARK: - Header fields

    /// 2.0: the lowest version that covers stored entries in folders.
    private static let versionNeeded: UInt16 = 20

    /// Unix (3) in the high byte, so `regularFileAttributes` is read as a mode.
    private static let versionMadeBy: UInt16 = 3 << 8 | 20

    /// General-purpose bit 11: names are UTF-8.
    private static let utf8Flag: UInt16 = 1 << 11

    /// `-rw-r--r--`, a regular file. ProPresenter's own archives record no
    /// permissions at all, which extracts as unreadable files.
    private static let regularFileAttributes: UInt32 = 0o100644 << 16

    /// MS-DOS time and date, the only timestamp a plain zip header holds. It
    /// cannot express anything before 1980.
    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max((parts.year ?? 1980) - 1980, 0)
        let time = (parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2
        let day = year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }

    // MARK: - CRC-32

    /// The IEEE 802.3 CRC-32 every zip entry carries, computed a byte at a time
    /// from a lookup table.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
