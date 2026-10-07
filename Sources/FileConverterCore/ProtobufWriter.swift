import Foundation

/// A writer for the Protocol Buffers binary wire format, limited to what a
/// ProPresenter presentation needs.
///
/// ProPresenter 7 and later store presentations as `rv.data.Presentation`
/// messages rather than the XML that ProPresenter 6 used. Describing a deck of
/// still images only touches a handful of message types, so this writes those
/// directly instead of taking on `protoc` plus a generated-code dependency.
///
/// The schema is community-reverse-engineered and is not supported by Renewed
/// Vision; see the "About the `.pro` format" section of README.md. The field
/// numbers used by `ProPresenterDocument` are checked against the published
/// `.proto` schema, and the ones a real ProPresenter file exercises are pinned
/// against a recording of one in `ProPresenterPackageTests`.
///
/// proto3 semantics apply: a scalar field holding its zero value is not written
/// at all. The `put` methods below follow that rule, so callers can pass values
/// unconditionally without littering the output with empty fields.
///
/// Message-typed fields are the exception, and deliberately so: they have
/// explicit presence, so a message that is set but empty is written as a
/// zero-length field. ProPresenter relies on this — it writes an empty
/// `media.audio` and an empty `drawing.crop_insets` on every slide.
struct ProtoWriter {
    enum WireType: UInt64 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    private(set) var bytes: [UInt8] = []

    init(reservingCapacity capacity: Int = 0) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    var data: Data { Data(bytes) }

    /// Appends a bare varint. This is the base-10 continuation encoding, not a
    /// field: callers normally want `uint(_:_:)` instead.
    mutating func varint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(truncatingIfNeeded: remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
    }

    mutating func tag(_ field: Int, _ wire: WireType) {
        varint(UInt64(field) << 3 | wire.rawValue)
    }

    /// Writes an unsigned integer field, skipping zero.
    mutating func uint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, .varint)
        varint(value)
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        guard value else { return }
        tag(field, .varint)
        varint(1)
    }

    mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        data(field, Data(value.utf8))
    }

    mutating func data(_ field: Int, _ value: Data) {
        tag(field, .lengthDelimited)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    /// Writes a nested message built by `body`.
    mutating func message(_ field: Int, _ body: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        body(&nested)
        data(field, nested.data)
    }

    mutating func double(_ field: Int, _ value: Double) {
        guard value != 0 else { return }
        tag(field, .fixed64)
        littleEndian(value.bitPattern, byteCount: 8)
    }

    mutating func float(_ field: Int, _ value: Float) {
        guard value != 0 else { return }
        tag(field, .fixed32)
        littleEndian(UInt64(value.bitPattern), byteCount: 4)
    }

    /// Fixed-width fields are stored little-endian regardless of the host, so
    /// the bytes are emitted one at a time rather than relying on the machine's
    /// own byte order.
    private mutating func littleEndian(_ value: UInt64, byteCount: Int) {
        for shift in stride(from: 0, to: byteCount * 8, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}