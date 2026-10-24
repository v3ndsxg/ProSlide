@testable import FileConverterCore
import XCTest

/// The batch behaviour lives in FileConverterCore precisely so it can be
/// asserted here: no window, no LibreOffice, no app target. Every test drives
/// the queue through an injected converter.
@MainActor
final class ConversionQueueTests: XCTestCase {

    // MARK: - Ordering and isolation

    func testBatchConvertsEveryFileInNameOrder() async throws {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        queue.accept(["c.pdf", "a.pdf", "b.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.inputs, ["a.pdf", "b.pdf", "c.pdf"],
                       "batch must run in sorted name order, not drop order")
        for item in queue.items {
            guard case .succeeded = item.status else {
                return XCTFail("\(item.fileName) should have succeeded, got \(item.status)")
            }
        }
    }

    func testOneFailingFileDoesNotStopTheRest() async throws {
        let recorder = Recorder(failingNames: ["b.pdf"])
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf", "b.pdf", "c.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.inputs, ["a.pdf", "b.pdf", "c.pdf"],
                       "every file must be attempted even though one fails")
        let statuses = Dictionary(uniqueKeysWithValues: queue.items.map { ($0.fileName, $0.status) })
        guard case .succeeded = statuses["a.pdf"] else { return XCTFail("a.pdf should succeed") }
        guard case .succeeded = statuses["c.pdf"] else {
            return XCTFail("c.pdf must still run after b.pdf fails")
        }
        guard case .failed(let reason) = statuses["b.pdf"] else {
            return XCTFail("b.pdf should carry the failure")
        }
        XCTAssertEqual(reason, Recorder.failureMessage)
    }

    func testSecondRunRequeuesAFailedFile() async throws {
        let recorder = Recorder(failingNames: ["a.pdf"])
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)
        guard case .failed = queue.items[0].status else {
            return XCTFail("expected the first run to fail")
        }

        recorder.failingNames = []
        queue.convert()
        await waitUntilIdle(queue)
        guard case .succeeded = queue.items[0].status else {
            return XCTFail("a second run should re-queue the failure and succeed")
        }
    }

    func testReDroppingAFileAfterACompletedRunConvertsItAgain() async throws {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)
        guard case .succeeded = queue.items[0].status else {
            return XCTFail("the first run should succeed")
        }

        // Dropping the same file again re-queues it, and it has to claim its
        // scope again because the first run released it.
        queue.accept(["a.pdf"].map(fileURL))
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items[0].status, .pending)

        queue.convert()
        await waitUntilIdle(queue)
        XCTAssertEqual(recorder.inputs, ["a.pdf", "a.pdf"])
        XCTAssertEqual(queue.scopesStarted, queue.scopesStopped)
    }

    /// Adding a file to a finished batch converts only the new one. Re-running the
    /// old ones would pile `… JPEGs 2` duplicates into the bin, and rebuild their
    /// presentations.
    func testAddingAFileToAFinishedBatchConvertsOnlyTheNewOne() async throws {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf", "b.pdf"].map(fileURL))
        queue.convert()
        await waitUntilIdle(queue)
        XCTAssertEqual(queue.pendingCount, 0)

        queue.accept(["c.pdf"].map(fileURL))
        XCTAssertEqual(queue.pendingCount, 1)
        queue.convert()
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.inputs, ["a.pdf", "b.pdf", "c.pdf"],
                       "a and b were already done and must not run again")
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testConvertWithEverythingAlreadyDoneDoesNothing() async throws {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf"].map(fileURL))
        queue.convert()
        await waitUntilIdle(queue)

        queue.convert()
        XCTAssertFalse(queue.isConverting, "nothing is pending, so no run starts")
        XCTAssertEqual(recorder.inputs, ["a.pdf"])
    }

    /// Clear resets the app, not only the bin: the files queued on the main page
    /// go too, so new content can be brought in from scratch.
    func testClearBinAlsoEmptiesTheFileListOnTheMainPage() async throws {
        let queue = makeQueue(Recorder())
        queue.accept(["a.pdf", "b.pdf"].map(fileURL))
        queue.convert()
        await waitUntilIdle(queue)
        queue.message = "a leftover notice"
        XCTAssertEqual(queue.items.count, 2)

        let presentations = queue.binPresentationsURL
        try queue.clearBin()

        XCTAssertTrue(queue.items.isEmpty, "the queued files are cleared along with the bin")
        XCTAssertNil(queue.message)
        XCTAssertEqual(queue.progress, 0)
        XCTAssertEqual(queue.scopesStarted, queue.scopesStopped)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: presentations.path),
            "and the presentations folder it was told to empty"
        )
    }

    // MARK: - Bundles

    /// The bundle is written as part of the same run that renders the JPEGs,
    /// so a deck is ready to drag the moment it reaches the bin — dragging only
    /// ever hands over a file that already exists.
    func testConversionWritesEachDecksBundleInTheSameRun() async throws {
        let packaged = Packaged()
        let queue = makeQueue(Recorder(), packaged: packaged)
        queue.accept(["b.pdf", "a.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)

        XCTAssertEqual(packaged.names, ["a", "b"], "one bundle per converted deck, in batch order")
        for name in ["a", "b"] {
            let group = ConversionGroup(sourceName: name, folderURL: fileURL(name))
            XCTAssertEqual(queue.presentation(for: group), URL(fileURLWithPath: "/tmp/\(name).probundle"))
            XCTAssertEqual(queue.deckStatus(for: group), .ready)
        }
    }

    /// A bundle that cannot be written is reported on the deck's card, but the
    /// conversion itself succeeded: the JPEGs are there and still drag.
    func testABundleFailureDoesNotFailTheConversion() async throws {
        let queue = makeQueue(Recorder(), failingPackages: ["a"])
        queue.accept([fileURL("a.pdf")])

        queue.convert()
        await waitUntilIdle(queue)

        XCTAssertTrue(try XCTUnwrap(queue.items.first).status.isSucceeded)
        let group = ConversionGroup(sourceName: "a", folderURL: fileURL("a"))
        XCTAssertEqual(queue.deckStatus(for: group), .failed(ProPackageError.tooLarge.errorDescription!))
        queue.dragMode = .jpegFolder
        XCTAssertEqual(queue.deckStatus(for: group), .ready)
    }

    /// A deck that failed is rebuilt from its card, and a rebuild that works
    /// clears the failure.
    func testRebuildWritesTheBundleAndClearsAnEarlierFailure() async throws {
        let packaged = Packaged()
        let queue = makeQueue(Recorder(), packaged: packaged)
        let group = ConversionGroup(sourceName: "Deck JPEGs", folderURL: URL(fileURLWithPath: "/tmp/none"))
        queue.recordPresentationFailure("boom", for: group)

        queue.buildPresentation(group)
        XCTAssertEqual(queue.deckStatus(for: group), .preparing)
        let deadline = Date().addingTimeInterval(5)
        while queue.presentation(for: group) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(packaged.names, ["Deck"])
        XCTAssertEqual(queue.deckStatus(for: group), .ready)
        XCTAssertNil(queue.presentationFailures[group.id])
    }

    /// Clear removes the decks in the queue's own bin and nothing else. It is
    /// pointed at a temporary bin here, which is the point: the version of this
    /// suite that scanned the real one deleted real decks.
    func testClearRemovesOnlyTheDecksInItsOwnBin() async throws {
        let queue = makeQueue(Recorder())
        let deck = queue.binRootURL.appendingPathComponent("Deck JPEGs", isDirectory: true)
        try FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: deck.appendingPathComponent("Deck-001.jpg"))
        let elsewhere = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("Other-001.jpg"))

        queue.reloadBin()
        let deadline = Date().addingTimeInterval(5)
        while queue.groups.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(queue.groups.map(\.folderURL.lastPathComponent), ["Deck JPEGs"])

        try queue.clearBin()
        XCTAssertFalse(FileManager.default.fileExists(atPath: deck.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Other-001.jpg").path))
    }

    /// Two conversions of one document share a bundle. Whichever was built last
    /// owns it, and the other goes back to not built rather than dragging
    /// slides it did not make.
    func testBuildingOneConversionUnclaimsTheOthersSharedBundle() async throws {
        let queue = makeQueue(Recorder())
        let first = ConversionGroup(sourceName: "Deck JPEGs", folderURL: URL(fileURLWithPath: "/tmp/Deck JPEGs"))
        let second = ConversionGroup(sourceName: "Deck JPEGs 2", folderURL: URL(fileURLWithPath: "/tmp/Deck JPEGs 2"))

        for group in [first, second] {
            queue.buildPresentation(group)
            let deadline = Date().addingTimeInterval(5)
            while queue.presentation(for: group) == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        XCTAssertEqual(queue.presentation(for: second), URL(fileURLWithPath: "/tmp/Deck.probundle"))
        XCTAssertNil(queue.presentation(for: first))
        XCTAssertEqual(queue.deckStatus(for: first), .missing)
    }

    // MARK: - Deck status

    func testDragModesAreLabelledInTitleCase() {
        XCTAssertEqual(DragMode.presentation.title, "ProPresenter Presentation")
        XCTAssertEqual(DragMode.jpegFolder.title, "JPEG Files")
    }

    func testDeckStatusFollowsThePresentationInPresentationMode() throws {
        let queue = makeQueue(Recorder())
        let group = ConversionGroup(sourceName: "Deck JPEGs", folderURL: URL(fileURLWithPath: "/tmp/none"))
        queue.dragMode = .presentation

        XCTAssertEqual(queue.deckStatus(for: group), .missing, "nothing written and nothing failed yet")
        XCTAssertEqual(queue.deckStatus(for: group).title, "Not built")

        queue.recordPresentationFailure("The folder is missing.", for: group)
        XCTAssertEqual(queue.deckStatus(for: group), .failed("The folder is missing."))
        XCTAssertEqual(queue.deckStatus(for: group).title, "Couldn\u{2019}t prepare")
    }

    /// In JPEG Files mode the images are the whole payload, so a deck whose
    /// presentation failed is still ready to drag.
    func testDeckStatusIsReadyInJPEGFilesModeEvenAfterAPresentationFailure() {
        let queue = makeQueue(Recorder())
        let group = ConversionGroup(sourceName: "Deck JPEGs", folderURL: URL(fileURLWithPath: "/tmp/none"))
        queue.recordPresentationFailure("boom", for: group)

        queue.dragMode = .jpegFolder
        XCTAssertEqual(queue.deckStatus(for: group), .ready)
        XCTAssertEqual(queue.deckStatus(for: group).title, "Ready")
    }

    // MARK: - Progress
    func testAggregateProgressMath() {
        // Each call names the method outright rather than binding it to a local
        // first: Swift erases argument labels when a function is referenced as a
        // value, so `let progress = ConversionQueue.aggregateProgress` yields a
        // bare `(Int, Double, Int) -> Double` and `progress(offset:...)` will not
        // compile. A typealias loses them the same way.
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 0, fraction: 0, total: 3),
            0, accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 0, fraction: 0.5, total: 3),
            1.0 / 6.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 1, fraction: 0, total: 3),
            1.0 / 3.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 2, fraction: 1, total: 3),
            1.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 0, fraction: 0.5, total: 1),
            0.5, accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 0, fraction: 0, total: 0),
            0, accuracy: 0.0001
        )
        // A misbehaving converter reporting out-of-range fractions must not
        // push progress outside 0...1.
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 0, fraction: 5, total: 2),
            0.5, accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversionQueue.aggregateProgress(offset: 0, fraction: -3, total: 2),
            0, accuracy: 0.0001
        )
    }

    func testProgressFinishesAtOneAndConverterProgressIsForwarded() async throws {
        let recorder = Recorder(reports: [0.25, 0.75])
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf", "b.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.reported, [0.25, 0.75, 0.25, 0.75],
                       "each file's progress must be handed to the queue")
        XCTAssertEqual(queue.progress, 1.0, accuracy: 0.0001)
    }

    // MARK: - Drag modes

    /// The bin offers both a JPEG-folder drag and a bundle drag. The bundle is
    /// the default because it is the reason the deck is packaged at all, but the
    /// folder has to stay reachable — it is what you want when pulling slides
    /// into a presentation you already have.
    ///
    /// Presentation mode has no fallback: a deck with no presentation drags
    /// nothing at all, rather than quietly handing over its JPEG folder. The
    /// fallback is what made a failed presentation look like a working drag.
    func testDragModeDefaultsToThePresentationAndCanSwitchToTheFolder() {
        let queue = ConversionQueue()
        XCTAssertEqual(queue.dragMode, .presentation)

        let group = ConversionGroup(
            sourceName: "Deck JPEGs",
            folderURL: URL(fileURLWithPath: "/tmp/Deck JPEGs", isDirectory: true)
        )

        // Nothing written yet, so presentation mode has nothing to offer.
        XCTAssertNil(queue.dragPayload(for: group))

        queue.dragMode = .jpegFolder
        XCTAssertEqual(queue.dragPayload(for: group), group.folderURL)

        queue.dragMode = .presentation
        XCTAssertNil(queue.dragPayload(for: group))
    }

    /// A deck whose presentation failed to write must not drag as a JPEG folder
    /// either. The two payloads behave differently in ProPresenter, and swapping
    /// one for the other without saying so is what made this so hard to see.
    func testAFailedPresentationNeverDragsTheJPEGFolderInstead() throws {
        let queue = ConversionQueue()
        XCTAssertEqual(queue.dragMode, .presentation)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSlideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("Deck-001.jpg"))

        let group = ConversionGroup(sourceName: "Deck JPEGs", folderURL: folder)
        queue.recordPresentationFailure("The presentation could not be written.", for: group)

        XCTAssertNil(
            queue.dragPayload(for: group),
            "a failed presentation must not quietly become a JPEG-folder drag"
        )
        XCTAssertNotNil(queue.presentationFailures[group.id], "and the reason is kept for the bin to report")
    }

    /// Decks converted before the bin moved out of Application Support must come
    /// across rather than be abandoned — they were unreadable where they sat.
    func testDecksAreBroughtAcrossFromTheOldBinLocation() throws {
        let legacy = try makeScratchFolder("legacy")
        let destination = try makeScratchFolder("new")
        let deck = legacy.appendingPathComponent("Faith JPEGs", isDirectory: true)
        try FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true)
        try Data("slide".utf8).write(to: deck.appendingPathComponent("Faith-001.jpg"))

        // Something that is not a deck must be left where it is.
        let notes = legacy.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        BinStorage.migrateDecks(from: legacy, to: destination)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Faith JPEGs"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: deck.path), "the deck moves, it is not copied"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: notes.path),
            "a folder holding no images is not a deck and stays put"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Faith JPEGs/Faith-001.jpg")),
            Data("slide".utf8), "and the images arrive intact"
        )
    }

    /// A deck already at the destination must survive migration untouched.
    ///
    /// Arranged by putting a deck in both places at once, which is what a
    /// re-conversion after a partial migration leaves behind. Simply migrating
    /// twice would prove nothing: the first pass moves the deck away, so the
    /// second finds nothing to do and never meets the collision.
    func testMigrationNeverOverwritesADeckAlreadyAtTheDestination() throws {
        let legacy = try makeScratchFolder("legacy")
        let destination = try makeScratchFolder("new")

        let fresh = destination.appendingPathComponent("Faith JPEGs", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: fresh.appendingPathComponent("Faith-001.jpg"))

        let stale = legacy.appendingPathComponent("Faith JPEGs", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale.appendingPathComponent("Faith-001.jpg"))

        BinStorage.migrateDecks(from: legacy, to: destination)

        XCTAssertEqual(
            try Data(contentsOf: fresh.appendingPathComponent("Faith-001.jpg")), Data("new".utf8),
            "the deck already at the destination is left exactly as it is"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stale.path),
            "and the stale original is left where it is rather than clobbering anything"
        )
    }

    /// The bin must not live in Application Support. ProPresenter is handed these
    /// paths and reads them itself; another app's container is not readable
    /// without a permission the drag never grants, and every slide arrived in
    /// ProPresenter empty.
    func testTheBinIsWhereProPresenterCanReadIt() {
        let path = BinStorage.rootURL.path
        XCTAssertTrue(
            path.contains("/Documents/"), "the bin is in Documents, got \(path)"
        )
        XCTAssertFalse(
            path.contains("Application Support"), "and nowhere near a container, got \(path)"
        )
    }

    /// A throwaway folder that removes itself.
    ///
    /// Named rather than reused so a test that forgets to clean up leaves an
    /// obvious directory behind instead of quietly polluting the next run.
    private func makeScratchFolder(_ label: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSlideTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: - Cancellation

    func testCancelStopsTheBatchAndLeavesNothingCommitted() async throws {
        let gate = Gate()
        let recorder = Recorder(gate: gate)
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf", "b.pdf", "c.pdf"].map(fileURL))

        queue.convert()
        let started = await gate.waitUntilEntered()
        XCTAssertTrue(started, "the first conversion never reached the gate")
        queue.cancel()
        gate.open()
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.inputs, ["a.pdf"], "no file may start after cancel")
        for item in queue.items {
            guard case .pending = item.status else {
                return XCTFail("\(item.fileName) should be pending after cancel, got \(item.status)")
            }
        }
    }

    // MARK: - Input handling

    func testUnsupportedFilesAreReportedWithoutPoisoningTheBatch() throws {
        let queue = makeQueue(Recorder())
        queue.accept([fileURL("a.pdf"), fileURL("virus.exe"), fileURL("b.pdf")])

        XCTAssertEqual(queue.items.map(\.fileName), ["a.pdf", "b.pdf"])
        XCTAssertEqual(try XCTUnwrap(queue.message), "Skipped 1 unsupported file: virus.exe")
    }

    /// Old binary `.ppt` decks are accepted alongside `.pptx`; LibreOffice
    /// converts both.
    func testLegacyPowerPointFilesAreAccepted() throws {
        let queue = makeQueue(Recorder())
        queue.accept(["a.ppt", "b.PPTX", "c.pdf", "d.key"].map(fileURL))
        XCTAssertEqual(queue.items.map(\.fileName), ["a.ppt", "b.PPTX", "c.pdf"])
        XCTAssertEqual(queue.message, "Skipped 1 unsupported file: d.key")
    }

    func testSeveralUnsupportedFilesAreReportedTogether() throws {
        let queue = makeQueue(Recorder())
        queue.accept([fileURL("virus.exe"), fileURL("notes.txt")])
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(queue.message),
            "Skipped 2 unsupported files: notes.txt, virus.exe",
            "unsupported names should be sorted with the accepted files"
        )
    }

    func testAcceptingTheSameFileTwiceRequeuesInsteadOfDuplicating() {
        let queue = makeQueue(Recorder())
        queue.accept([fileURL("a.pdf")])
        queue.accept([fileURL("a.pdf")])
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items[0].status, .pending)
    }

    func testRemoveAllClearsItemsAndMessage() {
        let queue = makeQueue(Recorder())
        queue.accept(["a.pdf", "b.pdf"].map(fileURL))
        queue.removeAll()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertNil(queue.message)
    }

    func testConvertOnAnEmptyQueueDoesNothing() async {
        let queue = makeQueue(Recorder())
        queue.convert()
        await Task.yield()
        XCTAssertFalse(queue.isConverting)
    }

    // MARK: - Security scopes

    func testSecurityScopesStayBalancedIncludingAfterAFailure() async throws {
        let recorder = Recorder(failingNames: ["a.pdf"])
        let queue = makeQueue(recorder)
        queue.accept(["a.pdf", "b.pdf", "c.pdf"].map(fileURL))

        queue.convert()
        await waitUntilIdle(queue)

        // These are plain temp URLs, so no scope is actually taken; the counts
        // are what proves the bookkeeping is balanced rather than double-freeing.
        XCTAssertEqual(queue.scopesStarted, queue.scopesStopped,
                       "every scope taken must be released exactly once")
    }

    // MARK: - Bin scanning

    func testScanBinFindsOnlyFoldersHoldingJPEGs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let withImages = root.appendingPathComponent("Deck JPEGs", isDirectory: true)
        let empty = root.appendingPathComponent("Empty Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: withImages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data([0x01]).write(to: withImages.appendingPathComponent("Deck-001.jpg"))
        try Data([0x02]).write(to: root.appendingPathComponent("loose.pdf"))

        let groups = ConversionQueue.scanBin(at: root)
        XCTAssertEqual(groups.map(\.sourceName), ["Deck JPEGs"])
        XCTAssertEqual(groups.first?.imageURLs.count, 1)
    }

    func testScanBinOnAMissingDirectoryIsEmptyRatherThanThrowing() {
        let groups = ConversionQueue.scanBin(
            at: URL(fileURLWithPath: "/tmp/proslide-absent-\(UUID().uuidString)")
        )
        XCTAssertTrue(groups.isEmpty)
    }

    func testScanBinOrdersNewestFolderFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["A JPEGs", "B JPEGs", "C JPEGs"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0x01]).write(to: folder.appendingPathComponent("\(name)-001.jpg"))
        }

        XCTAssertEqual(ConversionQueue.scanBin(at: root).map(\.sourceName),
                       ["C JPEGs", "B JPEGs", "A JPEGs"])
    }

    // MARK: - Helpers

    /// Stands in for the real engine: records what it was asked to convert and
    /// can be told to fail for specific documents.
    private final class Recorder: @unchecked Sendable {
        static let failureMessage = "this document is broken"

        private let lock = NSLock()
        private var recordedInputs: [String] = []
        private var recordedProgress: [Double] = []
        private let gate: Gate?
        private let reports: [Double]

        var failingNames: Set<String>

        init(failingNames: Set<String> = [], gate: Gate? = nil, reports: [Double] = [0.25, 0.75]) {
            self.failingNames = failingNames
            self.gate = gate
            self.reports = reports
        }

        var inputs: [String] {
            lock.lock(); defer { lock.unlock() }
            return recordedInputs
        }

        var reported: [Double] {
            lock.lock(); defer { lock.unlock() }
            return recordedProgress
        }

        /// Appends to `recordedProgress`. Deliberately not `async`: taking an
        /// `NSLock` straight from an async function is what produces the
        /// "unavailable from asynchronous contexts" warnings these helpers
        /// otherwise attract, so the locking lives here instead.
        private func recordProgress(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            recordedProgress.append(value)
        }

        func run(_ url: URL, report: (Double) -> Void) async throws -> URL {
            lock.lock()
            recordedInputs.append(url.lastPathComponent)
            lock.unlock()

            for value in reports { recordProgress(value); report(value) }

            if let gate {
                await gate.enterAndWait()
                // Mirror a converter that notices cancellation mid-file.
                if Task.isCancelled { throw CancellationError() }
            }

            if failingNames.contains(url.lastPathComponent) {
                throw RecorderError.broken
            }
            return url.deletingPathExtension()
        }
    }

    private enum RecorderError: LocalizedError {
        case broken
        var errorDescription: String? { Recorder.failureMessage }
    }

    /// Lets a test hold the converter in flight at a known point. The entry
    /// wait is polled rather than continued so a regression shows up as a
    /// failed assertion instead of a hung test run.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func waitUntilEntered(timeout: TimeInterval = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !hasEntered {
                guard Date() < deadline else { return false }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return true
        }

        private var hasEntered: Bool {
            lock.lock(); defer { lock.unlock() }
            return entered
        }

        func enterAndWait() async {
            lock.lock()
            entered = true
            let alreadyOpen = isOpen
            lock.unlock()
            if alreadyOpen { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let toResume = waiting
            waiting.removeAll()
            lock.unlock()
            toResume.forEach { $0.resume() }
        }
    }

    /// A queue around the fake converter. Packaging is faked too, so no test
    /// writes into the real bin: it records which decks were packaged, and
    /// fails for any deck named in `failingPackages`.
    private func makeQueue(
        _ recorder: Recorder,
        packaged: Packaged = Packaged(),
        failingPackages: Set<String> = []
    ) -> ConversionQueue {
        // Never the real bin: Clear deletes every deck the queue has scanned,
        // and a queue pointed at `~/Documents/ProSlide/Bin` once deleted the
        // operator's decks from a test run.
        let bin = (try? makeTemporaryDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        addTeardownBlock { try? FileManager.default.removeItem(at: bin) }
        return ConversionQueue(
            options: ConversionOptions(),
            convert: { url, _, _, progress in try await recorder.run(url, report: progress) },
            package: { group in
                packaged.append(group.displayName)
                if failingPackages.contains(group.displayName) { throw ProPackageError.tooLarge }
                return URL(fileURLWithPath: "/tmp/\(group.documentName).probundle")
            },
            binRoot: bin.appendingPathComponent("Bin", isDirectory: true),
            presentationsDirectory: bin.appendingPathComponent("Pro", isDirectory: true),
            legacyBin: nil
        )
    }

    private final class Packaged: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        var names: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func append(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(name)
        }
    }

    private func fileURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideQueueTests", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The queue finishes in a detached task, so tests wait for the published
    /// flag to settle rather than sleeping a fixed amount.
    private func waitUntilIdle(_ queue: ConversionQueue, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while queue.isConverting && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(queue.isConverting, "the queue never finished")
    }
}
