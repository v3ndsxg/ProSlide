@testable import FileConverterCore
import XCTest

/// Downloads sit in the bin beside the converted decks. Everything here works on
/// temporary folders: Clear deletes what the queue has scanned, so a queue that
/// found the real `~/Documents/ProSlide Beta/Downloads` would delete real files.
@MainActor
final class DownloadsBinTests: XCTestCase {

    // MARK: - Scanning

    func testScanFindsVideoAndAudioNewestFirst() throws {
        let folder = try makeTemporaryDirectory()
        let older = try makeFile("Older Song.mp3", in: folder, bytes: 10, modified: Date(timeIntervalSince1970: 1_000))
        let newer = try makeFile("Newer Video.mp4", in: folder, bytes: 20, modified: Date(timeIntervalSince1970: 2_000))

        let items = MediaItem.scan(in: folder)

        XCTAssertEqual(items.map(\.title), ["Newer Video", "Older Song"])
        XCTAssertEqual(items.map(\.kind), [.video, .audio])
        XCTAssertEqual(items.map(\.byteCount), [20, 10])
        XCTAssertEqual(items.map(\.fileURL.lastPathComponent), [newer.lastPathComponent, older.lastPathComponent])
        XCTAssertTrue(items[0].detail.hasPrefix("MP4"))
        XCTAssertTrue(items[1].detail.hasPrefix("MP3"))
    }

    func testScanIgnoresOtherFilesHiddenFilesAndFolders() throws {
        let folder = try makeTemporaryDirectory()
        _ = try makeFile("Keep.mp4", in: folder, bytes: 1)
        _ = try makeFile("notes.txt", in: folder, bytes: 1)
        _ = try makeFile("Half.mp4.part", in: folder, bytes: 1)
        _ = try makeFile(".hidden.mp4", in: folder, bytes: 1)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(MediaItem.thumbnailsFolderName),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(MediaItem.scan(in: folder).map(\.title), ["Keep"])
    }

    func testScanOfAMissingFolderIsEmpty() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-downloads-\(UUID().uuidString)")
        XCTAssertEqual(MediaItem.scan(in: missing), [])
    }

    func testScanPairsAThumbnailWhenOneExists() throws {
        let folder = try makeTemporaryDirectory()
        let video = try makeFile("With Art.mp4", in: folder, bytes: 1)
        _ = try makeFile("No Art.mp4", in: folder, bytes: 1)
        let thumbnail = MediaItem.thumbnailURL(for: video)
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF]).write(to: thumbnail)

        let byTitle = Dictionary(uniqueKeysWithValues: MediaItem.scan(in: folder).map { ($0.title, $0) })
        XCTAssertEqual(byTitle["With Art"]?.thumbnailURL?.resolvingSymlinksInPath(), thumbnail.resolvingSymlinksInPath())
        XCTAssertNil(byTitle["No Art"]?.thumbnailURL)
    }

    // MARK: - The queue

    func testDownloadsFolderSitsBesideTheBin() throws {
        let root = try makeTemporaryDirectory()
        let queue = makeQueue(root: root)
        XCTAssertEqual(queue.binDownloadsURL.lastPathComponent, "Downloads")
        XCTAssertEqual(
            queue.binDownloadsURL.deletingLastPathComponent().standardizedFileURL,
            root.standardizedFileURL
        )
    }

    func testReloadPublishesDownloads() async throws {
        let root = try makeTemporaryDirectory()
        let queue = makeQueue(root: root)
        try FileManager.default.createDirectory(at: queue.binDownloadsURL, withIntermediateDirectories: true)
        _ = try makeFile("Welcome Loop.mp4", in: queue.binDownloadsURL, bytes: 5)

        queue.reloadBin()
        for _ in 0..<100 where queue.downloads.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(queue.downloads.map(\.title), ["Welcome Loop"])
    }

    func testDragPayloadIsTheFileItselfRegardlessOfDragMode() throws {
        let root = try makeTemporaryDirectory()
        let queue = makeQueue(root: root)
        let file = try makeFile("Clip.mp4", in: root, bytes: 3)
        let item = try XCTUnwrap(MediaItem.scan(in: root).first)

        for mode in DragMode.allCases {
            queue.dragMode = mode
            XCTAssertEqual(queue.dragPayload(for: item)?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        }

        try FileManager.default.removeItem(at: file)
        XCTAssertNil(queue.dragPayload(for: item), "a deleted file has nothing to drag")
    }

    func testRemoveDeletesTheFileAndItsThumbnail() throws {
        let root = try makeTemporaryDirectory()
        let queue = makeQueue(root: root)
        let file = try makeFile("Clip.mp4", in: root, bytes: 3)
        let thumbnail = MediaItem.thumbnailURL(for: file)
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF]).write(to: thumbnail)
        let item = try XCTUnwrap(MediaItem.scan(in: root).first)

        try queue.remove(download: item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
    }

    func testSaveCopiesTheFileAndNeverDeletesItWhenSavedInPlace() throws {
        let root = try makeTemporaryDirectory()
        let queue = makeQueue(root: root)
        let file = try makeFile("Clip.mp4", in: root, bytes: 3)
        let item = try XCTUnwrap(MediaItem.scan(in: root).first)
        let elsewhere = try makeTemporaryDirectory()

        try queue.save(download: item, to: elsewhere)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Clip.mp4").path))

        try queue.save(download: item, to: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "saving into its own folder must not delete it")
    }

    func testClearBinDeletesDownloads() throws {
        let root = try makeTemporaryDirectory()
        let queue = makeQueue(root: root)
        try FileManager.default.createDirectory(at: queue.binDownloadsURL, withIntermediateDirectories: true)
        let file = try makeFile("Clip.mp4", in: queue.binDownloadsURL, bytes: 3)

        try queue.clearBin()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.binDownloadsURL.path))
    }

    // MARK: - Helpers

    // NSTemporaryDirectory() is /var/... but a directory listing comes back as
    // /private/var/..., so URLs for the same file are compared with symlinks
    // resolved.

    private func makeQueue(root: URL) -> ConversionQueue {
        ConversionQueue(
            options: ConversionOptions(),
            convert: { _, _, _, _ in throw CancellationError() },
            binRoot: root.appendingPathComponent("Bin", isDirectory: true),
            presentationsDirectory: root.appendingPathComponent("Pro", isDirectory: true),
            legacyBin: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideDownloadsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func makeFile(_ name: String, in folder: URL, bytes: Int, modified: Date? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }
}
