import Foundation
@testable import FileConverterCore

/// A deliberately independent Protocol Buffers reader.
///
/// It exists so the tests check what `ProPresenterDocument` actually put on the
/// wire by parsing the bytes back, rather than by trusting the writer. It
/// shares no code with `ProtoWriter` on purpose: if both are wrong in the same
/// way, a shared decoder would agree with them.
enum ProtoReader {

    struct Field {
        let number: Int
        let wireType: Int
        let varint: UInt64?
        let bytes: Data?

        var uint: UInt64? { varint }
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }

        var double: Double? {
            guard wireType == 1, let bytes, bytes.count == 8 else { return nil }
            var value: UInt64 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt64(byte) << UInt64(index * 8)
            }
            return Double(bitPattern: value)
        }

        var float: Float? {
            guard wireType == 5, let bytes, bytes.count == 4 else { return nil }
            var value: UInt32 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt32(byte) << UInt32(index * 8)
            }
            return Float(bitPattern: value)
        }
    }

    private struct Cursor {
        let data: Data
        var index: Data.Index

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { throw ReaderError.malformedVarint }
            }
            throw ReaderError.truncated
        }

        mutating func read(_ count: Int) throws -> Data {
            guard count >= 0,
                  data.index(index, offsetBy: count, limitedBy: data.endIndex) != nil
            else { throw ReaderError.truncated }
            let end = data.index(index, offsetBy: count)
            defer { index = end }
            return Data(data[index..<end])
        }
    }

    static func fields(of data: Data) throws -> [Field] {
        var cursor = Cursor(data: data, index: data.startIndex)
        var fields: [Field] = []

        while cursor.index < data.endIndex {
            let key = try cursor.readVarint()
            let number = Int(key >> 3)
            let wireType = Int(key & 0x07)
            guard number > 0 else { throw ReaderError.malformedVarint }

            switch wireType {
            case 0:
                fields.append(Field(number: number, wireType: wireType, varint: try cursor.readVarint(), bytes: nil))
            case 1:
                fields.append(Field(number: number, wireType: wireType, varint: nil, bytes: try cursor.read(8)))
            case 2:
                let length = Int(try cursor.readVarint())
                fields.append(Field(number: number, wireType: wireType, varint: nil, bytes: try cursor.read(length)))
            case 5:
                fields.append(Field(number: number, wireType: wireType, varint: nil, bytes: try cursor.read(4)))
            default:
                throw ReaderError.unsupportedWireType(wireType)
            }
        }
        return fields
    }

    enum ReaderError: Error, CustomStringConvertible {
        case truncated
        case malformedVarint
        case unsupportedWireType(Int)

        var description: String {
            switch self {
            case .truncated: "message ended mid-field"
            case .malformedVarint: "malformed varint"
            case .unsupportedWireType(let type): "unexpected wire type \(type)"
            }
        }
    }
}

extension Array where Element == ProtoReader.Field {
    func first(_ number: Int) -> ProtoReader.Field? {
        first { $0.number == number }
    }

    func all(_ number: Int) -> [ProtoReader.Field] {
        filter { $0.number == number }
    }

    func uint(_ number: Int) -> UInt64? { first(number)?.uint }
    func string(_ number: Int) -> String? { first(number)?.string }
    func double(_ number: Int) -> Double? { first(number)?.double }
    func float(_ number: Int) -> Float? { first(number)?.float }
    func bool(_ number: Int) -> Bool { first(number)?.uint == 1 }
    func message(_ number: Int) throws -> [ProtoReader.Field]? {
        guard let bytes = first(number)?.bytes else { return nil }
        return try ProtoReader.fields(of: bytes)
    }

    func messages(_ number: Int) throws -> [[ProtoReader.Field]] {
        try all(number).compactMap { field in
            guard let bytes = field.bytes else { return nil }
            return try ProtoReader.fields(of: bytes)
        }
    }
}