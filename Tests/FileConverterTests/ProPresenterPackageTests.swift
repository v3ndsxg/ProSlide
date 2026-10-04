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
            pixelSize: PixelSize(width: 1920, height: 1080)
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
        // Field 8 inside a URL's local path is the root enum, and it is expected
        // to differ: the recording is a standalone .pro resolving against the home
        // folder, a bundle resolves against itself. testMediaIsReferencedTheWay
        // ProPresenterResolvesABundle pins our value.
        assertSameShape(
            ours, theirs, ignoring: [1, 8, 10], ignoreAnywhere: [1], context: "cue"
        )

        let ourActions = try ours.messages(10)
        let theirActions = try theirs.messages(10)
        XCTAssertEqual(ourActions.count, theirActions.count)
        for (index, pair) in zip(ourActions, theirActions).enumerated() {
            // Field 8 on a media action is a playback duration. ProPresenter
            // writes one; we omit it so slides hold until clicked.
            assertSameShape(
                pair.0, pair.1,
                ignoring: index == 1 ? [8] : [],
                ignoreAnywhere: [1],
                context: "action \(index)"
            )
        }
    }

    func testGeneratedManifestKeepsSlideOrderAndSizes() throws {
        let slides = (1...3).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080),
                label: "Slide \(index)"
            )
        }
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides))

        XCTAssertEqual(presentation.string(3), "Deck")
        let cues = try presentation.messages(13)
        XCTAssertEqual(cues.compactMap { $0.string(2) }, ["Slide 1", "Slide 2", "Slide 3"])
        XCTAssertEqual(presentation.all(12).count, 1, "one group holding the deck in order")

        for (index, cue) in cues.enumerated() {
            let actions = try XCTUnwrap(cue.messages(10))
            let element = try XCTUnwrap(try XCTUnwrap(actions[1].message(20)).message(5))
            let drawing = try XCTUnwrap(try XCTUnwrap(element.message(5)).message(1))
            let natural = try XCTUnwrap(drawing.message(5))
            XCTAssertEqual(natural.double(1), 1920)
            XCTAssertEqual(natural.double(2), 1080)

            // Each cue must point at its own image.
            let local = try XCTUnwrap(try XCTUnwrap(element.message(2)).message(4))
            XCTAssertEqual(local.string(2), "deck-00\(index + 1).jpg")
        }
    }

    // MARK: - Bundle layout

    /// The three details that decide whether ProPresenter finds the images at
    /// all. Each of these was wrong at least once; they are pinned here so a
    /// future change cannot quietly reintroduce a bundle that imports empty.
    func testMediaIsReferencedTheWayProPresenterResolvesABundle() throws {
        let slide = ProSlide(
            imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-001.jpg"),
            pixelSize: PixelSize(width: 1920, height: 1080)
        )
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: [slide]))
        let cue = try XCTUnwrap(presentation.message(13))
        let element = try XCTUnwrap(try XCTUnwrap(try XCTUnwrap(cue.messages(10)[1].message(20)).message(5)))

        let url = try XCTUnwrap(element.message(2))
        let local = try XCTUnwrap(url.message(4))

        XCTAssertEqual(
            local.uint(1), 12,
            "media must use ROOT_CURRENT_RESOURCE, which ProPresenter resolves against the bundle. "
                + "ROOT_SHOW (10) points at ProPresenter's library directory and imports no images."
        )
        XCTAssertEqual(
            local.string(2), "deck-001.jpg",
            "the path must be the flat ZIP entry name, with no directory component"
        )
        XCTAssertEqual(
            url.string(1), "deck-001.jpg",
            "absolute_string is the bare filename for bundle media, not a file:// URL"
        )
        XCTAssertEqual(url.uint(3), 1, "platform: macOS")

        let metadata = try XCTUnwrap(element.message(3))
        XCTAssertEqual(
            metadata.string(5), "jpg",
            "ProPresenter records the format in lowercase"
        )
    }

    func testImageFileLocalURLMatchesTheMediaURL() throws {
        let slide = ProSlide(
            imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-001.jpg"),
            pixelSize: PixelSize(width: 1920, height: 1080)
        )
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: [slide]))
        let cue = try XCTUnwrap(presentation.message(13))
        let element = try XCTUnwrap(try XCTUnwrap(try XCTUnwrap(cue.messages(10)[1].message(20)).message(5)))

        // ProPresenter reads media.image.file.localUrl as well as media.url, and
        // the two must agree or the image resolves inconsistently. Both are URL
        // messages, so both nest the same way: url.local(4).path(2).
        // The longer route is element.image(5) -> file(2) -> localUrl(1).
        func localPath(_ url: [ProtoReader.Field]?) throws -> [ProtoReader.Field] {
            try XCTUnwrap(url?.message(4))
        }
        let direct = try localPath(element.message(2))
        let viaFile = try localPath(
            try XCTUnwrap(try XCTUnwrap(element.message(5)).message(2)).message(1)
        )
        XCTAssertEqual(direct.string(2), viaFile.string(2), "the two URLs must name the same file")
        XCTAssertEqual(direct.uint(1), viaFile.uint(1), "the two URLs must use the same root")
    }

    func testEmptyDeckProducesACueGroupAndNoCues() throws {
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Empty", slides: []))
        XCTAssertEqual(presentation.all(13).count, 0)
        XCTAssertEqual(presentation.all(12).count, 1, "still one group, holding no cues")
    }

    // MARK: - Packaging

    func testBundleHoldsManifestAndEveryImageAtTheZipRoot() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let destination = deck.packages

        let package = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: destination,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        XCTAssertEqual(package.lastPathComponent, "Sample Deck.probundle")
        XCTAssertEqual(package.deletingLastPathComponent(), destination)

        let archive = try Data(contentsOf: package)
        let entries = try ZipReader.entries(in: archive)

        // Flat names, no Media/Assets prefix: these must match the paths the
        // manifest records or ProPresenter resolves nothing.
        XCTAssertEqual(
            entries.map(\.path),
            ["Sample Deck.pro", "Sample Deck-001.jpg", "Sample Deck-002.jpg", "Sample Deck-003.jpg"]
        )
        for entry in entries {
            XCTAssertEqual(CRC32.checksum(entry.data), entry.crc32, "\(entry.path) has a stale CRC")
        }
        XCTAssertEqual(try ZipReader.data(at: "Sample Deck-002.jpg", in: archive), Data("two".utf8))
    }

    /// Every filename the manifest points at has to exist in the archive.
    func testEveryManifestPathResolvesToAnEntryInTheBundle() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        let package = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: deck.packages,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        let archive = try Data(contentsOf: package)
        let entryNames = Set(try ZipReader.entries(in: archive).map(\.path))
        let presentation = try ProtoReader.fields(of: try ZipReader.data(at: "Sample Deck.pro", in: archive))

        let paths = try presentation.messages(13).map { cue -> String in
            let actions = try XCTUnwrap(cue.messages(10))
            let element = try XCTUnwrap(try XCTUnwrap(actions[1].message(20)).message(5))
            return try XCTUnwrap(try XCTUnwrap(element.message(2)).message(4)).string(2)!
        }
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            XCTAssertTrue(entryNames.contains(path), "manifest points at \(path), which is not in the bundle")
        }
    }

    /// Real decks carry the document's name, which can contain spaces and
    /// non-ASCII characters. Those must survive the round trip unmangled.
    func testBundleHandlesAwkwardFilenames() throws {
        let awkward = ["Sermon Notes 2026-10-04.jpg", "Ünïcode & symbols.jpg", "Deck+plus(1).jpg"]
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in awkward {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let group = ConversionGroup(sourceName: "Awkward Names JPEGs", folderURL: folder)

        let package = try ProPresenterPackage.package(
            group: group,
            destinationDirectory: folder.appendingPathComponent("Packages", isDirectory: true),
            pixelSize: { _ in PixelSize(width: 800, height: 600) }
        )
        let archive = try Data(contentsOf: package)
        XCTAssertEqual(
            Set(try ZipReader.entries(in: archive).map(\.path)),
            Set(["Awkward Names.pro"] + awkward)
        )
        XCTAssertNoThrow(try ZipReader.data(at: "Ünïcode & symbols.jpg", in: archive))
    }

    func testPackagingADeckWithNoImagesFails() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let group = ConversionGroup(sourceName: "Empty JPEGs", folderURL: folder)
        XCTAssertThrowsError(
            try ProPresenterPackage.package(group: group, pixelSize: { _ in nil })
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .noImages("Empty JPEGs"))
        }
    }

    func testUnreadableImageFails() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        XCTAssertThrowsError(
            try ProPresenterPackage.package(
                group: deck.group, destinationDirectory: deck.packages, pixelSize: { _ in nil }
            )
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
        /// Sibling of the deck folder, standing in for the bin's Packages folder.
        let packages: URL
        let group: ConversionGroup
    }

    private func makeTemporaryDirectory() throws -> URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ProSlideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeDeck(imageCount: Int) throws -> Deck {
        let folder = try makeTemporaryDirectory()
        for index in 1...imageCount {
            let name = String(format: "Sample Deck-%03d.jpg", index)
            let words = ["one", "two", "three", "four", "five"]
            try Data(words[index - 1].utf8).write(to: folder.appendingPathComponent(name))
        }
        let group = ConversionGroup(sourceName: "Sample Deck JPEGs", folderURL: folder)
        XCTAssertEqual(group.imageURLs.count, imageCount, "images must sort into page order")
        return Deck(folder: folder, packages: folder.appendingPathComponent("Packages", isDirectory: true), group: group)
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
    /// `ignoring` holds field numbers to skip at this level and at every level
    /// below. Paths, identifiers and labels are compared only for presence: they
    /// legitimately differ between the recording and anything this app writes.
    ///
    /// `ignoreAnywhere` is the opposite: field numbers to skip wherever they turn
    /// up, used for the URL root, which is *meant* to differ — the recording is a
    /// standalone `.pro` pointing into the home folder (root 2) while a bundle
    /// points at itself (root 12).
    private func assertSameShape(
        _ ours: [ProtoReader.Field],
        _ theirs: [ProtoReader.Field],
        ignoring ignored: Set<Int>,
        ignoreAnywhere: Set<Int> = [],
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
            // String payloads are identifiers, labels, filenames and URLs.
            if let bytes = field.bytes, isText(bytes) { continue }
            switch field.wireType {
            case 2:
                let ourNested = try? ProtoReader.fields(of: field.bytes!)
                let theirNested = try? ProtoReader.fields(of: match.bytes!)
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
                    ours, theirs,
                    ignoring: ignored,
                    ignoreAnywhere: ignoreAnywhere,
                    context: "\(context).\(field.number)", depth: depth + 1, file: file, line: line
                )
            default:
                guard !ignoreAnywhere.contains(field.number) else { continue }
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
