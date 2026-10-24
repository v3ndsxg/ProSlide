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
        let setup = try makeSetup(video: "h264", audio: "aac")

        let progress = Progress()
        let file = try await setup.engine.download(
            url: url, info: info, format: .mp4, quality: .p1080,
            into: setup.downloads, progress: { progress.add($0) }
        )

        XCTAssertEqual(file.lastPathComponent, "Welcome Loop - Sunday.mp4")
        XCTAssertEqual(try String(contentsOf: file), "mp4", "an H.264 download must not be re-encoded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.ffmpegLog.path), "ffmpeg was only asked to look")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MediaItem.thumbnailURL(for: file).path))
        XCTAssertEqual(workFolderContents(setup.downloads), [], "the work folder must be emptied")
        XCTAssertEqual(MediaItem.scan(in: setup.downloads).map(\.title), ["Welcome Loop - Sunday"])
        XCTAssertTrue(progress.values.contains(.downloading(0.25)), "\(progress.values)")
        XCTAssertEqual(progress.values.last, .finishing)
    }

    func testVP9VideoIsConvertedWithTheHardwareEncoder() async throws {
        let setup = try makeSetup(video: "vp9", audio: "opus")

        let file = try await setup.engine.download(
            url: url, info: info, format: .mp4, quality: .p2160,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(try String(contentsOf: file), "converted")
        let log = try String(contentsOf: setup.ffmpegLog)
        XCTAssertTrue(log.contains("h264_videotoolbox"), log)
        XCTAssertTrue(log.contains("-b:v 35M"), log)
        XCTAssertTrue(log.contains("-c:a aac"), "opus audio must become AAC: \(log)")
    }

    func testAlreadyAACAudioIsCopiedWhenOnlyTheVideoChanges() async throws {
        let setup = try makeSetup(video: "av1", audio: "aac")

        _ = try await setup.engine.download(
            url: url, info: info, format: .mp4, quality: .p2160,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertTrue(try String(contentsOf: setup.ffmpegLog).contains("-c:a copy"))
    }

    func testSoftwareEncoderIsUsedWhenTheHardwareOneFails() async throws {
        let setup = try makeSetup(video: "vp9", audio: "aac", failEncoder: "h264_videotoolbox")

        let file = try await setup.engine.download(
            url: url, info: info, format: .mp4, quality: .p2160,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(try String(contentsOf: file), "converted")
        XCTAssertTrue(try String(contentsOf: setup.ffmpegLog).contains("libx264"))
    }

    func testAudioDownloadIsAnMP3() async throws {
        let setup = try makeSetup(video: "h264", audio: "aac")

        let file = try await setup.engine.download(
            url: url, info: info, format: .mp3, quality: .p1080,
            into: setup.downloads, progress: { _ in }
        )

        XCTAssertEqual(file.lastPathComponent, "Welcome Loop - Sunday.mp3")
        XCTAssertEqual(try String(contentsOf: file), "mp3")
    }

    func testARepeatDownloadIsNumberedRatherThanOverwritten() async throws {
        let setup = try makeSetup(video: "h264", audio: "aac")
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
        let setup = try makeSetup(video: "h264", audio: "aac")
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

    // MARK: - Setup

    private struct Setup {
        var engine: DownloadEngine
        let downloads: URL
        let ffmpegLog: URL
    }

    /// A stand-in `yt-dlp` that behaves like a successful one unless `ytDlpBody`
    /// replaces it, and a stand-in `ffmpeg` that reports the given codecs.
    private func makeSetup(
        video: String = "h264",
        audio: String = "aac",
        failEncoder: String? = nil,
        ytDlpBody: String? = nil
    ) throws -> Setup {
        let root = try makeTemporaryDirectory()
        let toolsDirectory = root.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("ffmpeg.log")

        let ytDlp = ytDlpBody ?? """
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
        if [ $audio = 1 ]; then
          printf mp3 > "$(printf '%s' "$media" | sed 's/%(ext)s/mp3/')"
        else
          printf mp4 > "$(printf '%s' "$media" | sed 's/%(ext)s/mp4/')"
        fi
        printf jpg > "$(printf '%s' "$thumb" | sed 's/%(ext)s/jpg/')"
        """

        let failure = failEncoder.map { "case \"$*\" in *\($0)*) exit 1 ;; esac" } ?? ""
        let ffmpeg = """
        if [ "$#" -eq 3 ] && [ "$2" = "-i" ]; then
          echo "Input #0, mov,mp4, from '$3':" >&2
          echo "  Stream #0:0: Video: \(video) (High), yuv420p, 1920x1080" >&2
          echo "  Stream #0:1: Audio: \(audio), 48000 Hz, stereo" >&2
          echo "At least one output file must be specified" >&2
          exit 1
        fi
        echo "$@" >> "\(log.path)"
        \(failure)
        printf converted > "${@: -1}"
        """

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
            ffmpegLog: log
        )
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
