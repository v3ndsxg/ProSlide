@testable import FileConverterCore
import XCTest

/// The pure parts of the downloader: what a pasted link means, what yt-dlp is
/// told to do, and how its output is read.
final class DownloadModelsTests: XCTestCase {

    // MARK: - Links

    func testPastedTextBecomesOneLinkPerPieceWithRepeatsDropped() {
        let links = DownloadLink.parse("""
        https://vimeo.com/76979871
          https://www.youtube.com/watch?v=abc

        https://vimeo.com/76979871
        """)
        XCTAssertEqual(links.map(\.text), ["https://vimeo.com/76979871", "https://www.youtube.com/watch?v=abc"])
        XCTAssertTrue(links.allSatisfy(\.isDownloadable))
    }

    func testOnlyWebLinksAreAccepted() {
        for text in ["hello", "ftp://example.com/video.mp4", "file:///etc/passwd", "-o", "javascript:alert(1)"] {
            let link = DownloadLink.classify(text)
            XCTAssertFalse(link.isDownloadable, text)
            XCTAssertNil(link.url, text)
        }
    }

    func testPlaylistsAndChannelsAreRefusedWithAMessage() {
        let refused = [
            "https://www.youtube.com/playlist?list=PL123",
            "https://www.youtube.com/@somechannel",
            "https://www.youtube.com/channel/UC123",
            "https://www.youtube.com/c/Name",
            "https://www.youtube.com/user/Name",
            "https://www.youtube.com/",
            "https://www.youtube.com/watch",
            "https://youtu.be/",
        ]
        for text in refused {
            let link = DownloadLink.classify(text)
            XCTAssertFalse(link.isDownloadable, text)
            XCTAssertNotNil(link.unsupportedReason, text)
        }
        XCTAssertTrue(DownloadLink.classify("https://www.youtube.com/playlist?list=PL123")
            .unsupportedReason!.contains("Playlists"))
    }

    func testAVideoInsideAPlaylistDownloadsAsThatOneVideo() {
        for text in [
            "https://www.youtube.com/watch?v=abc&list=PL123&index=4",
            "https://youtu.be/abc?list=PL123",
            "https://m.youtube.com/watch?v=abc",
            "https://www.youtube.com/shorts/abc",
            "https://music.youtube.com/watch?v=abc",
            "https://vimeo.com/76979871",
            "https://www.tiktok.com/@someone/video/123",
        ] {
            XCTAssertTrue(DownloadLink.classify(text).isDownloadable, text)
        }
    }

    // MARK: - Video details

    func testVideoInfoReadsTitleDurationAndTallestPicture() throws {
        let json = """
        {"title":"Sunday","duration":125.5,"is_live":false,
         "formats":[{"vcodec":"none","height":null},{"vcodec":"avc1.64002a","height":1080},{"vcodec":"vp09.00","height":2160},{"vcodec":"none","height":4000}]}
        """
        let info = try VideoInfo.parse(Data(json.utf8))
        XCTAssertEqual(info, VideoInfo(title: "Sunday", duration: 125.5, maxHeight: 2160, isLive: false))
    }

    func testVideoInfoFallsBackToTheSingleHeightAndAPlaceholderTitle() throws {
        let info = try VideoInfo.parse(Data(#"{"height":720}"#.utf8))
        XCTAssertEqual(info.maxHeight, 720)
        XCTAssertEqual(info.title, "Download")
    }

    func testVideoInfoRefusesPlaylistsAndGarbage() {
        XCTAssertThrowsError(try VideoInfo.parse(Data(#"{"_type":"playlist","title":"x"}"#.utf8))) {
            XCTAssertEqual($0 as? DownloadError, .playlistNotSupported)
        }
        XCTAssertThrowsError(try VideoInfo.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? DownloadError, .badMetadata)
        }
    }

    func testQualityIsGreyedOutOnlyAboveEverythingOffered() {
        let hd = VideoInfo(title: "a", duration: nil, maxHeight: 1080, isLive: false)
        let uhd = VideoInfo(title: "b", duration: nil, maxHeight: 2160, isLive: false)
        let unknown = VideoInfo(title: "c", duration: nil, maxHeight: nil, isLive: false)

        XCTAssertFalse(DownloadQuality.p2160.isOffered(by: [hd]))
        XCTAssertFalse(DownloadQuality.p1440.isOffered(by: [hd]))
        XCTAssertTrue(DownloadQuality.p1080.isOffered(by: [hd]))
        XCTAssertTrue(DownloadQuality.p720.isOffered(by: [hd]), "a lower option still works for a taller video")
        XCTAssertTrue(DownloadQuality.p2160.isOffered(by: [hd, uhd]), "one link with 4K is enough")
        XCTAssertTrue(DownloadQuality.p2160.isOffered(by: [unknown]), "an unknown height is not ruled out")
        XCTAssertTrue(DownloadQuality.p2160.isOffered(by: []), "nothing is greyed out before any link is looked up")
        XCTAssertTrue(DownloadQuality.p360.isOffered(by: [VideoInfo(title: "d", duration: nil, maxHeight: 240, isLive: false)]))
    }

    // MARK: - Command lines

    private let tools = DownloadTools(
        ytDlp: URL(fileURLWithPath: "/App/Tools/yt-dlp"),
        ffmpeg: URL(fileURLWithPath: "/App/Tools/ffmpeg"),
        deno: URL(fileURLWithPath: "/App/Tools/deno")
    )

    func testALinkIsNeverReadAsAnOption() {
        let url = URL(string: "https://example.com/-o")!
        for arguments in [
            DownloadArguments.info(url: url, tools: tools),
            DownloadArguments.download(url: url, format: .mp4, quality: .p1080, work: URL(fileURLWithPath: "/work"), tools: tools),
            DownloadArguments.download(url: url, format: .mp3, quality: .p1080, work: URL(fileURLWithPath: "/work"), tools: tools),
        ] {
            XCTAssertEqual(Array(arguments.suffix(2)), ["--", url.absoluteString])
        }
    }

    func testEveryRunIsPinnedAndUsesThePackagedHelpers() {
        let arguments = DownloadArguments.info(url: URL(string: "https://example.com/v")!, tools: tools)
        XCTAssertTrue(arguments.contains("--ignore-config"))
        XCTAssertTrue(arguments.contains("--no-update"))
        XCTAssertTrue(arguments.contains("--no-playlist"))
        XCTAssertTrue(arguments.contains("--dump-single-json"))
        XCTAssertEqual(value(after: "--ffmpeg-location", in: arguments), "/App/Tools")
        XCTAssertEqual(value(after: "--js-runtimes", in: arguments), "deno:/App/Tools/deno")
    }

    func testVideoDownloadAsksForH264UpToTheChosenHeight() {
        for quality in DownloadQuality.allCases {
            let arguments = DownloadArguments.download(
                url: URL(string: "https://example.com/v")!, format: .mp4, quality: quality,
                work: URL(fileURLWithPath: "/work"), tools: tools
            )
            XCTAssertEqual(value(after: "-S", in: arguments), "res:\(quality.rawValue),vcodec:h264,acodec:aac")
            XCTAssertEqual(value(after: "--merge-output-format", in: arguments), "mp4")
            XCTAssertTrue(arguments.contains("--no-mtime"))
            XCTAssertTrue(arguments.contains("/work/download.%(ext)s"))
            XCTAssertTrue(arguments.contains("thumbnail:/work/thumb.%(ext)s"))
        }
    }

    func testAudioDownloadIsA320kMP3() {
        let arguments = DownloadArguments.download(
            url: URL(string: "https://example.com/v")!, format: .mp3, quality: .p1080,
            work: URL(fileURLWithPath: "/work"), tools: tools
        )
        XCTAssertTrue(arguments.contains("-x"))
        XCTAssertEqual(value(after: "--audio-format", in: arguments), "mp3")
        XCTAssertEqual(value(after: "--audio-quality", in: arguments), "320K")
        XCTAssertFalse(arguments.contains("-S"))
    }

    func testConversionCopiesWhatIsAlreadyRight() {
        let copy = DownloadArguments.convert(
            input: URL(fileURLWithPath: "/in.mkv"), output: URL(fileURLWithPath: "/out.mp4"),
            videoEncoder: "copy", copyAudio: true, quality: .p1080
        )
        XCTAssertEqual(value(after: "-c:v", in: copy), "copy")
        XCTAssertEqual(value(after: "-c:a", in: copy), "copy")
        XCTAssertFalse(copy.contains("-b:v"))
        XCTAssertEqual(copy.last, "/out.mp4")

        let hardware = DownloadArguments.convert(
            input: URL(fileURLWithPath: "/in.webm"), output: URL(fileURLWithPath: "/out.mp4"),
            videoEncoder: "h264_videotoolbox", copyAudio: false, quality: .p2160
        )
        XCTAssertEqual(value(after: "-b:v", in: hardware), "35M")
        XCTAssertEqual(value(after: "-c:a", in: hardware), "aac")
    }

    func testCodecsAreReadFromFFmpegOutput() {
        let text = """
        Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 1920x1080
        Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo
        """
        XCTAssertEqual(DownloadArguments.codec("Video", in: text), "h264")
        XCTAssertEqual(DownloadArguments.codec("Audio", in: text), "aac")
        XCTAssertNil(DownloadArguments.codec("Audio", in: "Stream #0:0: Video: vp9"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Progress

    func testProgressIsSpreadAcrossTheVideoAndAudioStreams() {
        let parser = ProgressParser(expectedStreams: 2)
        XCTAssertNil(parser.consume("[download] Destination: /work/download.f137.mp4"))
        XCTAssertEqual(parser.consume("[download]  50.0% of 80.00MiB at 5.00MiB/s ETA 00:08"), .downloading(0.25))
        XCTAssertEqual(parser.consume("[download] 100% of 80.00MiB in 00:16"), .downloading(0.5))
        XCTAssertNil(parser.consume("[download] Destination: /work/download.f140.m4a"))
        XCTAssertEqual(parser.consume("[download]  50.0% of 3.00MiB"), .downloading(0.75))
        XCTAssertEqual(parser.consume("[download] 100% of 3.00MiB"), .downloading(1))
        XCTAssertEqual(parser.consume("[Merger] Merging formats into \"/work/download.mp4\""), .finishing)
    }

    func testProgressIgnoresOtherLines() {
        let parser = ProgressParser(expectedStreams: 1)
        XCTAssertNil(parser.consume("[youtube] abc: Downloading webpage"))
        XCTAssertNil(parser.consume("[info] Writing video thumbnail to: /work/thumb.webp"))
        XCTAssertNil(parser.consume(""))
    }

    func testProgressNeverExceedsOne() {
        let parser = ProgressParser(expectedStreams: 1)
        _ = parser.consume("[download] Destination: a")
        _ = parser.consume("[download] Destination: b")
        XCTAssertEqual(parser.consume("[download] 100% of 1MiB"), .downloading(1))
    }

    // MARK: - File names

    func testTitlesBecomeSafeFileNames() {
        XCTAssertEqual(DownloadFileNames.sanitize("Welcome Loop - Sunday"), "Welcome Loop - Sunday")
        XCTAssertEqual(DownloadFileNames.sanitize("AC/DC: Back in Black"), "AC-DC- Back in Black")
        XCTAssertEqual(DownloadFileNames.sanitize("What? \"Why\" <now> | *later*"), "What Why now later")
        XCTAssertEqual(DownloadFileNames.sanitize("  ..hidden   name  "), "hidden name")
        XCTAssertEqual(DownloadFileNames.sanitize("???"), "Download")
        XCTAssertEqual(DownloadFileNames.sanitize(""), "Download")
        XCTAssertLessThanOrEqual(DownloadFileNames.sanitize(String(repeating: "a", count: 500)).count, 120)
    }

    // MARK: - Tools

    func testToolsAreFoundInTheOverrideFolderOnlyWhenAllAreExecutable() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProSlideToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let environment = [DownloadTools.overrideVariable: folder.path]

        func install(_ name: String, mode: Int) throws {
            let file = folder.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }

        try install("yt-dlp", mode: 0o755)
        try install("ffmpeg", mode: 0o755)
        XCTAssertNil(DownloadTools.locate(resources: nil, environment: environment), "deno is missing")

        try install("deno", mode: 0o644)
        XCTAssertNil(DownloadTools.locate(resources: nil, environment: environment), "deno is not executable")

        try install("deno", mode: 0o755)
        XCTAssertEqual(DownloadTools.locate(resources: nil, environment: environment)?.deno.lastPathComponent, "deno")
    }

    func testToolsDefaultToTheAppsResourcesFolder() {
        let resources = URL(fileURLWithPath: "/nonexistent/Resources")
        XCTAssertNil(DownloadTools.locate(resources: resources, environment: [:]))
        XCTAssertNil(DownloadTools.locate(resources: nil, environment: [:]))
    }

    func testAvailabilityNamesTheReasonDownloadsCantRun() {
        let tools = DownloadTools(ytDlp: URL(fileURLWithPath: "/a"), ffmpeg: URL(fileURLWithPath: "/b"), deno: URL(fileURLWithPath: "/c"))
        XCTAssertEqual(DownloadAvailability.current(isAppleSilicon: false, tools: tools), .unsupportedHardware)
        XCTAssertEqual(DownloadAvailability.current(isAppleSilicon: true, tools: nil), .toolsMissing)
        XCTAssertEqual(DownloadAvailability.current(isAppleSilicon: true, tools: tools), .available(tools))
        XCTAssertEqual(DownloadAvailability.unsupportedHardware.error, .unsupportedHardware)
        XCTAssertNil(DownloadAvailability.available(tools).error)
    }

    // MARK: - Reading a failure

    func testToolOutputIsTurnedIntoAReasonAPersonCanActOn() {
        let cases: [(String, DownloadError)] = [
            ("ERROR: [instagram] x: Login required", .loginRequired),
            ("ERROR: [youtube] x: Sign in to confirm you\u{2019}re not a bot", .loginRequired),
            ("ERROR: [youtube] x: Sign in to confirm your age", .ageRestricted),
            ("ERROR: [youtube] x: Private video", .privateVideo),
            ("ERROR: [youtube] x: Video unavailable", .unavailable),
            ("ERROR: [youtube] x: The uploader has not made this video available in your country", .geoBlocked),
            ("ERROR: Unsupported URL: https://example.com", .unsupportedSite),
            ("ERROR: Unable to download webpage: <urlopen error timed out>", .network),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(DownloadError.fromToolOutput(["[info] something", line]), expected, line)
        }
        XCTAssertEqual(
            DownloadError.fromToolOutput(["ERROR: something new broke"]),
            .toolFailed("ERROR: something new broke")
        )
    }
}
