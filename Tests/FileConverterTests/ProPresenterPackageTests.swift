import XCTest
@testable import FileConverterCore

/// Covers the ProPresenter `.pro` path: the protobuf writer, the manifest
/// builder, and the packager that ties them together.
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

        // A real ProPresenter file records no arrangement, so this fixture cannot
        // teach us the field numbers. They come from the published `.proto`
        // schema instead, and `testGeneratedManifestDeclaresOneSelectedArrangement`
        // pins that we emit them.
        XCTAssertEqual(presentation.all(11).count, 0, "the recording has no arrangements")
        XCTAssertEqual(presentation.all(10).count, 0, "and no selected arrangement")

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

        // ProPresenter's own standalone files point into the home folder (root 2)
        // and percent-encode the display string: `Pictures/5ways%20to%20give.jpg`.
        // We use root 12 instead, resolved against the `.pro`'s own folder, so the
        // encoding has to survive the same way.
        let local = try XCTUnwrap(url.message(4))
        XCTAssertEqual(local.uint(1), 2, "root: user home")
        XCTAssertEqual(local.string(2), "Pictures/deck-001.jpg")
        XCTAssertEqual(
            url.string(1), "Pictures/5ways%20to%20give.jpg",
            "absolute_string is percent-encoded, not a file:// URL"
        )

        let metadata = try XCTUnwrap(element.message(3))
        XCTAssertEqual(metadata.string(5), "JPG", "standalone .pro records JPEG in uppercase")
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
    ///
    /// This checks the recording's own bookkeeping: that each group names as many
    /// cues as the deck has. It is also the model for the writer's behaviour,
    /// since a group whose identifiers do not match the cues leaves ProPresenter
    /// with an unreadable order.
    func testReferenceCueGroupsAccountForEveryCue() throws {
        let presentation = try ProtoReader.fields(of: referenceFixture())
        let groups = try presentation.messages(12)
        var listed: [[ProtoReader.Field]] = []
        for group in groups { listed += try group.messages(2) }
        XCTAssertEqual(listed.count, presentation.all(13).count)
    }

    /// The recording's cue identifiers must actually be the cues' own, which is
    /// the invariant `ProPresenterDocument` has to preserve when it mints its own.
    func testReferenceCueGroupIdentifiersMatchTheCuesTheyName() throws {
        let presentation = try ProtoReader.fields(of: referenceFixture())

        var cueUUIDs: Set<String> = []
        for cue in try presentation.messages(13) {
            let uuid = try XCTUnwrap(try cue.message(1)?.string(1))
            cueUUIDs.insert(uuid)
        }

        let groups = try presentation.messages(12)
        var listed: [String] = []
        for group in groups {
            for identifier in try group.messages(2) {
                listed.append(try XCTUnwrap(identifier.string(1)))
            }
        }
        XCTAssertEqual(Set(listed), cueUUIDs, "a cue group must name cues that exist")
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
        // Field 1 is the URL's absolute string wherever it turns up, and it is expected
        // to differ: the recording resolves against the home folder, ours against
        // the .pro's own folder. testMediaIsReferencedTheWayProPresenterResolvesIt
        // pins our value.
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

    /// Every cue group's identifiers must be the cues' own, in order. A group
    /// naming cues that do not exist leaves ProPresenter with no readable
    /// sequence, and this is exactly what a naive implementation gets wrong by
    /// minting identifiers independently in the two places.
    func testGeneratedCueGroupNamesTheCuesItHolds() throws {
        let slides = (1...3).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080)
            )
        }
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides))

        let cueUUIDs = try presentation.messages(13).map { try XCTUnwrap($0.message(1)?.string(1)) }
        XCTAssertEqual(cueUUIDs.count, 3, "identifiers are distinct, not shared")
        XCTAssertEqual(Set(cueUUIDs).count, 3)

        let group = try XCTUnwrap(presentation.messages(12).first)
        let listed = try group.messages(2).map { try XCTUnwrap($0.string(1)) }
        XCTAssertEqual(listed, cueUUIDs, "the group must list the cues in document order")
    }

    /// An arrangement names the groups it shows, and `selected_arrangement` says
    /// which one is on screen. Without both, a deck can open with nothing in it.
    ///
    /// The recording has neither, so these field numbers come from the published
    /// `.proto` schema rather than from `reference.pro`.
    func testGeneratedManifestDeclaresOneSelectedArrangement() throws {
        let slides = (1...2).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080)
            )
        }
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides))

        let groupUUID = try XCTUnwrap(
            try XCTUnwrap(presentation.messages(12).first).message(1)?.message(1)?.string(1)
        )

        XCTAssertEqual(presentation.all(11).count, 1, "one arrangement")
        let arrangement = try XCTUnwrap(presentation.message(11))
        XCTAssertEqual(arrangement.string(2), "Deck")
        let arrangementUUID = try XCTUnwrap(arrangement.message(1)?.string(1))
        XCTAssertEqual(
            try arrangement.messages(3).map { try XCTUnwrap($0.string(1)) }, [groupUUID],
            "the arrangement must name the group, or ProPresenter cannot resolve it"
        )

        XCTAssertEqual(
            try presentation.message(10)?.string(1), arrangementUUID,
            "selected_arrangement must point at the arrangement"
        )
    }

    // MARK: - Media references

    /// The details that decide whether ProPresenter finds the images at all. Each
    /// of these was wrong at least once; they are pinned here so a future change
    /// cannot quietly reintroduce a deck that imports empty.
    func testMediaIsReferencedTheWayProPresenterResolvesIt() throws {
        let slide = ProSlide(
            imageURL: URL(fileURLWithPath: "/Users/someone/Pictures/Sermon Notes 2026-001.jpg"),
            pixelSize: PixelSize(width: 1920, height: 1080)
        )
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: [slide]))
        let cue = try XCTUnwrap(presentation.message(13))
        let element = try XCTUnwrap(try XCTUnwrap(try XCTUnwrap(cue.messages(10)[1].message(20)).message(5)))

        let url = try XCTUnwrap(element.message(2))
        let local = try XCTUnwrap(url.message(4))

        XCTAssertEqual(
            local.uint(1), 12,
            "media must use ROOT_CURRENT_RESOURCE, which ProPresenter resolves against the folder "
                + "holding the .pro. ROOT_SHOW (10) points at ProPresenter's library directory."
        )
        XCTAssertEqual(
            local.string(2), "Sermon Notes 2026-001.jpg",
            "the path is the bare filename, relative to the .pro itself"
        )
        XCTAssertEqual(
            url.string(1), "Sermon%20Notes%202026-001.jpg",
            "absolute_string must be percent-encoded; an unescaped space stops the URL resolving"
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

    func testPercentEncodingEscapesUTF8BytesNotCharacters() {
        XCTAssertEqual(ProPresenterDocument.percentEncoded("Slide 1.jpg"), "Slide%201.jpg")
        XCTAssertEqual(
            ProPresenterDocument.percentEncoded("Sermon Notes 2026-10-04.jpg"),
            "Sermon%20Notes%202026-10-04.jpg"
        )
        // `+` is a legal sub-delim, so it stays as it is.
        XCTAssertEqual(ProPresenterDocument.percentEncoded("Deck+plus(1).jpg"), "Deck+plus(1).jpg")

        // The accents are two UTF-8 bytes each, and both have to be written out.
        // Escaping per Character, or reading `asciiValue` (which is nil above
        // ASCII and falls back to 0), turns this into %00n%00code.
        XCTAssertEqual(ProPresenterDocument.percentEncoded("Ünïcode.jpg"), "%C3%9Cn%C3%AFcode.jpg")
        XCTAssertEqual(ProPresenterDocument.percentEncoded("Ünïcode & symbols.jpg"), "%C3%9Cn%C3%AFcode%20&%20symbols.jpg")
        XCTAssertFalse(
            ProPresenterDocument.percentEncoded("Ünïcode.jpg").contains("%00"),
            "a nil asciiValue would silently encode to %00"
        )
    }

    func testEmptyDeckStillDescribesAReadableDocument() throws {
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Empty", slides: []))
        XCTAssertEqual(presentation.all(13).count, 0, "no cues")
        XCTAssertEqual(presentation.all(12).count, 1, "still one group, holding no cues")

        // The arrangement still names that group, and is still selected: an empty
        // deck that points at nothing is not a valid document.
        let groupUUID = try XCTUnwrap(
            try XCTUnwrap(presentation.messages(12).first).message(1)?.message(1)?.string(1)
        )
        XCTAssertEqual(
            try XCTUnwrap(presentation.message(11)).messages(3).map { try XCTUnwrap($0.string(1)) },
            [groupUUID]
        )
        XCTAssertNotNil(try presentation.message(10)?.string(1))
    }

    // MARK: - Packaging

    /// The `.pro` has to land in the deck's own folder, because that is the
    /// folder ProPresenter resolves its media paths against. Written anywhere
    /// else it opens with every image missing.
    func testPresentationIsWrittenBesideTheImagesItPointsAt() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        let presentation = try ProPresenterPackage.package(
            group: deck.group,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        XCTAssertEqual(presentation.lastPathComponent, "Sample Deck.pro")
        XCTAssertEqual(presentation.deletingLastPathComponent(), deck.folder)

        // Not a ZIP any more: a `.pro` is a bare protobuf message, which is what
        // makes it readable by ProPresenter at all.
        let bytes = try Data(contentsOf: presentation)
        XCTAssertFalse(
            bytes.starts(with: [0x50, 0x4B]),
            "a .pro must not be an archive; ProPresenter reads it as a bare message"
        )
        XCTAssertNoThrow(try ProtoReader.fields(of: bytes))
    }

    /// Every filename the manifest points at must exist on disk next to the
    /// `.pro`, since that is how it resolves them.
    func testEveryManifestPathResolvesToAFileOnDisk() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        let presentation = try ProPresenterPackage.package(
            group: deck.group,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        let manifest = try ProtoReader.fields(of: try Data(contentsOf: presentation))
        let folder = presentation.deletingLastPathComponent()

        let paths = try manifest.messages(13).map { cue -> String in
            let actions = try XCTUnwrap(cue.messages(10))
            let element = try XCTUnwrap(try XCTUnwrap(actions[1].message(20)).message(5))
            return try XCTUnwrap(try XCTUnwrap(element.message(2)).message(4)).string(2)!
        }
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            let target = folder.appendingPathComponent(path)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target.path),
                "manifest points at \(path), which is not beside the .pro"
            )
        }

        // And the images are left exactly as they were: the packager must not
        // copy or move them, or the deck's own files would go stale.
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Sample Deck-002.jpg")), Data("two".utf8))
    }

    /// Real decks carry the document's name, which can contain spaces and
    /// non-ASCII characters. Those must survive both the round trip and the
    /// percent-encoding ProPresenter needs on the URL.
    func testPresentationHandlesAwkwardFilenames() throws {
        let awkward = ["Sermon Notes 2026-10-04.jpg", "Ünïcode & symbols.jpg", "Deck+plus(1).jpg"]
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in awkward {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let group = ConversionGroup(sourceName: "Awkward Names JPEGs", folderURL: folder)

        let presentation = try ProPresenterPackage.package(
            group: group,
            pixelSize: { _ in PixelSize(width: 800, height: 600) }
        )
        XCTAssertEqual(presentation.lastPathComponent, "Awkward Names.pro")
        XCTAssertEqual(presentation.deletingLastPathComponent(), folder)

        let manifest = try ProtoReader.fields(of: try Data(contentsOf: presentation))
        for cue in try manifest.messages(13) {
            let actions = try XCTUnwrap(cue.messages(10))
            let element = try XCTUnwrap(try XCTUnwrap(actions[1].message(20)).message(5))
            let url = try XCTUnwrap(element.message(2))
            let filename = try XCTUnwrap(try XCTUnwrap(url.message(4)).string(2))

            XCTAssertTrue(awkward.contains(filename), "unexpected filename \(filename)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path),
                "\(filename) does not exist on disk"
            )
            let display = try XCTUnwrap(url.string(1))
            XCTAssertFalse(
                display.contains(" "),
                "absolute_string must be percent-encoded: \(display)"
            )
        }
    }

    /// A rebuilt presentation replaces the old one rather than leaving a stale
    /// file beside the deck.
    func testRewritingADeckReplacesTheEarlierPresentation() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        let first = try ProPresenterPackage.package(
            group: deck.group, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        let before = try Data(contentsOf: first)

        let second = try ProPresenterPackage.package(
            group: deck.group, pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        XCTAssertEqual(first, second, "the name is derived from the deck, so it is stable")

        // Identifiers are fresh each time, so a rewrite is a genuinely new
        // document rather than a byte-identical one being ignored.
        let after = try Data(contentsOf: second)
        XCTAssertNotEqual(before, after)
        XCTAssertNoThrow(try ProtoReader.fields(of: after))

        // And the deck folder holds the JPEGs plus the one .pro, nothing else.
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: deck.folder.path))
        XCTAssertEqual(names, Set(["Sample Deck-001.jpg", "Sample Deck-002.jpg", "Sample Deck.pro"]))
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
            try ProPresenterPackage.package(group: deck.group, pixelSize: { _ in nil })
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

    private func referenceFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
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
    /// up, used for the URL's field 1, which is *meant* to differ — the recording
    /// resolves against the home folder, ours against the `.pro`'s own folder.
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
