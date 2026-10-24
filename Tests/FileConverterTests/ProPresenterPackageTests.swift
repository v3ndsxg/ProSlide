import XCTest
@testable import FileConverterCore

/// Covers the ProPresenter `.probundle` path: the protobuf and zip writers, the
/// manifest builder, and the packager that ties them together.
///
/// The manifest's shape was settled by importing generated bundles into
/// ProPresenter, which is the only real proof a bundle works. These tests pin
/// that shape so it cannot drift without someone noticing.
final class ProPresenterPackageTests: XCTestCase {

    // MARK: - Protobuf primitives

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

    // MARK: - Zip

    /// The standard CRC-32 check value: the checksum of the ASCII digits 1–9.
    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    /// Checked by the system's own `unzip`, which shares nothing with the
    /// writer: its integrity test recomputes every checksum and walks every
    /// header, so a wrong offset or size fails here.
    func testArchivePassesUnzipsIntegrityCheck() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("source.jpg")
        try Data(repeating: 0xAB, count: 70_000).write(to: image)

        let archive = folder.appendingPathComponent("test.zip")
        try ZipWriter.write([
            .init(name: "Deck.pro", source: .data(Data("manifest".utf8))),
            .init(name: "Media/Assets/Deck-001.jpg", source: .file(image)),
            .init(name: "Media/Assets/Ти є тут-002.jpg", source: .data(Data())),
        ], to: archive)

        let check = try run("/usr/bin/unzip", "-tq", archive.path)
        XCTAssertEqual(check.status, 0, check.output)

        // Listed by `bsdtar`, not `unzip`: macOS's `unzip` prints any
        // non-ASCII name as `?`, flag or no flag, so it cannot tell a garbled
        // name from a good one.
        let listing = try run("/usr/bin/bsdtar", "-tf", archive.path)
        XCTAssertEqual(
            listing.output.split(separator: "\n").map(String.init),
            ["Deck.pro", "Media/Assets/Deck-001.jpg", "Media/Assets/Ти є тут-002.jpg"],
            "names come back exactly, Cyrillic included"
        )
    }

    /// Every entry is stored rather than deflated, and flagged as UTF-8 so a
    /// Ukrainian deck name is not garbled by whatever unpacks it.
    func testEveryEntryIsStoredAndFlaggedUTF8() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("test.zip")
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        try ZipWriter.write([
            .init(name: "Тест.pro", source: .data(payload)),
            .init(name: "plain.txt", source: .data(Data("x".utf8))),
        ], to: archive)

        let entries = try TestZipReader.entries(of: Data(contentsOf: archive))
        XCTAssertEqual(entries.map(\.name), ["Тест.pro", "plain.txt"])
        for entry in entries {
            XCTAssertEqual(entry.method, 0, "\(entry.name) is stored")
            XCTAssertEqual(entry.flags & 0x0800, 0x0800, "\(entry.name) is flagged UTF-8")
        }
        XCTAssertEqual(entries[0].contents, payload)
    }

    func testDOSTimestampEncodesTheWallClock() throws {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day) = (2026, 10, 24)
        (parts.hour, parts.minute, parts.second) = (13, 45, 30)
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: parts))
        let (time, day) = ZipWriter.dosTimestamp(date)
        XCTAssertEqual(time, 13 << 11 | 45 << 5 | 15)
        XCTAssertEqual(day, (2026 - 1980) << 9 | 10 << 5 | 24)
    }

    // MARK: - The manifest

    /// One cue per slide, and each cue is exactly what ProPresenter imported:
    /// an empty presentation slide, then a foreground media action carrying the
    /// image. Not an image element on the slide — a media cue can be turned into
    /// a slide element in ProPresenter, but not the other way round.
    func testEveryCueIsAnEmptySlideThenAForegroundMediaAction() throws {
        let presentation = try decode(slides: [slide("Deck-001.jpg"), slide("Deck-002.jpg")])
        let cues = try presentation.messages(13)
        XCTAssertEqual(cues.count, 2)

        for cue in cues {
            let actions = try cue.messages(10)
            XCTAssertEqual(actions.map { $0.uint(9) }, [11, 2], "presentation slide, then media")

            let slide = try XCTUnwrap(actions[0].message(23)?.message(2)?.message(1))
            XCTAssertNil(slide.first(1), "the slide carries no elements: the image is the media action")
            XCTAssertNotNil(slide.first(6), "but it does carry the canvas")

            let media = try XCTUnwrap(actions[1].message(20))
            XCTAssertEqual(media.uint(10), 1, "LAYER_TYPE_FOREGROUND, not background")
            XCTAssertNotNil(media.first(5), "the media element")
            XCTAssertNotNil(media.first(8), "and the empty marker ProPresenter writes for an image")

            XCTAssertTrue(actions.allSatisfy { $0.bool(6) }, "both actions enabled")
            XCTAssertTrue(cue.bool(12), "and the cue itself")
        }
    }

    /// The image is named relative to the bundle and nowhere else. An absolute
    /// `file://` URL would name a file on the machine that built the bundle,
    /// which is exactly the reference that failed to resolve before bundles.
    func testMediaIsNamedInsideTheBundleAndNowhereElse() throws {
        let presentation = try decode(slides: [slide("Deck-001.jpg")])
        let element = try mediaElement(of: try XCTUnwrap(presentation.messages(13).first))

        let url = try XCTUnwrap(element.message(2))
        XCTAssertNil(url.first(1), "no absolute URL")
        XCTAssertNil(url.first(3), "no platform")
        let local = try XCTUnwrap(url.message(4))
        XCTAssertEqual(local.uint(1), 10, "ROOT_SHOW, which ProPresenter resolves against the bundle")
        XCTAssertEqual(local.string(2), "Media/Assets/Deck-001.jpg")

        // ProPresenter writes the location a second time as the image's
        // `file.local_url`, and the two have to agree.
        let file = try XCTUnwrap(element.message(5)?.message(2)?.message(1))
        XCTAssertEqual(file.first(4)?.bytes, url.first(4)?.bytes)
        XCTAssertNil(file.first(1))

        XCTAssertNil(element.first(10), "no asset identifier: ProPresenter assigns its own")
        XCTAssertNil(element.first(11))
    }

    /// Fields ProPresenter's own exports carry that a ProSlide bundle must not.
    /// Copying `content_destination` from an announcements deck sent a test
    /// presentation to the announcements layer.
    func testDocumentCarriesNoApplicationInfoDestinationOrDuration() throws {
        let presentation = try decode(slides: [slide("Deck-001.jpg")])
        XCTAssertNil(presentation.first(1), "application info")
        XCTAssertNil(presentation.first(7), "notes")
        XCTAssertNil(presentation.first(17), "timeline")
        XCTAssertNil(presentation.first(19), "content destination: the presentation layer is the default")

        let media = try XCTUnwrap(presentation.messages(13).first?.messages(10).last)
        XCTAssertNil(media.first(8), "no duration on the media action; ProPresenter applies its own")
    }

    /// The cue name and the slide label are the file name without its
    /// extension, which keeps slides findable in ProPresenter's cue list.
    func testCuesAreNamedAfterTheirImage() throws {
        let presentation = try decode(slides: [slide("Ти є тут-001.jpg")])
        let cue = try XCTUnwrap(presentation.messages(13).first)
        XCTAssertEqual(cue.string(2), "Ти є тут-001")
        let label = try XCTUnwrap(cue.messages(10).first?.message(3))
        XCTAssertEqual(label.string(2), "Ти є тут-001")
        XCTAssertEqual(presentation.string(3), "Deck")
    }

    func testCueGroupListsEveryCueInSlideOrder() throws {
        let presentation = try decode(slides: (1...4).map { slide(String(format: "Deck-%03d.jpg", $0)) })
        let groups = try presentation.messages(12)
        XCTAssertEqual(groups.count, 1, "one group holding the whole deck")

        let listed = try groups[0].messages(2).map { try XCTUnwrap($0.string(1)) }
        let cueIDs = try presentation.messages(13).map { try XCTUnwrap($0.message(1)?.string(1)) }
        XCTAssertEqual(listed, cueIDs, "the group names the cues, in order")
        XCTAssertEqual(Set(cueIDs).count, 4)

        let paths = try presentation.messages(13).map {
            try XCTUnwrap(mediaElement(of: $0).message(2)?.message(4)?.string(2))
        }
        XCTAssertEqual(paths, (1...4).map { String(format: "Media/Assets/Deck-%03d.jpg", $0) })
    }

    /// The canvas and the image's natural size are the image's own pixels, and
    /// the image scales to fill.
    func testSlideSizesComeFromTheImage() throws {
        let presentation = try decode(slides: [
            ProSlide(imageURL: URL(fileURLWithPath: "/bin/Deck-001.jpg"), pixelSize: PixelSize(width: 3840, height: 2160)),
        ])
        let cue = try XCTUnwrap(presentation.messages(13).first)
        let canvas = try XCTUnwrap(cue.messages(10).first?.message(23)?.message(2)?.message(1)?.message(6))
        XCTAssertEqual(canvas.double(1), 3840)
        XCTAssertEqual(canvas.double(2), 2160)

        let element = try mediaElement(of: cue)
        let drawing = try XCTUnwrap(element.message(5)?.message(1))
        XCTAssertEqual(drawing.uint(1), 1, "scale to fill")
        let natural = try XCTUnwrap(drawing.message(5))
        XCTAssertEqual(natural.double(1), 3840)
        XCTAssertEqual(natural.double(2), 2160)
        XCTAssertEqual(try element.message(3)?.string(5), "jpg", "the file's own extension")
    }

    func testEmptyDeckStillDescribesAReadableDocument() throws {
        let presentation = try decode(slides: [])
        XCTAssertEqual(presentation.string(3), "Deck")
        XCTAssertTrue(try presentation.messages(13).isEmpty)
    }

    // MARK: - Packaging

    /// The bundle holds the manifest and every image, byte for byte, under the
    /// paths the manifest names. That agreement is the whole contract: a path
    /// with no file behind it is a slide ProPresenter imports blank.
    func testBundleHoldsTheManifestAndEveryImageWhereItSaysTheyAre() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        let bundle = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        XCTAssertEqual(bundle.lastPathComponent, "Sample Deck.probundle")

        let entries = try TestZipReader.entries(of: Data(contentsOf: bundle))
        XCTAssertEqual(entries.map(\.name), [
            "Sample Deck.pro",
            "Media/Assets/Sample Deck-001.jpg",
            "Media/Assets/Sample Deck-002.jpg",
            "Media/Assets/Sample Deck-003.jpg",
        ])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.contents) })
        for image in deck.group.imageURLs {
            XCTAssertEqual(
                byName["Media/Assets/\(image.lastPathComponent)"], try Data(contentsOf: image),
                "\(image.lastPathComponent) is carried unchanged"
            )
        }

        let presentation = try ProtoReader.fields(of: try XCTUnwrap(byName["Sample Deck.pro"]))
        for cue in try presentation.messages(13) {
            let path = try XCTUnwrap(mediaElement(of: cue).message(2)?.message(4)?.string(2))
            XCTAssertNotNil(byName[path], "\(path) is named by the manifest and present in the bundle")
        }
    }

    /// The bundle goes in the presentations folder, never in the deck's own
    /// folder: ProPresenter imports a folder holding a presentation as that
    /// presentation, which would break the JPEG Files drag.
    func testBundleIsWrittenOutsideTheDeckFolderAndLeavesNoPartialBehind() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let before = try FileManager.default.contentsOfDirectory(atPath: deck.folder.path).sorted()

        try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deck.folder.path).sorted(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Sample Deck.probundle"])
    }

    /// Rebuilding replaces the bundle in place, and clears away a `.pro` from
    /// before bundles, which names media ProSlide no longer stages.
    func testRebuildingReplacesTheBundleAndRemovesAnOldPro() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        try Data("old".utf8).write(to: out.appendingPathComponent("Sample Deck.pro"))
        let pixelSize: (URL) -> PixelSize? = { _ in PixelSize(width: 1920, height: 1080) }

        let first = try ProPresenterPackage.package(group: deck.group, destinationDirectory: out, pixelSize: pixelSize)
        try FileManager.default.removeItem(at: deck.group.imageURLs[1])
        let refreshed = ConversionGroup(sourceName: deck.group.sourceName, folderURL: deck.folder)
        let second = try ProPresenterPackage.package(group: refreshed, destinationDirectory: out, pixelSize: pixelSize)

        XCTAssertEqual(first, second, "same deck, same file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Sample Deck.probundle"])
        let entries = try TestZipReader.entries(of: Data(contentsOf: second))
        XCTAssertEqual(entries.count, 2, "the manifest and the one image left")
    }

    /// Launch only ever offers a finished bundle. One cut short by a crash is
    /// still named `.partial`, and is not it.
    func testExistingBundleIgnoresAnInterruptedBuild() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        try Data("half".utf8).write(to: out.appendingPathComponent("Sample Deck.probundle.partial"))
        XCTAssertNil(ProPresenterPackage.existingBundle(for: deck.group, in: out))

        let bundle = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        XCTAssertEqual(ProPresenterPackage.existingBundle(for: deck.group, in: out), bundle)
    }

    func testCyrillicDeckNamesSurviveIntoTheBundle() throws {
        let folder = try makeTemporaryDirectory().appendingPathComponent("Ти є тут JPEGs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data("one".utf8).write(to: folder.appendingPathComponent("Ти є тут-001.jpg"))
        let group = ConversionGroup(sourceName: folder.lastPathComponent, folderURL: folder)
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        let bundle = try ProPresenterPackage.package(
            group: group, destinationDirectory: out, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        XCTAssertEqual(bundle.lastPathComponent, "Ти є тут.probundle")
        let entries = try TestZipReader.entries(of: Data(contentsOf: bundle))
        XCTAssertEqual(entries.map(\.name), ["Ти є тут.pro", "Media/Assets/Ти є тут-001.jpg"])
    }

    func testPackagingADeckWithNoImagesFails() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let group = ConversionGroup(sourceName: "Empty JPEGs", folderURL: folder)
        XCTAssertThrowsError(
            try ProPresenterPackage.package(group: group, destinationDirectory: folder, pixelSize: { _ in nil })
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .noImages("Empty JPEGs"))
        }
    }

    func testUnreadableImageFailsBeforeAnythingIsWritten() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertThrowsError(
            try ProPresenterPackage.package(group: deck.group, destinationDirectory: out, pixelSize: { _ in nil })
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .unreadableImage("Sample Deck-001.jpg"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    /// The presentation, and its bundle, carry the document's own name. The
    /// bin folder's marker and copy number are the bin's business.
    func testPresentationIsNamedAfterTheDocument() {
        func name(_ folder: String) -> String {
            ProPresenterPackage.presentationName(for: group(folder))
        }
        XCTAssertEqual(name("Sample Deck JPEGs"), "Sample Deck")
        XCTAssertEqual(name("Sample Deck JPEGs 2"), "Sample Deck", "a second conversion is the same document")
        XCTAssertEqual(name("Sample Deck JPEGs 12"), "Sample Deck")
        XCTAssertEqual(name("JPEGs Explained JPEGs"), "JPEGs Explained", "only the folder's own marker goes")
        XCTAssertEqual(name("Sample Deck JPEGs two"), "Sample Deck JPEGs two", "a word after it is part of the name")
        XCTAssertEqual(name("Already Named"), "Already Named")
    }

    /// The bin still tells two conversions of one document apart.
    func testTheBinShowsTheCopyNumber() {
        XCTAssertEqual(group("Sample Deck JPEGs").displayName, "Sample Deck")
        XCTAssertEqual(group("Sample Deck JPEGs 2").displayName, "Sample Deck 2")
        XCTAssertEqual(group("Sample Deck JPEGs two").displayName, "Sample Deck JPEGs two")
    }

    /// A second conversion of one document overwrites the first one's bundle:
    /// the Pro folder is staging, and the file keeps the document's name.
    func testASecondConversionOverwritesTheBundle() throws {
        let first = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: first.folder) }
        let secondFolder = try makeTemporaryDirectory().appendingPathComponent("Sample Deck JPEGs 2")
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondFolder.deletingLastPathComponent()) }
        try Data("one".utf8).write(to: secondFolder.appendingPathComponent("Sample Deck-001.jpg"))
        let second = ConversionGroup(sourceName: secondFolder.lastPathComponent, folderURL: secondFolder)
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let pixelSize: (URL) -> PixelSize? = { _ in PixelSize(width: 1920, height: 1080) }

        let a = try ProPresenterPackage.package(group: first.group, destinationDirectory: out, pixelSize: pixelSize)
        let b = try ProPresenterPackage.package(group: second, destinationDirectory: out, pixelSize: pixelSize)

        XCTAssertEqual(a, b)
        XCTAssertEqual(b.lastPathComponent, "Sample Deck.probundle")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Sample Deck.probundle"])
        XCTAssertEqual(try TestZipReader.entries(of: Data(contentsOf: b)).count, 2, "the second deck's one image")
    }

    /// Clear deletes the presentations folder. A bundle written afterwards must
    /// make it again; every one once failed with "could not be saved" instead.
    func testPackagingRecreatesAMissingPresentationsFolder() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("Pro", isDirectory: true)

        let bundle = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    private func group(_ folder: String) -> ConversionGroup {
        ConversionGroup(sourceName: folder, folderURL: URL(fileURLWithPath: "/tmp/\(folder)"))
    }

    /// End to end on real output: each fixture through the conversion engine,
    /// then packaged, then checked by `unzip` and decoded. The fake decks above
    /// hold placeholder bytes; these hold real JPEGs with real dimensions.
    ///
    /// CI also hands the bundles these write to Scripts/check-probundle.py,
    /// which shares no code with the writer or these readers.
    func testSamplePDFBecomesAValidBundle() async throws {
        try await assertFixtureBecomesAValidBundle("sample.pdf")
    }

    func testSamplePPTXBecomesAValidBundle() async throws {
        try XCTSkipUnless(ConversionEngine.installedLibreOffice() != nil, "LibreOffice is not installed; skipping PPTX path")
        try await assertFixtureBecomesAValidBundle("sample.pptx")
    }

    func testSamplePPTBecomesAValidBundle() async throws {
        try XCTSkipUnless(ConversionEngine.installedLibreOffice() != nil, "LibreOffice is not installed; skipping PPT path")
        try await assertFixtureBecomesAValidBundle("sample.ppt")
    }

    private func assertFixtureBecomesAValidBundle(_ fixture: String) async throws {
        let work = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var options = ConversionOptions()
        options.destination = work
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixture)")

        let folder = try await ConversionEngine().convert(input: sample, options: options) { _ in }
        let group = ConversionGroup(sourceName: folder.lastPathComponent, folderURL: folder)
        let out = work.appendingPathComponent("Pro", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let bundle = try ProPresenterPackage.package(group: group, destinationDirectory: out)
        exportBundle(bundle, kind: sample.pathExtension)

        let check = try run("/usr/bin/unzip", "-tq", bundle.path)
        XCTAssertEqual(check.status, 0, check.output)

        let entries = try TestZipReader.entries(of: Data(contentsOf: bundle))
        let image = try XCTUnwrap(group.imageURLs.first)
        XCTAssertEqual(entries.map(\.name), ["sample.pro", "Media/Assets/\(image.lastPathComponent)"])

        let presentation = try ProtoReader.fields(of: entries[0].contents)
        let cue = try XCTUnwrap(presentation.messages(13).first)
        let element = try mediaElement(of: cue)
        XCTAssertEqual(try element.message(2)?.message(4)?.string(2), "Media/Assets/\(image.lastPathComponent)")
        let natural = try XCTUnwrap(element.message(5)?.message(1)?.message(5))
        XCTAssertEqual(natural.double(1), 1920, "the default Full HD render of a 16:9 page")
        XCTAssertEqual(natural.double(2), 1080)
    }

    // MARK: - Helpers

    private struct Deck {
        let folder: URL
        let group: ConversionGroup
    }

    private func slide(_ name: String) -> ProSlide {
        ProSlide(imageURL: URL(fileURLWithPath: "/bin/\(name)"), pixelSize: PixelSize(width: 1920, height: 1080))
    }

    private func decode(slides: [ProSlide]) throws -> [ProtoReader.Field] {
        try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides))
    }

    /// The `rv.data.Media` inside a cue's media action.
    private func mediaElement(of cue: [ProtoReader.Field]) throws -> [ProtoReader.Field] {
        let action = try XCTUnwrap(cue.messages(10).first { $0.uint(9) == 2 })
        return try XCTUnwrap(action.message(20)?.message(5))
    }

    /// If FILE_CONVERTER_ARTIFACTS is set (CI), copy `bundle` to
    /// `bundles/<kind>/` there, so CI can check it with
    /// Scripts/check-probundle.py and upload it to be imported by hand.
    private func exportBundle(_ bundle: URL, kind: String) {
        guard let target = ProcessInfo.processInfo.environment["FILE_CONVERTER_ARTIFACTS"] else { return }
        let folder = URL(fileURLWithPath: target, isDirectory: true)
            .appendingPathComponent("bundles/\(kind)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(bundle.lastPathComponent)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.copyItem(at: bundle, to: out)
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
        return Deck(folder: folder, group: group)
    }

    private func run(_ tool: String, _ arguments: String...) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // A UTF-8 locale, or `bsdtar` escapes non-ASCII names as octal.
        process.environment = ["LC_ALL": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// A deliberately independent zip reader, for the same reason `ProtoReader`
/// exists: it shares no code with `ZipWriter`, so the two cannot agree on a
/// mistake. It reads only what a stored archive needs — the end record, the
/// central directory, and each entry's local header.
enum TestZipReader {
    struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let contents: Data
    }

    enum ReaderError: Error { case malformed(String) }

    static func entries(of data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        let end = bytes.count - 22
        guard end >= 0, u32(end) == 0x0605_4B50 else { throw ReaderError.malformed("no end record") }
        let count = u16(end + 10)
        var cursor = u32(end + 16)

        var entries: [Entry] = []
        for _ in 0..<count {
            guard u32(cursor) == 0x0201_4B50 else { throw ReaderError.malformed("directory entry") }
            let flags = UInt16(u16(cursor + 8))
            let method = UInt16(u16(cursor + 10))
            let size = u32(cursor + 24)
            let nameLength = u16(cursor + 28)
            let extra = u16(cursor + 30)
            let comment = u16(cursor + 32)
            let offset = u32(cursor + 42)
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            guard u32(offset) == 0x0403_4B50 else { throw ReaderError.malformed("local header for \(name)") }
            let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
            entries.append(Entry(
                name: name, flags: flags, method: method,
                contents: Data(bytes[start..<(start + size)])
            ))
            cursor += 46 + nameLength + extra + comment
        }
        return entries
    }
}
