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

    // MARK: - The real presentation

    /// `real.pro` is a presentation ProPresenter exported itself, complete with
    /// images. It is the only trustworthy ground truth for media: the older
    /// `reference.pro` fixture was hand-edited, its UUIDs replaced with
    /// sequential placeholders and its paths overwritten with `deck-NNN.jpg`, and
    /// in eight of thirteen cues its two URL fields disagree with each other. No
    /// real file does that. Nothing about how ProPresenter names media could be
    /// learned from it, and several wrong conclusions here came from trying.
    func testRealFixtureHasTheShapeTheWriterMustMatch() throws {
        let presentation = try ProtoReader.fields(of: realFixture())

        XCTAssertEqual(presentation.all(11).count, 0, "no arrangements")
        XCTAssertEqual(presentation.all(10).count, 0, "no selected arrangement")
        XCTAssertEqual(presentation.all(12).count, 1, "one cue group")
        let cues = try presentation.messages(13)
        XCTAssertEqual(cues.count, 41)

        // One action per cue, and every one a presentation slide.
        var actionTypes: Set<UInt64> = []
        for cue in cues {
            let actions = try cue.messages(10)
            XCTAssertEqual(actions.count, 1, "a cue carries exactly one action")
            actionTypes.insert(try XCTUnwrap(actions.first?.uint(9)))
        }
        XCTAssertEqual(
            actionTypes, [11],
            "all presentation slides, and no media actions anywhere in the file"
        )

        // The image hangs off the slide at 10.23.2.1.1.1.9.3.
        let first = try actions(of: cues[0])[0]
        let element = try XCTUnwrap(mediaElement(of: first))
        XCTAssertEqual(
            element.map(\.number).sorted(), [1, 2, 3, 5],
            "uuid, url, metadata and element type"
        )

        let url = try XCTUnwrap(element.message(2))
        XCTAssertEqual(
            url.map(\.number).sorted(), [1, 3, 4],
            "absolute string, platform, local path"
        )
        XCTAssertEqual(
            try XCTUnwrap(url.string(1)),
            "file:///Users/techuser/Documents/ProPresenter/Media/Imported/"
                + "D7A11B7C-D837-4F34-AD63-547229289B4C/5B9CC38B-2BFB-41AD-AB63-D2719F37F2DE/Slide19.jpg",
            "a full file:// URL, not a percent-encoded fragment"
        )

        let local = try XCTUnwrap(url.message(4))
        XCTAssertEqual(
            try XCTUnwrap(local.uint(1)), 10,
            "ROOT_SHOW: resolved against ProPresenter's own document root"
        )
        XCTAssertEqual(
            try XCTUnwrap(local.string(2)),
            "Media/Imported/D7A11B7C-D837-4F34-AD63-547229289B4C/"
                + "5B9CC38B-2BFB-41AD-AB63-D2719F37F2DE/Slide19.jpg"
        )

        let metadata = try XCTUnwrap(element.message(3))
        XCTAssertEqual(metadata.string(5), "JPG", "uppercase")
        XCTAssertEqual(metadata.uint(6), 1, "SDR")

        let drawing = try XCTUnwrap(try XCTUnwrap(element.message(5)).message(1))
        XCTAssertEqual(
            drawing.map(\.number).sorted(), [5, 7, 14, 15],
            "natural size, bounds, crop, alpha — and no field 16, which we used to write"
        )
        XCTAssertEqual(drawing.uint(15), 1, "alpha_type: straight")
    }

    /// The cue group lists the same cues, but in the slide-list order rather than
    /// the order they appear in the file. Worth knowing before anyone "fixes" it
    /// to match document order.
    func testRealCueGroupListsEveryCueInItsOwnOrder() throws {
        let presentation = try ProtoReader.fields(of: realFixture())
        let cues = try presentation.messages(13)
        let listed = try presentation.messages(12)[0].messages(2)

        let cueIDs = Set(cues.compactMap { try? $0.message(1)?.string(1) })
        XCTAssertEqual(
            Set(listed.compactMap { $0.string(1) }), cueIDs,
            "the group names every cue exactly once"
        )
    }

    // MARK: - The generated manifest

    /// The generated document must have the same *shape* as one ProPresenter wrote
    /// itself: one action per cue, of the slide kind, carrying the image.
    ///
    /// The structural facts this pins are the ones that were wrong for a long time
    /// and that no field-by-field diff had caught, because they only show up when
    /// compared against a real export:
    ///
    /// - exactly one action per cue, and it is a presentation slide — a real
    ///   presentation contains **no** media actions, so the image has to hang off
    ///   the slide rather than sit beside it.
    /// - the image is reachable at `10.23.2.1.1.1.9.3.2`.
    func testGeneratedManifestMatchesTheRealCueShape() throws {
        let slide = ProSlide(
            imageURL: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/deck-001.jpg"),
            pixelSize: PixelSize(width: 1920, height: 1080)
        )
        let generated = try ProtoReader.fields(
            of: ProPresenterDocument.encode(name: "Deck", slides: [slide], showRoot: fixtureShow)
        )
        let real = try ProtoReader.fields(of: realFixture())

        let ourCue = try XCTUnwrap(generated.message(13))
        let realCue = try XCTUnwrap(real.message(13))

        let ourActions = try ourCue.messages(10)
        let realActions = try realCue.messages(10)

        XCTAssertEqual(
            ourActions.count, 1,
            "a cue holds exactly one action; real presentations have no media actions at all"
        )
        XCTAssertEqual(realActions.count, 1, "the recording agrees")

        XCTAssertEqual(
            try XCTUnwrap(ourActions.first?.uint(9)), 11,
            "ACTION_TYPE_PRESENTATION_SLIDE"
        )
        XCTAssertEqual(try XCTUnwrap(realActions.first?.uint(9)), 11)

        // Both reach the media at the same nesting depth. Nothing here is a
        // coincidence of the fixture: it is the only path a real file uses.
        func urlIn(_ action: [ProtoReader.Field]) throws -> [ProtoReader.Field] {
            let slideType = try XCTUnwrap(action.message(23))
            let presentationSlide = try XCTUnwrap(slideType.message(2))
            let baseSlide = try XCTUnwrap(presentationSlide.message(1))
            let element = try XCTUnwrap(baseSlide.message(1))
            let graphics = try XCTUnwrap(element.message(1))
            let mediaHolder = try XCTUnwrap(graphics.message(9))
            let mediaElement = try XCTUnwrap(mediaHolder.message(3))
            return try XCTUnwrap(mediaElement.message(2))
        }

        let ourURL = try urlIn(ourActions[0])
        let realURL = try urlIn(realActions[0])

        XCTAssertEqual(
            ourURL.map(\.number).sorted(), realURL.map(\.number).sorted(),
            "the URL message carries the same fields as the recording"
        )
        XCTAssertEqual(ourURL.uint(3), 1, "platform: macOS")
        XCTAssertEqual(realURL.uint(3), 1)
    }

    func testGeneratedManifestKeepsSlideOrderAndSizes() throws {
        let slides = (1...3).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080),
                label: "Slide \(index)"
            )
        }
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides, showRoot: fixtureShow))

        XCTAssertEqual(presentation.string(3), "Deck")
        let cues = try presentation.messages(13)
        XCTAssertEqual(presentation.all(12).count, 1, "one group holding the deck in order")

        for (index, cue) in cues.enumerated() {
            let actions = try XCTUnwrap(cue.messages(10))
            XCTAssertEqual(actions.count, 1, "one action per cue")

            let mediaElement = try XCTUnwrap(mediaElement(of: actions[0]))
            let natural = try XCTUnwrap(
                try XCTUnwrap(try XCTUnwrap(mediaElement.message(5)).message(1)).message(5)
            )
            XCTAssertEqual(natural.double(1), 1920)
            XCTAssertEqual(natural.double(2), 1080)

            // Each cue must point at its own image.
            let local = try XCTUnwrap(try XCTUnwrap(mediaElement.message(2)).message(4))
            XCTAssertEqual(local.string(2), "Media/deck-00\(index + 1).jpg")
        }
    }

    /// A cue's action list.
    private func actions(of cue: [ProtoReader.Field]) throws -> [[ProtoReader.Field]] {
        try cue.messages(10)
    }

    /// Walks `10.23.2.1.1.1.9.3` to the media element inside a slide action.
    private func mediaElement(of action: [ProtoReader.Field]) throws -> [ProtoReader.Field]? {
        let slideType = try XCTUnwrap(action.message(23))
        let presentationSlide = try XCTUnwrap(slideType.message(2))
        let baseSlide = try XCTUnwrap(presentationSlide.message(1))
        let element = try XCTUnwrap(baseSlide.message(1))
        let graphics = try XCTUnwrap(element.message(1))
        let mediaHolder = try XCTUnwrap(graphics.message(9))
        return try XCTUnwrap(mediaHolder.message(3))
    }

    /// Every cue group's identifiers must be the cues' own, in order. A group
    /// naming cues that do not exist leaves ProPresenter with no readable
    /// sequence, and this is exactly what a naive implementation gets wrong by
    /// minting identifiers independently in the two places.
    func testGeneratedCueGroupNamesTheCuesItHolds() throws {
        let slides = (1...3).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080)
            )
        }
        let presentation = try ProtoReader.fields(of: ProPresenterDocument.encode(name: "Deck", slides: slides, showRoot: fixtureShow))

        let cueUUIDs = try presentation.messages(13).map { try XCTUnwrap($0.message(1)?.string(1)) }
        XCTAssertEqual(cueUUIDs.count, 3, "identifiers are distinct, not shared")
        XCTAssertEqual(Set(cueUUIDs).count, 3)

        let group = try XCTUnwrap(presentation.messages(12).first)
        let listed = try group.messages(2).map { try XCTUnwrap($0.string(1)) }
        XCTAssertEqual(listed, cueUUIDs, "the group must list the cues in document order")
    }

    /// A flat deck has no arrangements at all.
    ///
    /// I added arrangements and `selected_arrangement` on an earlier inference,
    /// and they were wrong: `Fixtures/real.pro`, exported by ProPresenter itself,
    /// records neither. Emitting fields a real file never contains is the kind of
    /// invention that makes a manifest unreadable, so this pins their absence.
    func testGeneratedManifestDeclaresNoArrangements() throws {
        let slides = (1...2).map { index in
            ProSlide(
                imageURL: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/deck-00\(index).jpg"),
                pixelSize: PixelSize(width: 1920, height: 1080)
            )
        }
        let generated = try ProtoReader.fields(
            of: ProPresenterDocument.encode(name: "Deck", slides: slides, showRoot: fixtureShow)
        )
        let real = try ProtoReader.fields(of: realFixture())

        XCTAssertEqual(generated.all(11).count, 0, "no arrangements, matching the recording")
        XCTAssertEqual(generated.all(10).count, 0, "and no selected arrangement")
        XCTAssertEqual(real.all(11).count, 0)
        XCTAssertEqual(real.all(10).count, 0)

        // One group is still what gives the deck its order.
        XCTAssertEqual(generated.all(12).count, 1)
    }

    /// Every path a manifest names is inside ProPresenter's own document root.
    ///
    /// ProSlide used to climb out of it with `..` to reach the deck's images
    /// where they sat in the bin. No real presentation does that — `real.pro`'s
    /// 41 media files all live under `Media/Imported` — and it is the likeliest
    /// reason a deck imported as placeholders. The packager now stages its media
    /// into that tree, so the path is always a descent.
    func testRelativePathNeverLeavesTheShowRoot() {
        let show = URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter")
        XCTAssertEqual(
            ProPresenterDocument.relativePath(
                of: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/a.jpg"),
                from: show
            ),
            "Media/a.jpg",
            "a path inside the root needs no climbing"
        )
        XCTAssertFalse(
            ProPresenterDocument.relativePath(
                of: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/a.jpg"),
                from: show
            )?.contains("..") ?? true,
            "and it never climbs back out"
        )
    }

    // MARK: - Media references

    /// How media must be referenced for ProPresenter to resolve it.
    ///
    /// Every one of these was wrong at least once, so each is pinned against
    /// `Fixtures/real.pro`, a presentation ProPresenter exported itself.
    ///
    /// This one packages rather than only encoding, because the path is no longer
    /// a matter of spelling: the packager stages the image into ProPresenter's
    /// media tree first, and the manifest names it from there.
    func testMediaIsReferencedTheWayProPresenterResolvesIt() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        let file = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: out,
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        let manifest = try ProtoReader.fields(of: try Data(contentsOf: file))
        let cues = try manifest.messages(13)
        XCTAssertEqual(cues.count, 1)
        let actions = try cues[0].messages(10)
        let element = try XCTUnwrap(mediaElement(of: actions[0]))

        let url = try XCTUnwrap(element.message(2))
        let local = try XCTUnwrap(url.message(4))

        XCTAssertEqual(
            local.uint(1), 10,
            "ROOT_SHOW: media resolves against ProPresenter's own document root. "
                + "All 82 media URLs in real.pro use it."
        )
        XCTAssertEqual(
            local.string(2),
            try stagedPath(of: deck.group, image: deck.group.imageURLs[0].lastPathComponent, in: showRoot),
            "the image is named from inside ProPresenter's media tree, as real.pro names its own"
        )

        let staged = showRoot.appendingPathComponent(try XCTUnwrap(local.string(2)))
        XCTAssertEqual(
            url.string(1),
            staged.standardizedFileURL.absoluteString,
            "absolute_string is the full file:// URL of the staged file, as real.pro records"
        )
        XCTAssertEqual(url.uint(3), 1, "platform: macOS")

        let metadata = try XCTUnwrap(element.message(3))
        XCTAssertEqual(metadata.string(5), "JPG", "uppercase, matching real.pro")
        XCTAssertEqual(metadata.uint(6), 1, "colour format: SDR")
    }

    /// ProPresenter reads the image's `file.localUrl` as well as the media URL,
    /// and they have to name the same file or the image resolves inconsistently.
    /// Both are URL messages, so both nest as `url.local(4).{1:root,2:path}`; the
    /// longer route is `element.mediaType(5) -> file(2) -> localUrl(1)`.
    func testImageFileLocalURLMatchesTheMediaURL() throws {
        let slide = ProSlide(
            imageURL: URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter/Media/deck-001.jpg"),
            pixelSize: PixelSize(width: 1920, height: 1080)
        )
        let presentation = try ProtoReader.fields(
            of: ProPresenterDocument.encode(name: "Deck", slides: [slide], showRoot: fixtureShow)
        )
        let actions = try XCTUnwrap(presentation.message(13)).messages(10)
        let element = try XCTUnwrap(mediaElement(of: actions[0]))

        let direct = try XCTUnwrap(try XCTUnwrap(element.message(2)).message(4))
        let viaFile = try XCTUnwrap(
            try XCTUnwrap(try XCTUnwrap(element.message(5)).message(2)).message(1)
        ).message(4)
        let fileLocal = try XCTUnwrap(viaFile)

        XCTAssertEqual(direct.string(2), try XCTUnwrap(fileLocal.string(2)), "same file")
        XCTAssertEqual(direct.uint(1), try XCTUnwrap(fileLocal.uint(1)), "same root")
        XCTAssertEqual(direct.string(1), try XCTUnwrap(fileLocal.string(1)), "same absolute URL")
    }

    func testEmptyDeckStillDescribesAReadableDocument() throws {
        let presentation = try ProtoReader.fields(
            of: ProPresenterDocument.encode(name: "Empty", slides: [], showRoot: fixtureShow)
        )
        XCTAssertEqual(presentation.all(13).count, 0, "no cues")
        XCTAssertEqual(presentation.all(12).count, 1, "still one group, holding no cues")
        XCTAssertEqual(presentation.string(3), "Empty", "and it is still named")
    }

    // MARK: - Packaging

    /// The `.pro` must be written *outside* the deck's own folder.
    ///
    /// ProPresenter imports a folder containing a `.pro` as a presentation rather
    /// than as a sequence of slides, so a `.pro` left beside a deck's JPEGs turns
    /// the JPEG-folder drag into a presentation import — which is exactly what
    /// happened before this was separated out.
    func testPresentationIsWrittenOutsideTheDeckFolder() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        let presentation = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: out,
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        XCTAssertEqual(presentation.lastPathComponent, "Sample Deck.pro")
        XCTAssertEqual(presentation.deletingLastPathComponent(), out)
        XCTAssertNotEqual(
            presentation.deletingLastPathComponent(), deck.folder,
            "the .pro must not land in the deck folder or the JPEG-folder drag breaks"
        )

        // Not a ZIP any more, and not a probundle either: a `.pro` is a bare
        // protobuf message, which is what makes it readable by ProPresenter at
        // all. Its images are staged separately, as linked names.
        let bytes = try Data(contentsOf: presentation)
        XCTAssertFalse(
            bytes.starts(with: [0x50, 0x4B]),
            "a .pro must not be an archive; ProPresenter reads it as a bare message"
        )
        XCTAssertNoThrow(try ProtoReader.fields(of: bytes))
        XCTAssertLessThan(bytes.count, 4_000, "a manifest names its media; it does not carry it")
    }

    /// The regression guard for the behaviour above: a deck folder holds JPEGs
    /// and nothing else. ProPresenter sees a stray `.pro` in there and imports the
    /// presentation instead of the slides.
    func testDeckFolderHoldsJPEGsAndNothingElse() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        _ = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: out,
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: deck.folder.path)
        XCTAssertEqual(
            names.sorted(), ["Sample Deck-001.jpg", "Sample Deck-002.jpg"],
            "the packager must not add anything to a deck folder"
        )
        XCTAssertTrue(
            names.allSatisfy { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) },
            "only JPEGs may live in a deck folder"
        )
    }

    /// Every path the manifest names has to resolve to a real file inside
    /// ProPresenter's document root. This is how ProPresenter finds them.
    func testEveryManifestPathResolvesToAFileOnDisk() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        let file = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: out,
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )
        let manifest = try ProtoReader.fields(of: try Data(contentsOf: file))

        let paths = try manifest.messages(13).map { cue -> String in
            let actions = try XCTUnwrap(cue.messages(10))
            let element = try XCTUnwrap(mediaElement(of: actions[0]))
            let local = try XCTUnwrap(try XCTUnwrap(element.message(2)).message(4))
            XCTAssertEqual(local.uint(1), 10, "media always names ProPresenter's document root")
            return try XCTUnwrap(local.string(2))
        }
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            XCTAssertFalse(
                path.contains(".."),
                "\(path) climbs out of ProPresenter's root, which no real presentation does"
            )
            let target = showRoot.appendingPathComponent(path).standardizedFileURL
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target.path),
                "manifest names \(path), which does not resolve to a file under ProPresenter's root"
            )
        }

        // The paths really are the deck's own images, staged into ProPresenter's
        // tree — not merely names that happen to resolve to something.
        XCTAssertEqual(
            Set(paths.map { ($0 as NSString).lastPathComponent }),
            Set(deck.group.imageURLs.map(\.lastPathComponent)),
            "the manifest must name exactly the deck's images"
        )

        // And they are the same bytes, not a second copy: a hard link is a second
        // directory entry for one inode, so a 300-page deck still costs one
        // storage. This is what keeps staging from duplicating the bin.
        for image in deck.group.imageURLs {
            let staged = try XCTUnwrap(
                stagedFiles(of: deck.group, in: showRoot)[image.lastPathComponent]
            )
            XCTAssertEqual(
                try inode(of: staged), try inode(of: image),
                "\(image.lastPathComponent) was copied rather than linked"
            )
        }

        // The images are left exactly as they were: the packager must not move or
        // rewrite them, or the deck's own files would go stale.
        XCTAssertEqual(
            try Data(contentsOf: deck.folder.appendingPathComponent("Sample Deck-002.jpg")),
            Data("two".utf8)
        )
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

        // A destination entirely outside the deck folder, matching where the app really
        // writes presentations.
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let presentation = try ProPresenterPackage.package(
            group: group,
            destinationDirectory: out,
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 800, height: 600) }
        )
        XCTAssertEqual(presentation.lastPathComponent, "Awkward Names.pro")
        XCTAssertEqual(presentation.deletingLastPathComponent(), out)

        let manifest = try ProtoReader.fields(of: try Data(contentsOf: presentation))
        var seen: [String] = []
        for cue in try manifest.messages(13) {
            let actions = try cue.messages(10)
            let element = try XCTUnwrap(mediaElement(of: actions[0]))
            let url = try XCTUnwrap(element.message(2))
            let path = try XCTUnwrap(try XCTUnwrap(url.message(4)).string(2))

            // The path is relative to ProPresenter's root, so it ends in the
            // image's filename.
            let filename = (path as NSString).lastPathComponent
            XCTAssertTrue(awkward.contains(filename), "unexpected filename \(filename)")
            seen.append(filename)
            XCTAssertFalse(path.contains(".."), "\(path) climbs out of the show root")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: showRoot.appendingPathComponent(path).standardizedFileURL.path
                ),
                "\(path) does not resolve to a file under ProPresenter's root"
            )

            // The absolute URL is percent-encoded even though the relative path is
            // not, so a name with a space survives both forms.
            let display = try XCTUnwrap(url.string(1))
            XCTAssertTrue(display.hasPrefix("file:///"), "absolute_string is a full URL")
            XCTAssertFalse(display.contains(" "), "and it is percent-encoded: \(display)")
        }
        XCTAssertEqual(Set(seen), Set(awkward), "every awkward filename must be referenced")
    }

    /// A rebuilt presentation replaces the old one rather than leaving a stale
    /// file beside the deck — and its staging is replaced too, so ProPresenter is
    /// never offered media the presentation no longer names.
    func testRewritingADeckReplacesTheEarlierPresentation() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }

        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let pixelSize: (URL) -> PixelSize? = { _ in PixelSize(width: 1920, height: 1080) }
        let first = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, showRoot: showRoot, pixelSize: pixelSize
        )
        let before = try Data(contentsOf: first)

        let second = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, showRoot: showRoot, pixelSize: pixelSize
        )
        XCTAssertEqual(first, second, "the name is derived from the deck, so it is stable")

        // Identifiers are fresh each time, so a rewrite is a genuinely new
        // document rather than a byte-identical one being ignored.
        let after = try Data(contentsOf: second)
        XCTAssertNotEqual(before, after)
        XCTAssertNoThrow(try ProtoReader.fields(of: after))

        // And it overwrote rather than accumulating: one .pro in the destination,
        // and the deck folder still holds only its JPEGs.
        let written = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        XCTAssertEqual(written, Set(["Sample Deck.pro"]))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: deck.folder.path)),
            Set(["Sample Deck-001.jpg", "Sample Deck-002.jpg"])
        )
    }

    /// Staging is replaced, not joined: a rebuild leaves one media item holding
    /// one link per slide, however many times it has been built.
    func testRebuildingReplacesStagedMediaRatherThanAccumulating() throws {
        let deck = try makeDeck(imageCount: 3)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let pixelSize: (URL) -> PixelSize? = { _ in PixelSize(width: 1920, height: 1080) }

        _ = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, showRoot: showRoot, pixelSize: pixelSize
        )
        let first = try stagedFiles(of: deck.group, in: showRoot)

        _ = try ProPresenterPackage.package(
            group: deck.group, destinationDirectory: out, showRoot: showRoot, pixelSize: pixelSize
        )
        let second = try stagedFiles(of: deck.group, in: showRoot)

        XCTAssertEqual(second.count, first.count, "a rebuild replaces its staging rather than joining it")
        for (name, url) in second {
            XCTAssertEqual(
                try inode(of: url), try inode(of: try XCTUnwrap(first[name])),
                "\(name) was written afresh rather than linked to the deck's own file"
            )
        }
    }

    /// The hard link is not decoration: it is the difference between naming the
    /// deck's bytes and holding a second copy of them.
    func testStagedMediaNamesTheDecksBytesRatherThanCopyingThem() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }

        _ = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: try makeTemporaryDirectory(),
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
        )

        let image = deck.group.imageURLs[0]
        let staged = try XCTUnwrap(stagedFiles(of: deck.group, in: showRoot)[image.lastPathComponent])
        XCTAssertEqual(try inode(of: staged), try inode(of: image), "one inode, two names")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: image))
    }

    /// A ProPresenter library on another volume cannot hold a hard link to the
    /// bin, so the image is copied there instead. The bytes cost more; the
    /// presentation still resolves, which is the part that matters.
    func testPackagingFallsBackToCopyingWhenLinkingFails() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let showRoot = try makeShowRoot()
        defer { try? FileManager.default.removeItem(at: showRoot) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        _ = try ProPresenterPackage.package(
            group: deck.group,
            destinationDirectory: out,
            showRoot: showRoot,
            pixelSize: { _ in PixelSize(width: 1920, height: 1080) },
            linkMedia: { _, _ in throw ProPackageError.stageFailed("no link across volumes") }
        )

        let image = deck.group.imageURLs[0]
        let staged = try XCTUnwrap(stagedFiles(of: deck.group, in: showRoot)[image.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: image))
    }

    /// ProSlide never creates ProPresenter's library. A `Media/Imported` tree
    /// anywhere else is media nothing will read, so the deck is left alone and
    /// the card reports why it fell back to dragging its JPEG folder.
    func testPackagingReportsAMissingProPresenterFolder() throws {
        let deck = try makeDeck(imageCount: 2)
        defer { try? FileManager.default.removeItem(at: deck.folder) }
        let out = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        // Inside a folder that exists, but with no ProPresenter library in it.
        let showRoot = out.appendingPathComponent("Not Installed/ProPresenter")

        XCTAssertThrowsError(
            try ProPresenterPackage.package(
                group: deck.group,
                destinationDirectory: out,
                showRoot: showRoot,
                pixelSize: { _ in PixelSize(width: 1920, height: 1080) }
            )
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .showRootUnavailable(showRoot.path))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: showRoot.path),
            "a missing library must not be created"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: out.path), [],
            "and nothing is written at all when there is nowhere to stage media"
        )
    }

    func testPackagingADeckWithNoImagesFails() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let group = ConversionGroup(sourceName: "Empty JPEGs", folderURL: folder)
        XCTAssertThrowsError(
            try ProPresenterPackage.package(
                group: group, destinationDirectory: try makeTemporaryDirectory(),
                pixelSize: { _ in nil }
            )
        ) { error in
            XCTAssertEqual(error as? ProPackageError, .noImages("Empty JPEGs"))
        }
    }

    func testUnreadableImageFails() throws {
        let deck = try makeDeck(imageCount: 1)
        defer { try? FileManager.default.removeItem(at: deck.folder) }

        XCTAssertThrowsError(
            try ProPresenterPackage.package(
                group: deck.group, destinationDirectory: try makeTemporaryDirectory(),
                pixelSize: { _ in nil }
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

    /// The ProPresenter document root the fixture-shaped manifests name media
    /// against. Injecting it keeps expectations independent of whoever runs the
    /// suite. The manifests built against it are pure — the packager is what
    /// touches the disk, and it is given a real root.
    private var fixtureShow: URL { URL(fileURLWithPath: "/Users/someone/Documents/ProPresenter") }

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

    /// A stand-in for ProPresenter's document root.
    ///
    /// A real folder, because the packager stages media into it, and deliberately
    /// under the same temporary root as the decks so a hard link between the two
    /// is possible without permissions to write anywhere else.
    private func makeShowRoot(named: String = "ProPresenter") throws -> URL {
        let show = try makeTemporaryDirectory().appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
        return show
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

    /// Every staged file for a deck, keyed by filename.
    ///
    /// Read off disk rather than recomputed: where the packager put the deck is
    /// part of what is being checked, so the helper asks the same function
    /// production does and then looks.
    private func stagedFiles(of group: ConversionGroup, in showRoot: URL) throws -> [String: URL] {
        let deck = ProPresenterPackage.stagedMediaDirectory(for: group, in: showRoot)
        let items = try FileManager.default.contentsOfDirectory(atPath: deck.path)
        XCTAssertEqual(items.count, 1, "one media item per packaging")
        let item = deck.appendingPathComponent(items[0], isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
        return Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0) })
    }

    /// The manifest-relative path of one staged image: `Media/Imported/…`, the
    /// deck's folder inside ProPresenter's media tree, the media item's, and the
    /// image's own name.
    private func stagedPath(of group: ConversionGroup, image: String, in showRoot: URL) throws -> String {
        let deck = ProPresenterPackage.stagedMediaDirectory(for: group, in: showRoot)
        let items = try FileManager.default.contentsOfDirectory(atPath: deck.path)
        XCTAssertEqual(items.count, 1, "one media item per packaging")
        return "Media/Imported/\(deck.lastPathComponent)/\(items[0])/\(image)"
    }

    /// A file's inode number, which two hard-linked names for the same bytes
    /// share and two separate copies do not.
    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        return number.uint64Value
    }

    /// `real.pro`, a presentation ProPresenter exported itself with media in it.
    /// This is the only trustworthy ground truth for how media is referenced: the
    /// older `reference.pro` fixture was hand-edited, and its paths were replaced
    /// with sequential placeholders, so nothing about URL semantics could be
    /// learned from it.
    private func realFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("real.pro")
        return try Data(contentsOf: url)
    }
}
