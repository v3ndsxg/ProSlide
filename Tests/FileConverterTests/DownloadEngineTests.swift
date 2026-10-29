@testable import FileConverterCore
import XCTest

/// The engine is driven through stand-in `yt-dlp` and `ffmpeg` scripts, as the
/// conversion tests use a stand-in LibreOffice: no network, no real tools, and
/// every folder a temporary one.
final class DownloadEngineTests: XCTestCase {

    private let info = VideoInfo(title: "Welcome Loop - Sunday", duration: 72, maxHeight: 2160, isLive: false)
    private let url = URL(string: "https://example.com/watch?v=abc")!

    // MARK: - Downloading

    func testH264VideoIsMovedIntoPlaceWithoutConversion() async throws {
        let setup = try makeSetup()

        let progress = Progress()
        let file = try await setup.engine.download(
            url: url, info: info, format: .mp4, quality: .p1080,
            into: setup.downloads, progress: { progress.add($0) }
        )

        XCTAssertEqual(file.lastPathComponent, "Welcome Loop - Sunday.mp4")
        XCTAssertEqual(try String(contentsOf: file), "mp4", "an H.264 download must not be re-encoded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.ffmpegLog.path), "the app never runs ffmpeg itself")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MediaItem.thumbnailURL(for: file).path))
        XCTAssertEqual(workFolderContents(setup.downloads), [], "the work folder must be emptied")
        XCTAssertEqual(MediaItem.scan(in: setup.downloads).map(\.title), ["Welcome Loop - Sunday"])
        // 50% of a 10 MiB video, with the audio estimated at 5% of it.
        XCTAssertTrue(progress.values.contains { value in
            value.phase == .video && abs((value.fraction ?? 0) - 5.0 / 10.5) < 0.01 && value.bytesPerSecond == 1_048_576
        }, "\(progress.values)")
        XCTAssertEqual(progress.values.last?.phase, .finishing)
    }

    func testA4KDownloadIsNeverReencoded() async throws {
        let setup = try makeSetup()
        let progress = Progress()

        let file = try await setup.engine.download(
            url: url, info: info, format: .mp4, quality: .p2160,
            into: setup.downloads, progress: { progress.add($0) }
        )

        XCTAssertEqual(try String(contentsOf: file), "mp4", "the file yt-dlp made is the one in the bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.ffmpegLog.path), "nothing is converted afterwards")
        let line = try XCTUnwrap(try runs(setup).last)
        XCTAssertTrue(line.contains("--remux-video mp4"), line)
        XCTAssertTrue(line.contains("res:2160"), line)
        XCTAssertEqual(progress.values.last?.phase, .finishing)
    }

    func testAudioDownloadIsAnMP3() async throws {
        let setup = try makeSetup()

        let file = try await setup.engine.download(
            url: url, info: info, format: .mp3, quality: .p1080,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(file.lastPathComponent, "Welcome Loop - Sunday.mp3")
        XCTAssertEqual(try String(contentsOf: file), "mp3")
    }

    func testARepeatDownloadIsNumberedRatherThanOverwritten() async throws {
        let setup = try makeSetup()
        var names: [String] = []
        for _ in 0..<3 {
            let file = try await setup.engine.download(
                url: url, info: info, format: .mp4, quality: .p1080,
                into: setup.downloads, progress: { _ in }
            )
            names.append(file.lastPathComponent)
        }
        XCTAssertEqual(names, ["Welcome Loop - Sunday.mp4", "Welcome Loop - Sunday 2.mp4", "Welcome Loop - Sunday 3.mp4"])
    }

    func testAFailedDownloadIsExplainedAndLeavesNothingBehind() async throws {
        let setup = try makeSetup(
            ytDlpBody: "echo 'ERROR: [instagram] abc: Login required' >&2\nexit 1"
        )

        do {
            _ = try await setup.engine.download(
                url: url, info: info, format: .mp4, quality: .p1080,
                into: setup.downloads, progress: { _ in }
            )
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DownloadError, .loginRequired)
        }
        XCTAssertEqual(workFolderContents(setup.downloads), [])
        XCTAssertEqual(MediaItem.scan(in: setup.downloads), [])
    }

    func testStopEndsTheToolAndLeavesNothingBehind() async throws {
        let setup = try makeSetup(ytDlpBody: "exec sleep 30")

        let task = Task {
            try await setup.engine.download(
                url: url, info: info, format: .mp4, quality: .p1080,
                into: setup.downloads, progress: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the download to be cancelled")
        } catch is CancellationError {
        }
        XCTAssertEqual(workFolderContents(setup.downloads), [])
    }

    func testAToolThatGoesQuietIsStopped() async throws {
        var setup = try makeSetup(ytDlpBody: "exec sleep 30")
        setup.engine.idleTimeout = 1

        do {
            _ = try await setup.engine.download(
                url: url, info: info, format: .mp4, quality: .p1080,
                into: setup.downloads, progress: { _ in }
            )
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? DownloadError, .timedOut)
        }
    }

    func testLiveStreamsAreRefusedBeforeAnythingRuns() async throws {
        let setup = try makeSetup(ytDlpBody: "echo should-not-run >&2\nexit 1")
        let live = VideoInfo(title: "Live", duration: nil, maxHeight: 1080, isLive: true)

        do {
            _ = try await setup.engine.download(
                url: url, info: live, format: .mp4, quality: .p1080,
                into: setup.downloads, progress: { _ in }
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? DownloadError, .liveNotSupported)
        }
    }

    // MARK: - Looking a link up

    func testFetchInfoReadsTheTitleAndTallestPicture() async throws {
        let setup = try makeSetup()
        let fetched = try await setup.engine.fetchInfo(for: url)
        XCTAssertEqual(fetched.title, "Welcome Loop: Sunday")
        XCTAssertEqual(fetched.maxHeight, 2160)
        XCTAssertEqual(fetched.duration, 72)
    }

    func testFetchInfoRefusesALiveStream() async throws {
        let setup = try makeSetup(ytDlpBody: #"echo '{"title":"Live","is_live":true,"formats":[]}'"#)
        do {
            _ = try await setup.engine.fetchInfo(for: url)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? DownloadError, .liveNotSupported)
        }
    }

    func testFetchInfoExplainsAFailure() async throws {
        let setup = try makeSetup(ytDlpBody: "echo 'ERROR: [youtube] abc: Private video' >&2\nexit 1")
        do {
            _ = try await setup.engine.fetchInfo(for: url)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DownloadError, .privateVideo)
        }
    }

    // MARK: - Speed and stalls

    /// A lookup prints about a megabyte of JSON on one line. Reading that one
    /// byte at a time once stalled for minutes, so no lookup ever finished.
    func testAMegabyteOfOutputOnOneLineIsReadAtOnce() async throws {
        let big = #"printf '{"title":"Big","pad":"'; head -c 1500000 /dev/zero | tr '\0' 'a'; printf '","formats":[]}\n'"#
        let setup = try makeSetup(ytDlpBody: big)

        let start = Date()
        let fetched = try await setup.engine.fetchInfo(for: url)

        XCTAssertEqual(fetched.title, "Big")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testStopEndsTheToolsHelperProcessesToo() async throws {
        // Like yt-dlp, which runs its real work in a child of the program that was launched.
        let setup = try makeSetup(ytDlpBody: "sleep 31.7 &\nwait")
        addTeardownBlock { _ = self.run("/usr/bin/pkill", ["-f", "sleep 31.7"]) }

        let task = Task {
            try await setup.engine.download(
                url: url, info: nil, format: .mp4, quality: .p1080,
                into: setup.downloads, progress: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(run("/usr/bin/pgrep", ["-f", "sleep 31.7"]), "the helper should be running before Stop")

        task.cancel()
        _ = try? await task.value
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(run("/usr/bin/pgrep", ["-f", "sleep 31.7"]), "Stop must end the helper as well")
    }

    func testALookupThatTakesTooLongGivesUp() async throws {
        var setup = try makeSetup(ytDlpBody: "exec sleep 30")
        setup.engine.quickLookupTimeout = 1
        setup.engine.lookupTimeout = 1

        let start = Date()
        do {
            _ = try await setup.engine.fetchInfo(for: url)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? DownloadError, .lookupTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(try runs(setup).count, 2, "a slow quick lookup is tried again the normal way")
    }

    func testASlowQuickLookupLeavesTheNormalOneItsOwnTime() async throws {
        var setup = try makeSetup(slowFastLookup: true)
        setup.engine.quickLookupTimeout = 1
        setup.engine.lookupTimeout = 10

        let fetched = try await setup.engine.fetchInfo(for: url)

        XCTAssertEqual(fetched.maxHeight, 2160)
        let lines = try runs(setup)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[1].contains("player_client=visionos"))
    }

    func testLookupUsesTheFastClientAndFallsBackToTheNormalOnes() async throws {
        let fast = try makeSetup()
        _ = try await fast.engine.fetchInfo(for: url)
        XCTAssertEqual(try runs(fast).count, 1)
        XCTAssertTrue(try runs(fast)[0].contains("player_client=visionos"))

        let refused = try makeSetup(failFastLookup: true)
        let fetched = try await refused.engine.fetchInfo(for: url)
        let lines = try runs(refused)
        XCTAssertEqual(fetched.maxHeight, 2160)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("player_client=visionos"))
        XCTAssertFalse(lines[1].contains("player_client=visionos"))
    }

    func testAVideoTheQuickClientCallsUnavailableIsAskedAgainTheNormalWay() async throws {
        let setup = try makeSetup(failFastLookup: true, fastLookupError: "ERROR: [youtube] abc: Video unavailable")
        let fetched = try await setup.engine.fetchInfo(for: url)
        XCTAssertEqual(fetched.title, "Welcome Loop: Sunday")
        XCTAssertEqual(try runs(setup).count, 2)
    }

    func testALinkNoClientCanDownloadIsNotAskedAgain() async throws {
        let setup = try makeSetup(ytDlpBody: "echo 'ERROR: Unsupported URL: https://example.com/x' >&2\nexit 1")
        do {
            _ = try await setup.engine.fetchInfo(for: url)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DownloadError, .unsupportedSite)
        }
        XCTAssertEqual(try runs(setup).count, 1, "no YouTube client makes an unsupported site supported")
    }

    // MARK: - Starting from the lookup

    func testDownloadStartsFromTheSavedLookupInsteadOfAskingAgain() async throws {
        let setup = try makeSetup()
        let looked = VideoInfo(title: "Saved", duration: 72, maxHeight: 1080, isLive: false, json: Data("{}".utf8))

        let file = try await setup.engine.download(
            url: url, info: looked, format: .mp4, quality: .p1080,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(file.lastPathComponent, "Saved.mp4")
        let line = try XCTUnwrap(try runs(setup).last)
        XCTAssertTrue(line.contains("--load-info-json"), line)
        XCTAssertFalse(line.contains(url.absoluteString), "the link must not be looked up again: \(line)")
    }

    func testASavedLookupThatFailsIsRetriedFromScratchOnce() async throws {
        let setup = try makeSetup(failSavedLookup: true)
        let looked = VideoInfo(title: "Saved", duration: 72, maxHeight: 1080, isLive: false, json: Data("{}".utf8))

        let file = try await setup.engine.download(
            url: url, info: looked, format: .mp4, quality: .p1080,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(file.lastPathComponent, "Saved.mp4")
        let lines = try runs(setup)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("--load-info-json"))
        XCTAssertFalse(lines[1].contains("--load-info-json"))
        XCTAssertTrue(lines[1].contains(url.absoluteString))
    }

    func testAnOldSavedLookupIsNotReused() async throws {
        let setup = try makeSetup()
        let stale = VideoInfo(
            title: "Old", duration: 72, maxHeight: 1080, isLive: false,
            json: Data("{}".utf8), fetchedAt: Date(timeIntervalSinceNow: -3 * 3600)
        )

        _ = try await setup.engine.download(
            url: url, info: stale, format: .mp4, quality: .p1080,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertFalse(try XCTUnwrap(try runs(setup).last).contains("--load-info-json"))
    }

    func testWithoutALookupTheDownloadNamesTheFileItself() async throws {
        let setup = try makeSetup()

        let file = try await setup.engine.download(
            url: url, info: nil, format: .mp4, quality: .p1080,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(file.lastPathComponent, "Their Own Title.mp4")
    }

    // MARK: - Setup

    private struct Setup {
        var engine: DownloadEngine
        let downloads: URL
        let ffmpegLog: URL
        /// One line per yt-dlp run: its arguments.
        let ytDlpLog: URL
    }

    /// A stand-in `yt-dlp` that behaves like a successful one unless `ytDlpBody`
    /// replaces it, and a stand-in `ffmpeg` that records being run, which the
    /// engine should never do.
    private func makeSetup(
        failFastLookup: Bool = false,
        fastLookupError: String = "ERROR: something odd happened",
        slowFastLookup: Bool = false,
        failSavedLookup: Bool = false,
        ytDlpBody: String? = nil
    ) throws -> Setup {
        let root = try makeTemporaryDirectory()
        let toolsDirectory = root.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("ffmpeg.log")
        let ytDlpLog = root.appendingPathComponent("yt-dlp.log")

        let fastFailure: String
        if failFastLookup {
            fastFailure = #"case "$*" in *player_client=visionos*) echo "\#(fastLookupError)" >&2; exit 1 ;; esac"#
        } else if slowFastLookup {
            fastFailure = #"case "$*" in *player_client=visionos*) exec sleep 30 ;; esac"#
        } else {
            fastFailure = ""
        }
        let savedFailure = failSavedLookup
            ? #"case "$*" in *--load-info-json*) echo "ERROR: unable to download video data: HTTP Error 403: Forbidden" >&2; exit 1 ;; esac"#
            : ""
        let ytDlp = "echo \"$@\" >> \"\(ytDlpLog.path)\"\n" + (ytDlpBody ?? """
        \(fastFailure)
        \(savedFailure)
        for a in "$@"; do
          if [ "$a" = "--dump-single-json" ]; then
            echo '{"title":"Welcome Loop: Sunday","duration":72,"is_live":false,"formats":[{"vcodec":"none","height":null},{"vcodec":"avc1","height":1080},{"vcodec":"vp09","height":2160}]}'
            exit 0
          fi
        done
        media=""; thumb=""; prev=""; audio=0
        for a in "$@"; do
          if [ "$prev" = "-o" ]; then
            case "$a" in
              thumbnail:*) thumb="${a#thumbnail:}" ;;
              *) media="$a" ;;
            esac
          fi
          if [ "$a" = "-x" ]; then audio=1; fi
          prev="$a"
        done
        echo "[download] Destination: $media"
        echo "[download]  50.0% of 10.00MiB at 1.00MiB/s"
        echo "[download] 100% of 10.00MiB"
        named() { printf '%s' "$1" | sed -e 's/%(title).120B/Their Own Title/' -e "s/%(ext)s/$2/"; }
        if [ $audio = 1 ]; then
          printf mp3 > "$(named "$media" mp3)"
        else
          printf mp4 > "$(named "$media" mp4)"
        fi
        printf jpg > "$(printf '%s' "$thumb" | sed 's/%(ext)s/jpg/')"
        """)

        let ffmpeg = "echo \"$@\" >> \"\(log.path)\""

        try writeTool("yt-dlp", body: ytDlp, in: toolsDirectory)
        try writeTool("ffmpeg", body: ffmpeg, in: toolsDirectory)
        try writeTool("deno", body: "exit 0", in: toolsDirectory)
        let tools = try XCTUnwrap(DownloadTools.locate(
            resources: nil,
            environment: [DownloadTools.overrideVariable: toolsDirectory.path]
        ))
        return Setup(
            engine: DownloadEngine(tools: tools),
            downloads: root.appendingPathComponent("Downloads", isDirectory: true),
            ffmpegLog: log,
            ytDlpLog: ytDlpLog
        )
    }

    /// The arguments of each yt-dlp run, in order.
    private func runs(_ setup: Setup) throws -> [String] {
        try String(contentsOf: setup.ytDlpLog).split(separator: "\n").map(String.init)
    }

    /// Runs a program and says whether it exited successfully.
    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func writeTool(_ name: String, body: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private func workFolderContents(_ downloads: URL) -> [String] {
        let work = downloads.appendingPathComponent(DownloadFileNames.workFolderName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).sorted()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideDownloadEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [DownloadProgress] = []

        var values: [DownloadProgress] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func add(_ value: DownloadProgress) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
    }
}
