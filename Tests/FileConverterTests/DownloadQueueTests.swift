@testable import FileConverterCore
import XCTest

/// The Downloader tab's state, driven through injected lookups and downloads so
/// nothing here touches the network or the packaged tools.
@MainActor
final class DownloadQueueTests: XCTestCase {

    private let tools = DownloadTools(
        ytDlp: URL(fileURLWithPath: "/a"), ffmpeg: URL(fileURLWithPath: "/b"), deno: URL(fileURLWithPath: "/c")
    )

    // MARK: - Settings

    func testFormatAndQualityAreRemembered() throws {
        let defaults = try makeDefaults()
        let first = makeQueue(defaults: defaults)
        XCTAssertEqual(first.format, .mp4)
        XCTAssertEqual(first.quality, .p1080, "1080p is the default")

        first.format = .mp3
        first.quality = .p2160

        let second = makeQueue(defaults: defaults)
        XCTAssertEqual(second.format, .mp3)
        XCTAssertEqual(second.quality, .p2160)
    }

    // MARK: - Looking links up

    func testPastedLinksAreLookedUpAndQualitiesGreyedOutAccordingly() async throws {
        let queue = makeQueue(lookUp: { url in
            VideoInfo(title: url.lastPathComponent, duration: 60, maxHeight: url.lastPathComponent == "uhd" ? 2160 : 1080, isLive: false)
        })

        queue.linkText = "https://example.com/hd"
        try await waitUntil { queue.pastedInfos.count == 1 }
        XCTAssertFalse(queue.isOffered(.p2160))
        XCTAssertTrue(queue.isOffered(.p1080))

        queue.linkText += "\nhttps://example.com/uhd"
        try await waitUntil { queue.pastedInfos.count == 2 }
        XCTAssertTrue(queue.isOffered(.p2160), "one link with 4K is enough")
    }

    func testALinkIsLookedUpOnceAndOneThatFailsSaysWhy() async throws {
        let calls = Counter()
        let queue = makeQueue(lookUp: { url in
            calls.increment()
            if url.lastPathComponent == "private" { throw DownloadError.privateVideo }
            return VideoInfo(title: "ok", duration: nil, maxHeight: nil, isLive: false)
        })

        queue.linkText = "https://example.com/ok https://example.com/private"
        try await waitUntil { queue.lookups.count == 2 && !queue.lookups.values.contains(.looking) }
        queue.linkText += " https://example.com/ok"
        queue.linkText += "\n"

        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(queue.lookups["https://example.com/private"], .failed(DownloadError.privateVideo.localizedDescription))
    }

    func testUnsupportedLinksAreNeverLookedUp() async throws {
        let calls = Counter()
        let queue = makeQueue(lookUp: { _ in
            calls.increment()
            return VideoInfo(title: "x", duration: nil, maxHeight: nil, isLive: false)
        })

        queue.linkText = "https://www.youtube.com/playlist?list=PL1 not-a-link"
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(queue.downloadableLinks.isEmpty)
    }

    // MARK: - Downloading

    func testLinksDownloadOneAtATimeAndTheBinIsToldEachTime() async throws {
        let order = Recorder()
        let queue = makeQueue(fetch: { url, info, format, quality, _, progress in
            order.add("start \(url.lastPathComponent)")
            progress(.downloading(0.5))
            order.add("end \(url.lastPathComponent) \(format.rawValue) \(quality.rawValue) \(info.title)")
            return URL(fileURLWithPath: "/Downloads/\(url.lastPathComponent).mp4")
        })
        var binChanges = 0
        queue.onBinChanged = { binChanges += 1 }
        queue.format = .mp4
        queue.quality = .p720

        queue.linkText = "https://example.com/one\nhttps://example.com/two\nnot a link"
        queue.download()
        XCTAssertTrue(queue.isDownloading)
        XCTAssertEqual(queue.linkText, "", "the box is emptied once its links are queued")
        try await waitUntil { !queue.isDownloading }

        XCTAssertEqual(order.lines, [
            "start one", "end one mp4 720 one",
            "start two", "end two mp4 720 two",
        ])
        XCTAssertEqual(queue.items.count, 2, "the unsupported text was not queued")
        XCTAssertTrue(queue.items.allSatisfy { if case .done = $0.status { true } else { false } })
        XCTAssertEqual(binChanges, 2)
        XCTAssertTrue(queue.activeItems.isEmpty)
    }

    func testAFailureIsRecordedAndTheRestCarryOn() async throws {
        let queue = makeQueue(fetch: { url, _, _, _, _, _ in
            if url.lastPathComponent == "bad" { throw DownloadError.loginRequired }
            return URL(fileURLWithPath: "/Downloads/ok.mp4")
        })

        queue.linkText = "https://example.com/bad https://example.com/good"
        queue.download()
        try await waitUntil { !queue.isDownloading }

        XCTAssertEqual(queue.items.map(\.status), [
            .failed(DownloadError.loginRequired.localizedDescription),
            .done(URL(fileURLWithPath: "/Downloads/ok.mp4")),
        ])
    }

    func testStopEndsTheRunAndDropsWhatWasWaiting() async throws {
        let started = Counter()
        let queue = makeQueue(fetch: { _, _, _, _, _, _ in
            started.increment()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return URL(fileURLWithPath: "/never")
        })

        queue.linkText = "https://example.com/one https://example.com/two"
        queue.download()
        try await waitUntil { started.value == 1 }
        queue.cancel()
        try await waitUntil { !queue.isDownloading }

        XCTAssertEqual(started.value, 1, "the second link must never start")
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testFinishedItemsCanBeClearedButNotWhileDownloading() async throws {
        let queue = makeQueue()
        queue.linkText = "https://example.com/one"
        queue.download()
        queue.clearFinished()
        XCTAssertEqual(queue.items.count, 1, "an item in progress stays")
        try await waitUntil { !queue.isDownloading }

        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testIntelMacsAreToldWhyAndNothingRuns() async throws {
        let calls = Counter()
        let queue = makeQueue(
            availability: .unsupportedHardware,
            lookUp: { _ in calls.increment(); return VideoInfo(title: "x", duration: nil, maxHeight: nil, isLive: false) },
            fetch: { _, _, _, _, _, _ in calls.increment(); return URL(fileURLWithPath: "/x") }
        )

        queue.linkText = "https://example.com/one"
        queue.download()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(queue.message, DownloadError.unsupportedHardware.localizedDescription)
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertFalse(queue.isDownloading)
        XCTAssertEqual(calls.value, 0)
    }

    func testProgressOnlyMovesForwardAndNeverRevivesAFinishedItem() async throws {
        let queue = makeQueue(fetch: { _, _, _, _, _, progress in
            progress(.downloading(0.6))
            progress(.downloading(0.2))
            try await Task.sleep(nanoseconds: 100_000_000)
            return URL(fileURLWithPath: "/Downloads/a.mp4")
        })
        queue.linkText = "https://example.com/a"
        queue.download()
        try await waitUntil { !queue.isDownloading }

        guard case .done = queue.items[0].status else { return XCTFail("\(queue.items[0].status)") }
    }

    // MARK: - Helpers

    private func makeQueue(
        availability: DownloadAvailability? = nil,
        defaults: UserDefaults? = nil,
        lookUp: DownloadQueue.LookUp? = nil,
        fetch: DownloadQueue.Fetch? = nil
    ) -> DownloadQueue {
        DownloadQueue(
            availability: availability ?? .available(tools),
            defaults: defaults ?? ((try? makeDefaults()) ?? .standard),
            downloadsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("never-used-downloads"),
            lookUp: lookUp ?? { url in VideoInfo(title: url.lastPathComponent, duration: nil, maxHeight: 1080, isLive: false) },
            fetch: fetch ?? { url, _, _, _, _, _ in URL(fileURLWithPath: "/Downloads/\(url.lastPathComponent).mp4") }
        )
    }

    /// A private defaults store, so tests never read or change the real settings.
    private func makeDefaults() throws -> UserDefaults {
        let name = "ProSlideDownloadQueueTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out waiting", file: file, line: line)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
        func add(_ line: String) { lock.lock(); recorded.append(line); lock.unlock() }
    }
}
