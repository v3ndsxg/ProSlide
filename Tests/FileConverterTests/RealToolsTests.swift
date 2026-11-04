@testable import FileConverterCore
import XCTest

/// Runs the engine against the real, packaged `yt-dlp`, `ffmpeg` and Deno, with
/// a local web server standing in for the internet. This is what proves the
/// command lines in `DownloadArguments` are ones the pinned tools accept.
///
/// Skipped unless `PROSLIDE_TOOLS_DIR` points at a folder holding the tools, as
/// CI does after packaging the app. It never leaves the machine.
final class RealToolsTests: XCTestCase {

    func testEngineDownloadsWithTheRealTools() async throws {
        guard let tools = DownloadTools.locate(resources: nil) else {
            throw XCTSkip("\(DownloadTools.overrideVariable) is not set to a folder of tools")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideRealToolsTests-\(UUID().uuidString)", isDirectory: true)
        let served = root.appendingPathComponent("served", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Two tiny clips: one in H.264 and AAC, one in the VP9 and Opus that
        // YouTube serves at 4K, in a WebM.
        let testPicture = ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15"]
        let testTone = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
        try await ffmpeg(tools, ["-hide_banner", "-y"] + testPicture + testTone
            + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
               served.appendingPathComponent("h264.mp4").path])
        try await ffmpeg(tools, ["-hide_banner", "-y"] + testPicture + testTone
            + ["-c:v", "libvpx-vp9", "-c:a", "libopus", "-shortest",
               served.appendingPathComponent("vp9.webm").path])

        let port = Int.random(in: 20_000..<40_000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", served.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        addTeardownBlock { server.terminate() }
        try await waitForServer(port: port)

        let engine = DownloadEngine(tools: tools, idleTimeout: 90)
        func link(_ name: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(name)")! }

        // Looking a link up.
        let info = try await engine.fetchInfo(for: link("h264.mp4"))
        XCTAssertFalse(info.title.isEmpty)
        XCTAssertFalse(info.isLive)

        // H.264 and AAC arrive as they are.
        let direct = try await engine.download(
            url: link("h264.mp4"), info: info, format: .mp4, quality: .p1080,
            into: downloads, progress: { _ in }
        )
        let directCodecs = try await codecs(of: direct, tools: tools)
        XCTAssertEqual(directCodecs.video, "h264")
        XCTAssertEqual(directCodecs.audio, "aac")

        // A WebM is repackaged as an MP4, with its VP9 and Opus left as they are.
        let webmInfo = VideoInfo(title: "VP9 clip", duration: 2, maxHeight: 240, isLive: false)
        let repackaged = try await engine.download(
            url: link("vp9.webm"), info: webmInfo, format: .mp4, quality: .p2160,
            into: downloads, progress: { _ in }
        )
        XCTAssertEqual(repackaged.pathExtension, "mp4")
        let repackagedCodecs = try await codecs(of: repackaged, tools: tools)
        XCTAssertEqual(repackagedCodecs.video, "vp9")
        XCTAssertEqual(repackagedCodecs.audio, "opus")

        // Audio only.
        let audio = try await engine.download(
            url: link("h264.mp4"), info: info, format: .mp3, quality: .p1080,
            into: downloads, progress: { _ in }
        )
        XCTAssertEqual(audio.pathExtension, "mp3")
        let audioCodecs = try await codecs(of: audio, tools: tools)
        XCTAssertEqual(audioCodecs.audio, "mp3")

        // All three are in the bin's folder, and nothing else is.
        XCTAssertEqual(MediaItem.scan(in: downloads).count, 3)
        let work = downloads.appendingPathComponent(DownloadFileNames.workFolderName)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [], [])
    }

    private func ffmpeg(_ tools: DownloadTools, _ arguments: [String]) async throws {
        let result = try await ToolProcess.run(
            executable: tools.ffmpeg, arguments: arguments, idleTimeout: 90, onLine: { _ in }
        )
        XCTAssertEqual(result.status, 0, result.tail.joined(separator: "\n"))
    }

    private func codecs(of file: URL, tools: DownloadTools) async throws -> (video: String?, audio: String?) {
        let result = try await ToolProcess.run(
            executable: tools.ffmpeg, arguments: ["-hide_banner", "-i", file.path],
            idleTimeout: 60, onLine: { _ in }
        )
        let text = result.tail.joined(separator: "\n")
        return (codec("Video", in: text), codec("Audio", in: text))
    }

    /// The codec on the first `kind` stream line of `ffmpeg -i` output, such as
    /// "h264" from "Stream #0:0: Video: h264 (High), yuv420p".
    private func codec(_ kind: String, in text: String) -> String? {
        guard let range = text.range(of: "\(kind): ") else { return nil }
        let name = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name).lowercased()
    }

    private func waitForServer(port: Int) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<100 {
            if (try? await URLSession.shared.data(from: url)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the local test server did not start")
    }
}
