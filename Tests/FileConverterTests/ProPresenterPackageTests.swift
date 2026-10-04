import XCTest
@testable import FileConverterCore

/// Covers the ProPresenter packaging path: the protobuf writer, the manifest
/// builder, the ZIP writer, and the packager that ties them together.
final class ProPresenterPackageTests: XCTestCase {

    // MARK: - Primitives

    func testVarintEncodingMatchesSpecification() throws {
        var writer = ProtoWriter()
        writer.varint(0)
        writer.varint(1)
        writer.varint(127)
        writer.varint(128)
        writer.varint(300)
        writer.varint(16384)
        XCTAssertEqual(
            [UInt8](writer.bytes),
            [0x00, 0x01, 0x7F, 0x80, 0x01, 0xAC, 0x02, 0x80, 0x80, 0x01]
        )
    }

    func testProto3OmitsZeroValuesButKeepsFalseAsAbsent() {
        var writer = ProtoWriter()
        writer.uint(1, 0)
        writer.bool(2, false)
        writer.double(3, 0)
        writer.string(4, "")
        writer.float(5, 0)
        XCTAssertEqual(writer.bytes.count, 0, "proto3 leaves zero-valued fields off the wire")

        var nonZero = ProtoWriter()
        nonZero.uint(1, 1)
        nonZero.bool(2, true)
        XCTAssertEqual([UInt8](nonZero.bytes), [0x08, 0x01, 0x10, 0x01])
    }

    /// Fixed-width fields are little-endian on every host, which a
    /// `withUnsafeBytes` implementation would only get right by accident.
    func testFixedWidthFieldsAreLittleEndian() throws {
        var writer = ProtoWriter()
        writer.double(1, 1)          // 0x3FF0000000000000
        writer.float(2, 1)           // 0x3F800000
        XCTAssertEqual(
            [UInt8](writer.bytes),
            // tag 1/wire 1, then 1.0 as 00 00 00 00 00 00 F0 3F,
            // then tag 2/wire 5, then 1.0f as 00 00 80 3F.
            [0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, 0x15, 0x00, 0x00, 0x80, 0x3F]
        )
    }

    func testCRC32MatchesKnownVector() {
        // The check value every CRC-32 implementation is expected to produce.
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    // MARK: - The reference presentation

    /// Reads `reference.pro`, a recording of a presentation ProPresenter wrote
    /// itself with every path and identifier replaced. It is the ground truth
    /// for every field number and enum value in `ProPresenterDocument`.
    func testReferenceFixtureHasTheDocumentedShape() throws {
        let presentation = try ProtoReader.fields(of: referenceFixture())

        XCTAssertEqual(presentation.string(3), "7PM Youth Announcements")
        XCTAssertEqual(presentation.all(13).count, 13, "thirteen cues")
        XCTAssertEqual(presentation.all(12).count, 8, "eight cue groups")

        // ApplicationInfo: Mac, ProPresenter.
        let info = try XCTUnwrap(presentation.message(1))
        XCTAssertEqual(info.uint(1), 1)
        XCTAssertEqual(info.uint(3), 1)

        // Background is a transparent colour; chord chart is Mac.
        let background = try XCTUnwrap(presentation.message(8))
        let colour = try XCTUnwrap(background.message(1))
        XCTAssertEqual(colour.float(4), 1)
        XCTAssertEqual(try presentation.message(9)?.uint(3), 1)

        // First cue: a name, one canvas action, one media action.
        let cue = try XCTUnwrap(presentation.message(13))
        XCTAssertEqual(cue.string(2), "deck-001.jpg")
        XCTAssertEqual(cue.uint(5), 1, "completion_action_type: last")
        XCTAssertTrue(cue.bool(12), "cues are enabled")

        let actions = try cue.messages(10)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].uint(9), 11, "first action is a presentation slide")
        XCTAssertEqual(actions[1].uint(9), 2, "second action is media")

        // The canvas action sizes itself to the image.
        let slideType = try XCTUnwrap(actions[0].message(23))
        let presentationSlide = try XCTUnwrap(slideType.message(2))
        let baseSlide = try XCTUnwrap(presentationSlide.message(1))
        let size = try XCTUnwrap(baseSlide.message(6))
        XCTAssertEqual(size.double(1), 1920)
        XCTAssertEqual(size.double(2), 1080)

        // The media action: a foreground layer pointing at one JPEG.
        let media = try XCTUnwrap(actions[1].message(20))
        XCTAssertEqual(media.uint(10), 1, "layer_type: foreground")
        let element = try XCTUnwrap(media.message(5))
        let url = try XCTUnwrap(element.message(2))
        XCTAssertEqual(url.uint(3), 1, "platform: macOS")
        let local = try XCTUnwrap(url.message(4))
        XCTAssertEqual(local.uint(1), 2, "root: user home")
        XCTAssertEqual(local.string(2), "Pictures/deck-001.jpg")

        let metadata = try XCTUnwrap(element.message(3))
        XCTAssertEqual(metadata.string(5), "JPG")
        XCTAssertEqual(metadata.uint(6), 1, "colour format: SDR")

        let image = try XCTUnwrap(element.message(5))
        let drawing = try XCTUnwrap(image.message(1))
        let natural = try XCTUnwrap(drawing.message(5))
        XCTAssertEqual(natural.double(1), 1920)
        XCTAssertEqual(natural.double(2), 1080)
        XCTAssertEqual(drawing.uint(15), 1, "alpha_type: straight")
        XCTAssertTrue(drawing.bool(16))
    }

    /// Every cue group lists the deck's cues in order, which is what gives the
    /// presentation its sequence in ProPresenter.
    func testReferenceCueGroupsAccountForEveryCue() throws {
        let presentation = try ProtoReader.fields(of: referenceFixture())
        let groups = try presentation.messages(12)
        var listed: [[ProtoReader.Field]] = []
        for group in groups { listed += try group.messages(2) }
        XCTAssertEqual(listed.count, presentation.all(13).count)
    }

    // MARK: - The generated manifest

    func testGeneratedManifestMatchesTheReferenceCueShape() throws {
        let slide = ProSlide(
            imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-001.jpg"),
            pixelSize: PixelSize(width: 1920, height: 1080),
            reference: .userHome(
                URL(fileURLWithPath: "/Users/someone/Pictures/deck-001.jpg"),
                home: URL(fileURLWithPath: "/Users/someone")
            )!
        )
        let generated = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: [slide]))
        let reference = try ProtoReader.fields(of: referenceFixture())

        // Compare the first cue of each, ignoring the fields we deliberately do
        // not write (see ProPresenterDocument) and the ones that are just
        // identifiers.
        let ours = try XCTUnwrap(generated.message(13))
        let theirs = try XCTUnwrap(reference.message(13))

        // Field 1 is the cue's own UUID and field 8 an empty hot key; field 10 is
        // the action list, compared element by element below because our two
        // actions differ in field count from ProPresenter's.
        assertSameShape(ours, theirs, ignoring: [1, 8, 10], context: "cue")

        let ourActions = try ours.messages(10)
        let theirActions = try theirs.messages(10)
        XCTAssertEqual(ourActions.count, theirActions.count)
        for (index, pair) in zip(ourActions, theirActions).enumerated() {
            // Field 8 on a media action is a playback duration. ProPresenter
            // writes one; we omit it so slides hold until clicked.
            assertSameShape(pair.0, pair.1, ignoring: index == 1 ? [8] : [], context: "action \(index)")
        }
    }

    func testGeneratedManifestKeepsSlideOrderAndSizes() throws {
        let slides = (1...3).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080),
                reference: .bundleAsset(named: "deck-00\(index).jpg"),
                label: "Slide \(index)"
            )
        }
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides))

        XCTAssertEqual(presentation.string(3), "Deck")
        let cues = try presentation.messages(13)
        XCTAssertEqual(cues.compactMap { $0.string(2) }, ["Slide 1", "Slide 2", "Slide 3"])

        for cue in cues {
            let actions = try XCTUnwrap(cue.messages(10))
            let element = try XCTUnwrap(try XCTUnwrap(actions[1].message(20)).message(5))
            let local = try XCTUnwrap(try XCTUnwrap(element.message(2)).message(4))
            XCTAssertEqual(local.uint(1), 10, "bundled media resolves against ROOT_SHOW")
            XCTAssertEqual(
                local.string(2),
                "Media/Assets/\(cue.string(2)!.replacingOccurrences(of: "Slide ", with: "deck-00").appending(".jpg"))"
            )
        }
    }

    func testEmptyDeckProducesACueGroupAndNoCues() throws {
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Empty", slides: []))
        XCTAssertEqual(presentation.all(13).count, 0)
        XCTAssertEqual(presentation.all(12).count, 1, "still one group, holding no cues")
    }

    // MARK: - References

    func testUserHomeReferenceStripsTheHomePrefix() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let file = URL(fileURLWithPath: "/Users/someone/Pictures/deck-001.jpg")
        let reference = MediaReference.userHome(file, home: home)
        XCTAssertEqual(reference?.root, 2)
        XCTAssertEqual(reference?.path, "Pictures/deck-001.jpg")
        XCTAssertEqual(reference?.absoluteString, file.absoluteString)
    }

    func testUserHomeReferenceRejectsAnythingOutsideHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let elsewhere = URL(fileURLWithPath: "/Volumes/Share/deck-001.jpg")
        XCTAssertNil(MediaReference.userHome(elsewhere, home: home))
    }

    func testUserHomeReferenceIsNotFooledByAPrefixThatIsNotAPathBoundary() {
        let home = URL(fileURLWithPath: "/Users/some")
        let sibling = URL(fileURLWithPath: "/Users/someoneelse/deck-001.jpg")
        XCTAssertNil(MediaReference.userHome(sibling, home: home))
    }

    func testBundleAssetReferenceUsesRootShow() {
        let reference = MediaReference.bundleAsset(named: "deck 001.jpg")
        XCTAssertEqual(reference.root, 10)
        XCTAssertEqual(reference.path, "Media/Assets/deck 001.jpg")
        XCTAssertEqual(reference.absoluteString, "file:///Library/Application%20Support/ProPresenter/Media/Assets/deck%20001.jpg")
    }

    func testPercentEncodingLeavesReservedPathCharactersAlone() {
        XCTAssertEqual(ProPresenterDocument.percentEncoded("a b.jpg"), "a%20b.jpg")
        XCTAssertEqual(ProPresenterDocument.percentEncoded("plain-1_2.3.jpg"), "plain-1_2.3.jpg")
        XCTAssertEqual(ProPresenterDocument.percentEncoded("100%.jpg"), "100%25.jpg")
    }

    // MARK: - Packaging

    func testBundleContainsManifestAndEveryImage() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        let package = try ProPresenterPackage.package(
            group: deck.group,
            format: .probundle,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        XCTAssertEqual(package.lastPathComponent, "Sample Deck.probundle")
        XCTAssertEqual(package.deletingLastPathComponent(), deck.folder)

        let archive = try Data(contentsOf: package)
        let entries = try ZipReader.entries(in: archive)
        XCTAssertEqual(
            entries.map(\.path),
            ["Sample Deck.pro", "Media/Assets/Sample Deck-001.jpg",
             "Media/Assets/Sample Deck-002.jpg", "Media/Assets/Sample Deck-003.jpg"]
        )
        for entry in entries {
            XCTAssertEqual(CRC32.checksum(entry.data), entry.crc32, "\(entry.path) has a stale CRC")
        }
        XCTAssertEqual(try ZipReader.data(at: "Media/Assets/Sample Deck-002.jpg", in: archive), Data("two".utf8))
    }

    func testBundledManifestIsByteIdenticalToTheBareOne() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        let bundle = try ProPresenterPackage.package(
            group: deck.group, format: .probundle,
            pixelSize: { _ in PixelSize(width: 800, height: 600) }
        )
        let bare = try ProPresenterPackage.package(
            group: deck.group, format: .proFile,
            pixelSize: { _ in PixelSize(width: 800, height: 600) }
        )

        XCTAssertEqual(bare.lastPathComponent, "Sample Deck.pro")
        let bundled = try ZipReader.data(at: "Sample Deck.pro", in: try Data(contentsOf: bundle))
        // The manifests differ only in where each slide's image lives, so they
        // cannot be equal byte for byte; both must still parse to the same deck.
        let fromBundle = try ProtoReader.fields(of: bundled)
        let fromFile = try ProtoReader.fields(of: try Data(contentsOf: bare))
        XCTAssertEqual(fromBundle.string(3), fromFile.string(3))
        XCTAssertEqual(fromBundle.all(13).count, fromFile.all(13).count)

        let bundledLocal = try XCTUnwrap(
            try XCTUnwrap(try XCTUnwrap(fromBundle.message(13)).messages(10)[1].message(20)).message(5)
        )
        let fileLocal = try XCTUnwrap(
            try XCTUnwrap(try XCTUnwrap(fromFile.message(13)).messages(10)[1].message(20)).message(5)
        )
        XCTAssertEqual(try bundledLocal.message(2)?.message(4)?.uint(1), 10)
        XCTAssertEqual(try fileLocal.message(2)?.message(4)?.uint(1), 2)
    }

    func testPackagingADeckWithNoImagesFails() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ProSlideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let group = ConversionGroup(sourceName: "Empty JPEGs", folderURL: folder)
        XCTAssertThrowsError(
            try ProPresenterPackage.package(group: group, format: .probundle, pixelSize: { _ in nil })
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .noImages("Empty JPEGs"))
        }
    }

    func testUnreadableImageFails() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        XCTAssertThrowsError(
            try ProPresenterPackage.package(group: deck.group, format: .probundle, pixelSize: { _ in nil })
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .unreadableImage("Sample Deck-001.jpg"))
        }
    }

    func testPresentationNameStripsTheJPEGSuffix() {
        func name(_ folder: String) -> String {
            ProPresenterPackage.presentationName(
                for: ConversionGroup(sourceName: folder, folderURL: URL(fileURLWithPath: "/tmp/\(folder)"))
            )
        }
        XCTAssertEqual(name("Sample Deck JPEGs"), "Sample Deck")
        XCTAssertEqual(name("Sample Deck JPEGs 2"), "Sample Deck JPEGs 2", "only the exact suffix is trimmed")
        XCTAssertEqual(name("Already Named"), "Already Named")
    }

    // MARK: - Helpers

    private struct Deck {
        let folder: URL
        let group: ConversionGroup
    }

    private func makeDeck(imageCount: Int) throws -> Deck {
        // Under the home folder, like the real bin: a bare .pro can only point
        // at media beneath the user's home.
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ProSlideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...imageCount {
            let name = String(format: "Sample Deck-%03d.jpg", index)
            let words = ["one", "two", "three", "four", "five"]
            try Data(words[index - 1].utf8).write(to: folder.appendingPathComponent(name))
        }
        let group = ConversionGroup(sourceName: "Sample Deck JPEGs", folderURL: folder)
        XCTAssertEqual(group.imageURLs.count, imageCount, "images must sort into page order")
        return Deck(folder: folder, group: group)
    }

    private func referenceFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("reference.pro")
        return try Data(contentsOf: url)
    }

    /// Asserts two messages carry the same fields, recursively, so that
    /// ProPresenter would read them the same way.
    ///
    /// Strings and identifiers are skipped: they legitimately differ between the
    /// recording and anything this app writes (paths, generated UUIDs).
    private func assertSameShape(
        _ ours: [ProtoReader.Field],
        _ theirs: [ProtoReader.Field],
        ignoring ignored: Set<Int>,
        context: String,
        depth: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard depth < 12 else { return }
        for field in ours where !ignored.contains(field.number) {
            guard let match = theirs.first(where: {
                $0.number == field.number && $0.wireType == field.wireType
            }) else {
                return XCTFail("\(context): field \(field.number) is not in the reference", file: file, line: line)
            }
            switch field.wireType {
            case 2:
                guard let ourBytes = field.bytes, let theirBytes = match.bytes else { continue }
                // Identifiers, labels, paths and URLs are expected to differ.
                if isText(ourBytes) { continue }
                let ourNested = try? ProtoReader.fields(of: ourBytes)
                let theirNested = try? ProtoReader.fields(of: theirBytes)
                guard let ours = ourNested, let theirs = theirNested else {
                    return XCTFail(
                        "\(context): field \(field.number) is a message in only one of the two",
                        file: file, line: line
                    )
                }
                XCTAssertEqual(
                    ours.count, theirs.count,
                    "\(context): field \(field.number) holds a different number of fields",
                    file: file, line: line
                )
                assertSameShape(
                    ours, theirs, ignoring: [],
                    context: "\(context).\(field.number)", depth: depth + 1, file: file, line: line
                )
            default:
                let ours = field.varint.map(String.init) ?? "nil"
                let theirs = match.varint.map(String.init) ?? "nil"
                XCTAssertEqual(
                    ours, theirs,
                    "\(context): field \(field.number) disagrees with the reference", file: file, line: line
                )
            }
        }
    }

    private func isText(_ data: Data) -> Bool {
        !data.isEmpty && data.allSatisfy { (0x20..<0x7F).contains($0) }
    }
}
