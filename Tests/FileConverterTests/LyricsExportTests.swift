@testable import FileConverterCore
import XCTest

/// The Lyrics Formatter's presentation and bundle, read back with the tests'
/// own protobuf and zip readers. The lyrics are made up. What ProPresenter
/// accepts can only be proven by an import; these check the shape copied from
/// the church's own exported song holds together.
@MainActor
final class LyricsExportTests: XCTestCase {

    private let lyrics = """
    Verse 1
    Morning breaks across the hills
    Every shadow runs away

    Chorus
    Sing it out, sing it out
    Let the whole world hear

    Приспів
    Співаю Тобі
    Ти мій Бог

    Chorus
    """

    private func song(title: String = "Morning Song", artist: String = "Jane Doe", ccli: String = "1234567") -> LyricsSong {
        let parsed = LyricsParser.parse(lyrics, linesPerSlide: 4)
        return LyricsSong(title: title, artist: artist, ccliNumber: ccli, sections: parsed.sections, order: parsed.order)
    }

    private func decode(_ song: LyricsSong, name: String = "Morning Song") throws -> [ProtoReader.Field] {
        try ProtoReader.fields(of: LyricsDocument.encode(name: name, song: song))
    }

    /// The "Lyrics" text box's `Graphics.Text` in a cue.
    private func text(of cue: [ProtoReader.Field]) throws -> [ProtoReader.Field] {
        let action = try XCTUnwrap(cue.messages(10).first)
        let base = try XCTUnwrap(action.message(23)?.message(2)?.message(1))
        let element = try XCTUnwrap(base.messages(1).first)
        return try XCTUnwrap(element.message(1)?.message(13))
    }

    private func rtf(of cue: [ProtoReader.Field]) throws -> String {
        let bytes = try XCTUnwrap(try text(of: cue).first(5)?.bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - The presentation

    func testTheParserRecordsThePastedOrder() {
        let parsed = LyricsParser.parse(lyrics)
        XCTAssertEqual(parsed.sections.map(\.name), ["Verse 1:", "Chorus:", "Приспів:"])
        XCTAssertEqual(parsed.order, [0, 1, 2, 1], "the bare Chorus at the end names the Chorus again")
    }

    func testGroupsAreBlankThenEachSectionInItsColour() throws {
        let document = try decode(song())
        XCTAssertEqual(document.string(3), "Morning Song")
        let groups = try document.messages(12).map { try XCTUnwrap($0.message(1)) }
        XCTAssertEqual(groups.map { $0.string(2) }, ["Blank", "Verse 1:", "Chorus:", "Приспів:"])

        let expected: [LyricsSectionKind] = [.other, .verse, .chorus, .chorus]
        for (group, kind) in zip(groups, expected) {
            let color = try XCTUnwrap(group.message(3))
            XCTAssertEqual(color.float(1) ?? 0, Float((kind.color >> 16) & 0xFF) / 255, accuracy: 0.001)
            XCTAssertEqual(color.float(2) ?? 0, Float((kind.color >> 8) & 0xFF) / 255, accuracy: 0.001)
            XCTAssertEqual(color.float(3) ?? 0, Float(kind.color & 0xFF) / 255, accuracy: 0.001)
            XCTAssertEqual(color.float(4), 1)
            XCTAssertNil(group.first(5), "no link to one Mac's preset groups")
        }
    }

    func testEveryCueIsInExactlyOneGroupInSlideOrder() throws {
        let document = try decode(song())
        let cueUUIDs = try document.messages(13).map { try XCTUnwrap($0.message(1)?.string(1)) }
        XCTAssertEqual(cueUUIDs.count, 1 + 1 + 1 + 1, "Blank plus one slide per section")
        let listed = try document.messages(12).flatMap { group in try group.messages(2).map { $0.string(1) ?? "" } }
        XCTAssertEqual(listed, cueUUIDs)
        XCTAssertEqual(Set(cueUUIDs).count, cueUUIDs.count)
    }

    func testTheArrangementFollowsThePastedOrderAfterBlank() throws {
        let document = try decode(song())
        let arrangements = try document.messages(11)
        XCTAssertEqual(arrangements.count, 1)
        let arrangement = try XCTUnwrap(arrangements.first)
        XCTAssertEqual(arrangement.string(2), "Default")
        let groupUUIDs = try document.messages(12).map { try XCTUnwrap($0.message(1)?.message(1)?.string(1)) }
        let arranged = try arrangement.messages(3).map { $0.string(1) ?? "" }
        // Blank, Verse 1, Chorus, Приспів, Chorus.
        XCTAssertEqual(arranged, [groupUUIDs[0], groupUUIDs[1], groupUUIDs[2], groupUUIDs[3], groupUUIDs[2]])
    }

    func testEachSlideIsOneCentredTextBoxFillingTheCanvas() throws {
        let document = try decode(song())
        for cue in try document.messages(13) {
            XCTAssertTrue(cue.bool(12), "enabled")
            let actions = try cue.messages(10)
            XCTAssertEqual(actions.map { $0.uint(9) }, [11], "one presentation-slide action, no media")
            let base = try XCTUnwrap(actions[0].message(23)?.message(2)?.message(1))
            let canvas = try XCTUnwrap(base.message(6))
            XCTAssertEqual(canvas.double(1), 1920)
            XCTAssertEqual(canvas.double(2), 1080)

            let elements = try base.messages(1)
            XCTAssertEqual(elements.count, 1)
            let graphics = try XCTUnwrap(elements[0].message(1))
            XCTAssertEqual(graphics.string(2), "Lyrics")
            let size = try XCTUnwrap(graphics.message(3)?.message(2))
            XCTAssertEqual(size.double(1), 1920)
            XCTAssertEqual(size.double(2), 1080)

            let text = try XCTUnwrap(graphics.message(13))
            XCTAssertEqual(text.uint(6), 1, "centred down the slide")
            let attributes = try XCTUnwrap(text.message(3))
            XCTAssertEqual(try attributes.message(6)?.uint(1), 2, "centred across the slide")
            let font = try XCTUnwrap(attributes.message(1))
            XCTAssertEqual(font.string(1), "Lato-Bold")
            XCTAssertEqual(font.double(2), 60)
        }
    }

    func testTheTextAttributesCoverTheWholeTextInUTF16() throws {
        let cues = try decode(song()).messages(13)
        // Cue 1 is Verse 1: two lines and the break between them.
        let attributes = try XCTUnwrap(try text(of: cues[1]).message(3))
        let ranges = try attributes.messages(13).map { try XCTUnwrap($0.message(1)?.uint(2)) }
        let expected = UInt64("Morning breaks across the hills\nEvery shadow runs away".utf16.count)
        XCTAssertEqual(ranges, [expected, expected])

        // The Blank slide has no text, so no attributes.
        XCTAssertEqual(try text(of: cues[0]).message(3)?.all(13).count, 0)
    }

    func testTheRTFHoldsTheLinesWithCyrillicEscaped() throws {
        let cues = try decode(song()).messages(13)
        let verse = try rtf(of: cues[1])
        XCTAssertTrue(verse.hasPrefix("{\\rtf1\\ansi"))
        XCTAssertTrue(verse.contains("\\qc"), "centred")
        XCTAssertTrue(verse.contains("Lato-Bold;"))
        XCTAssertTrue(verse.hasSuffix("Morning breaks across the hills\\\nEvery shadow runs away}"))

        let ukrainian = try rtf(of: cues[3])
        // "Співаю": С is U+0421 (1057), п U+043F (1087).
        XCTAssertTrue(ukrainian.contains("\\uc0\\u1057 \\uc0\\u1087 "))
        XCTAssertTrue(ukrainian.allSatisfy(\.isASCII), "RTF itself is ASCII")

        let blank = try rtf(of: cues[0])
        XCTAssertTrue(blank.contains("{\\fonttbl}"))
    }

    func testRTFEscapesItsOwnSyntax() {
        let rtf = String(decoding: LyricsDocument.rtf(lines: ["a{b}\\c"]), as: UTF8.self)
        XCTAssertTrue(rtf.hasSuffix("a\\{b\\}\\\\c}"))
    }

    func testCCLIInfoIsStoredButNotShown() throws {
        let ccli = try XCTUnwrap(try decode(song()).message(14))
        XCTAssertEqual(ccli.string(1), "Jane Doe", "the artist goes where ProPresenter keeps the author")
        XCTAssertEqual(ccli.string(3), "Morning Song")
        XCTAssertEqual(ccli.uint(6), 1_234_567)
        XCTAssertNil(ccli.first(7), "display is off")
    }

    func testASongWithoutDetailsStillHasItsTitle() throws {
        let ccli = try XCTUnwrap(try decode(song(artist: "", ccli: "")).message(14))
        XCTAssertNil(ccli.first(1))
        XCTAssertEqual(ccli.string(3), "Morning Song")
        XCTAssertNil(ccli.first(6))
    }

    func testIdentifiersAreUppercaseUUIDs() throws {
        let document = try decode(song())
        let pattern = try NSRegularExpression(pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
        var identifiers = [try XCTUnwrap(document.message(2)?.string(1))]
        identifiers += try document.messages(12).map { try XCTUnwrap($0.message(1)?.message(1)?.string(1)) }
        identifiers += try document.messages(13).map { try XCTUnwrap($0.message(1)?.string(1)) }
        for identifier in identifiers {
            XCTAssertNotNil(pattern.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)), identifier)
        }
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    // MARK: - The bundle

    func testTheBundleHoldsOnlyTheManifestStored() throws {
        let folder = try makeTemporaryDirectory()
        let saved = try LyricsPackage.write(song(), to: folder)
        XCTAssertEqual(saved.name, "Morning Song")
        XCTAssertFalse(saved.wasRenamed)
        XCTAssertEqual(saved.url.lastPathComponent, "Morning Song.probundle")

        let entries = try TestZipReader.entries(of: Data(contentsOf: saved.url))
        XCTAssertEqual(entries.map(\.name), ["Morning Song.pro"])
        XCTAssertEqual(entries.first?.method, 0, "stored")
        let document = try ProtoReader.fields(of: try XCTUnwrap(entries.first?.contents))
        XCTAssertEqual(document.string(3), "Morning Song")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path + ".partial"))

        exportBundle(saved.url)
    }

    func testTheBinCardDescribesTheSong() throws {
        let folder = try makeTemporaryDirectory()
        try LyricsPackage.write(song(), to: folder)
        let items = LyricsItem.scan(in: folder)
        XCTAssertEqual(items.count, 1, "the card file is hidden and not a song")
        XCTAssertEqual(items.first?.name, "Morning Song")
        XCTAssertEqual(items.first?.artist, "Jane Doe")
        XCTAssertEqual(items.first?.detail, "3 slides \u{00B7} V1 C C")
    }

    func testATakenTitleGetsTheArtistThenANumber() {
        XCTAssertEqual(LyricsPackage.uniqueName(title: "Song", artist: "Jane", taken: []), "Song")
        XCTAssertEqual(LyricsPackage.uniqueName(title: "Song", artist: "Jane", taken: ["song"]), "Song (Jane)")
        XCTAssertEqual(LyricsPackage.uniqueName(title: "Song", artist: "", taken: ["song"]), "Song (2)")
        XCTAssertEqual(LyricsPackage.uniqueName(title: "Song", artist: "Jane", taken: ["song", "song (jane)"]), "Song (2)")
        XCTAssertEqual(LyricsPackage.uniqueName(title: "Song", artist: "", taken: ["song", "song (2)"]), "Song (3)")
    }

    func testLookalikeLettersAndCaseCountAsTheSameTitle() {
        // The second word starts with a Latin C in one and a Cyrillic С in the other.
        XCTAssertEqual(LyricsPackage.foldedName("На Троні Cлави"), LyricsPackage.foldedName("на троні  Слави"))
        XCTAssertNotEqual(LyricsPackage.foldedName("Morning Song"), LyricsPackage.foldedName("Evening Song"))
    }

    func testASongAlreadyInTheLibraryOrTheBinIsRenamed() throws {
        let bin = try makeTemporaryDirectory()
        let library = try makeTemporaryDirectory()
        try Data().write(to: library.appendingPathComponent("Morning Song.pro"))

        let first = try LyricsPackage.write(song(), to: bin, takenNames: LyricsPackage.names(in: library))
        XCTAssertEqual(first.name, "Morning Song (Jane Doe)")
        XCTAssertTrue(first.wasRenamed)

        let second = try LyricsPackage.write(song(), to: bin, takenNames: LyricsPackage.names(in: library))
        XCTAssertEqual(second.name, "Morning Song (2)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path), "nothing is overwritten")
    }

    func testAnEmptyArtistNeverBecomesPartOfTheName() throws {
        let bin = try makeTemporaryDirectory()
        try LyricsPackage.write(song(artist: ""), to: bin)
        let second = try LyricsPackage.write(song(artist: ""), to: bin)
        XCTAssertEqual(second.name, "Morning Song (2)")
    }

    // MARK: - The bin

    func testTheQueueAddsRemovesAndClearsSongs() throws {
        let root = try makeTemporaryDirectory()
        let queue = ConversionQueue(
            options: ConversionOptions(),
            convert: { _, _, _, _ in throw CancellationError() },
            binRoot: root.appendingPathComponent("Bin", isDirectory: true),
            presentationsDirectory: root.appendingPathComponent("Pro", isDirectory: true),
            legacyBin: nil
        )
        XCTAssertEqual(queue.binLyricsURL.standardizedFileURL.path, root.appendingPathComponent("Lyrics").standardizedFileURL.path)

        let saved = try queue.addSong(song())
        XCTAssertEqual(queue.songs.map(\.name), ["Morning Song"])
        let item = try XCTUnwrap(queue.songs.first)
        XCTAssertEqual(queue.dragPayload(for: item)?.resolvingSymlinksInPath(), saved.url.resolvingSymlinksInPath())

        try queue.remove(song: item)
        XCTAssertTrue(queue.songs.isEmpty)
        XCTAssertNil(queue.dragPayload(for: item))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LyricsPackage.cardURL(for: saved.url).path))

        try queue.addSong(song())
        try queue.clearBin()
        XCTAssertTrue(queue.songs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.binLyricsURL.path))
    }

    func testSaveACopyCopiesTheBundle() throws {
        let root = try makeTemporaryDirectory()
        let queue = ConversionQueue(
            options: ConversionOptions(),
            convert: { _, _, _, _ in throw CancellationError() },
            binRoot: root.appendingPathComponent("Bin", isDirectory: true),
            presentationsDirectory: root.appendingPathComponent("Pro", isDirectory: true),
            legacyBin: nil
        )
        try queue.addSong(song())
        let destination = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try queue.save(song: try XCTUnwrap(queue.songs.first), to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Morning Song.probundle").path))
    }

    // MARK: - Helpers

    /// If FILE_CONVERTER_ARTIFACTS is set (CI), copy the bundle to
    /// `bundles/lyrics/` there, where CI checks it with Scripts/check-probundle.py
    /// and uploads it to be imported by hand.
    private func exportBundle(_ bundle: URL) {
        guard let target = ProcessInfo.processInfo.environment["FILE_CONVERTER_ARTIFACTS"] else { return }
        let folder = URL(fileURLWithPath: target, isDirectory: true)
            .appendingPathComponent("bundles/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(bundle.lastPathComponent)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.copyItem(at: bundle, to: out)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideLyricsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
