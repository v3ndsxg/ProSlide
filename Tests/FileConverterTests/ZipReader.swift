import Foundation
@testable import FileConverterCore

/// An independent ZIP reader, so the tests can prove the archive is readable by
/// something other than the code that wrote it.
enum ZipReader {

    struct Entry {
        let path: String
        let crc32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
        let data: Data
    }

    enum Failure: Error, CustomStringConvertible {
        case badSignature(UInt32, String)
        case unsupportedMethod(UInt16)
        case sizeMismatch(String)

        var description: String {
            switch self {
            case .badSignature(let value, let what): "\(what) had signature 0x\(String(value, radix: 16))"
            case .unsupportedMethod(let method): "compression method \(method) is not stored"
            case .sizeMismatch(let path): "\(path) size did not match its central directory record"
            }
        }
    }

    static func entries(in archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        func readU16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func readU32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
        }
        func readU64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << UInt64(8 * $1) }
        }

        // Locate the classic end-of-central-directory record by scanning
        // backwards for its signature.
        var eocd: Int?
        var cursor = bytes.count - 22
        while cursor >= 0 {
            if readU32(cursor) == 0x0605_4B50 { eocd = cursor; break }
            cursor -= 1
        }
        guard let eocd else { throw Failure.badSignature(0, "end of central directory") }

        let count = Int(readU16(eocd + 10))
        var offset = Int(readU32(eocd + 16))

        var entries: [Entry] = []
        for _ in 0..<count {
            guard readU32(offset) == 0x0201_4B50 else {
                throw Failure.badSignature(readU32(offset), "central directory record")
            }
            let method = readU16(offset + 10)
            guard method == 0 else { throw Failure.unsupportedMethod(method) }
            let crc = readU32(offset + 16)
            let nameLength = Int(readU16(offset + 28))
            let extraLength = Int(readU16(offset + 30))
            let commentLength = Int(readU16(offset + 32))
            let localOffset = Int(readU32(offset + 42))
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            // The real sizes live in the ZIP64 extra field.
            var uncompressed = UInt64(readU32(offset + 24))
            var compressed = UInt64(readU32(offset + 20))
            var local = UInt64(localOffset)
            var extraCursor = offset + 46 + nameLength
            let extraEnd = extraCursor + extraLength
            while extraCursor + 4 <= extraEnd {
                let tag = readU16(extraCursor)
                let size = Int(readU16(extraCursor + 2))
                if tag == 0x0001 {
                    var field = extraCursor + 4
                    if uncompressed == UInt64(UInt32.max) { uncompressed = readU64(field); field += 8 }
                    if compressed == UInt64(UInt32.max) { compressed = readU64(field); field += 8 }
                    if local == UInt64(UInt32.max) { local = readU64(field) }
                }
                extraCursor += 4 + size
            }

            guard readU32(Int(local)) == 0x0403_4B50 else {
                throw Failure.badSignature(readU32(Int(local)), "local file header for \(name)")
            }
            let localNameLength = Int(readU16(Int(local) + 26))
            let localExtraLength = Int(readU16(Int(local) + 28))
            let dataStart = Int(local) + 30 + localNameLength + localExtraLength
            guard compressed == uncompressed else {
                throw Failure.unsupportedMethod(method)
            }
            let payload = Data(bytes[dataStart..<(dataStart + Int(uncompressed))])
            guard UInt64(payload.count) == uncompressed else {
                throw Failure.sizeMismatch(name)
            }
            entries.append(
                Entry(path: name, crc32: crc, size: uncompressed, localHeaderOffset: local, data: payload)
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func data(at path: String, in archive: Data) throws -> Data {
        guard let entry = try entries(in: archive).first(where: { $0.path == path }) else {
            throw Failure.sizeMismatch("no entry named \(path)")
        }
        return entry.data
    }
}