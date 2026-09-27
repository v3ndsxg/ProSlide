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

    // MARK: - Progress
    func testAggregateProgressMath() {
        typealias Fn = ConversionQueue.aggregateProgress
        XCTAssertEqual(Fn(offset: 0, fraction: 0, total: 3), 0, accuracy: 0.0001)
        XCTAssertEqual(Fn(offset: 0, fraction: 0.5, total: 3), 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(Fn(offset: 1, fraction: 0, total: 3), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(Fn(offset: 2, fraction: 1, total: 3), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Fn(offset: 0, fraction: 0.5, total: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Fn(offset: 0, fraction: 0, total: 0), 0, accuracy: 0.0001)
        // A misbehaving converter reporting out-of-range fractions must not
        // push progress outside 0...1.
        XCTAssertEqual(Fn(offset: 0, fraction: 5, total: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Fn(offset: 0, fraction: -3, total: 2), 0, accuracy: 0.0001)
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

        func run(_ url: URL, report: (Double) -> Void) async throws -> URL {
            lock.lock()
            recordedInputs.append(url.lastPathComponent)
            lock.unlock()

            for value in reports { report(value) }

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

    private func makeQueue(_ recorder: Recorder) -> ConversionQueue {
        ConversionQueue(options: ConversionOptions()) { url, _, _, progress in
            try await recorder.run(url, report: progress)
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
