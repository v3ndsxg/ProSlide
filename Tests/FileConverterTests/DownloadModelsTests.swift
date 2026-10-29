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
        for text in [
            "hello", "ftp://example.com/video.mp4", "file:///etc/passwd", "-o", "--exec=x",
            "javascript:alert(1)", "someone@example.com", ".hidden", "example.",
        ] {
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

    func testALinkPastedWithoutHTTPSIsGivenIt() {
        for (text, expected) in [
            ("vimeo.com/76979871", "https://vimeo.com/76979871"),
            ("www.tiktok.com/@someone/video/123", "https://www.tiktok.com/@someone/video/123"),
            ("youtu.be/dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            ("http://vimeo.com/76979871", "http://vimeo.com/76979871"),
        ] {
            let link = DownloadLink.classify(text)
            XCTAssertTrue(link.isDownloadable, text)
            XCTAssertEqual(link.url?.absoluteString, expected, text)
            XCTAssertEqual(link.text, text, "the row shows what was pasted")
        }
    }

    func testYouTubeLinksInEveryFormBecomeThePlainVideoLink() {
        let forms = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=4&t=42s",
            "https://m.youtube.com/watch?app=desktop&v=dQw4w9WgXcQ",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc",
            "https://youtu.be/dQw4w9WgXcQ?si=tracking&t=10",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share",
            "https://www.youtube.com/live/dQw4w9WgXcQ",
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
            "youtube.com/shorts/dQw4w9WgXcQ",
        ]
        for text in forms {
            let link = DownloadLink.classify(text)
            XCTAssertTrue(link.isDownloadable, text)
            XCTAssertEqual(link.url?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", text)
        }

        let links = DownloadLink.parse(forms.joined(separator: "\n"))
        XCTAssertEqual(links.map(\.text), [forms[0]], "one video pasted in many forms is one link")
    }

    func testAYouTubeLinkWithAnOddIdIsLeftAsItWas() {
        let text = "https://www.youtube.com/watch?v=abc&list=PL123"
        XCTAssertEqual(DownloadLink.classify(text).url?.absoluteString, text, "yt-dlp decides what it means")
    }

    // MARK: - Video details

    func testVideoInfoReadsTitleDurationAndTallestPicture() throws {
        let json = """
        {"title":"Sunday","duration":125.5,"is_live":false,
         "formats":[{"vcodec":"none","height":null},{"vcodec":"avc1.64002a","height":1080},{"vcodec":"vp09.00","height":2160},{"vcodec":"none","height":4000}]}
        """
        let info = try VideoInfo.parse(Data(json.utf8))
        XCTAssertEqual(info, VideoInfo(
            title: "Sunday", duration: 125.5, maxHeight: 2160, isLive: false,
            formats: [VideoFormat(resolution: 1080), VideoFormat(resolution: 2160)]
        ))
        XCTAssertEqual(info.json, Data(json.utf8), "the raw lookup is kept so a download can start from it")
        XCTAssertTrue(info.canBeReused)
    }

    func testPicturesAreMeasuredByTheirShorterSide() throws {
        let json = """
        {"title":"t","formats":[
          {"vcodec":"avc1","width":1080,"height":1920},
          {"vcodec":"vp09","width":2048,"height":858},
          {"vcodec":"none","width":4000,"height":4000}]}
        """
        let info = try VideoInfo.parse(Data(json.utf8))
        XCTAssertEqual(info.formats.map(\.resolution), [1080, 858], "a vertical Short is 1080, not 1920")
        XCTAssertEqual(info.maxHeight, 1080)
        XCTAssertFalse(DownloadQuality.p1440.isOffered(by: [info]), "a Short must not enable 1440p")
    }

    func testAV1DoesntCountTowardsTheBestQualityUnlessItIsAllThereIs() throws {
        // Like a video whose 4K exists only as AV1: the download takes the VP9 1440p.
        let mixed = """
        {"title":"m","formats":[{"vcodec":"avc1","height":1080},{"vcodec":"vp09","height":1440},{"vcodec":"av01.0.12M.08","height":2160}]}
        """
        let info = try VideoInfo.parse(Data(mixed.utf8))
        XCTAssertEqual(info.maxHeight, 1440)
        XCTAssertFalse(DownloadQuality.p2160.isOffered(by: [info]), "4K would download as AV1, which an M2 can't play")
        XCTAssertEqual(info.formats.filter(\.isAV1).map(\.resolution), [2160])

        let onlyAV1 = #"{"title":"a","formats":[{"vcodec":"av01","height":720},{"vcodec":"av01","height":2160}]}"#
        XCTAssertEqual(try VideoInfo.parse(Data(onlyAV1.utf8)).maxHeight, 2160, "with nothing else, AV1 is what downloads")
    }

    func testAnOldLookupIsNoLongerReusable() {
        let old = VideoInfo(title: "x", duration: nil, maxHeight: nil, isLive: false,
                            json: Data("{}".utf8), fetchedAt: Date(timeIntervalSinceNow: -3 * 3600))
        XCTAssertFalse(old.canBeReused)
        XCTAssertFalse(VideoInfo(title: "x", duration: nil, maxHeight: nil, isLive: false).canBeReused, "no saved output to reuse")
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

    func testVideoDownloadPicksAPlayableVersionUpToTheChosenHeight() {
        for quality in DownloadQuality.allCases {
            let arguments = DownloadArguments.download(
                url: URL(string: "https://example.com/v")!, format: .mp4, quality: quality,
                work: URL(fileURLWithPath: "/work"), tools: tools
            )
            XCTAssertEqual(value(after: "-f", in: arguments), "bv*[vcodec!^=?av01]+ba/b[vcodec!^=?av01]/bv*+ba/b")
            XCTAssertEqual(value(after: "-S", in: arguments), "res:\(quality.rawValue),+hdr,+vcodec:avc,proto,acodec:aac")
            XCTAssertEqual(value(after: "--merge-output-format", in: arguments), "mp4")
            XCTAssertEqual(value(after: "--remux-video", in: arguments), "mp4", "other containers are repackaged, not re-encoded")
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

    func testFastLookupAsksYouTubeForItsQuickestClient() {
        let url = URL(string: "https://example.com/v")!
        let fast = DownloadArguments.info(url: url, tools: tools, fast: true)
        XCTAssertEqual(value(after: "--extractor-args", in: fast), "youtube:player_client=visionos;skip=hls")
        XCTAssertFalse(DownloadArguments.info(url: url, tools: tools, fast: false).contains("--extractor-args"))
        XCTAssertEqual(Array(fast.suffix(2)), ["--", url.absoluteString])
    }

    func testDownloadFromASavedLookupIsGivenNoLink() {
        let arguments = DownloadArguments.download(
            url: URL(string: "https://example.com/-o")!,
            savedLookup: URL(fileURLWithPath: "/work/info.json"),
            format: .mp4, quality: .p1080, work: URL(fileURLWithPath: "/work"), tools: tools
        )
        XCTAssertEqual(value(after: "--load-info-json", in: arguments), "/work/info.json")
        XCTAssertFalse(arguments.contains("--"))
        XCTAssertFalse(arguments.contains("https://example.com/-o"))
        XCTAssertEqual(value(after: "-S", in: arguments), DownloadArguments.videoOrder(.p1080), "the same choices are made again")
    }

    func testWithoutATitleTheFileIsNamedByYtDlp() {
        let arguments = DownloadArguments.download(
            url: URL(string: "https://example.com/v")!, titleKnown: false,
            format: .mp4, quality: .p1080, work: URL(fileURLWithPath: "/work"), tools: tools
        )
        XCTAssertTrue(arguments.contains("/work/%(title).120B.%(ext)s"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Progress

    private let mebibyte = 1_048_576.0

    func testProgressIsWeightedBySizeNotSplitEvenlyBetweenVideoAndAudio() throws {
        let parser = ProgressParser(format: .mp4)
        XCTAssertNil(parser.consume("[download] Destination: /work/download.f137.mp4"))

        let half = try XCTUnwrap(parser.consume("[download]  50.0% of ~ 100.00MiB at 5.00MiB/s ETA 00:10"))
        XCTAssertEqual(half.phase, .video)
        // 50 of an expected 105 (the audio is guessed at 5% until it starts).
        XCTAssertEqual(try XCTUnwrap(half.fraction), 50.0 / 105.0, accuracy: 0.001)
        XCTAssertEqual(half.bytesPerSecond, 5 * mebibyte)
        XCTAssertEqual(half.secondsLeft, 11, "55 MiB left at 5 MiB/s")

        let videoDone = try XCTUnwrap(parser.consume("[download] 100% of 100.00MiB in 00:20 at 5.00MiB/s"))
        XCTAssertEqual(try XCTUnwrap(videoDone.fraction), 100.0 / 105.0, accuracy: 0.001,
                       "finishing the video is about 95%, not 50%")

        XCTAssertNil(parser.consume("[download] Destination: /work/download.f140.m4a"))
        let audio = try XCTUnwrap(parser.consume("[download]  50.0% of 4.00MiB at 2.00MiB/s"))
        XCTAssertEqual(audio.phase, .audio)
        XCTAssertEqual(try XCTUnwrap(audio.fraction), 102.0 / 104.0, accuracy: 0.001, "the real audio size replaces the guess")
        XCTAssertEqual(try XCTUnwrap(parser.consume("[download] 100% of 4.00MiB")).fraction, 1)
        XCTAssertEqual(parser.consume("[Merger] Merging formats into \"/work/download.mp4\"")?.phase, .merging)
        XCTAssertEqual(parser.consume("[VideoRemuxer] Remuxing video from webm to mp4; Destination: /work/download.mp4")?.phase,
                       .finishing)
    }

    func testAnAudioOnlyDownloadIsOneStream() throws {
        let parser = ProgressParser(format: .mp3)
        _ = parser.consume("[download] Destination: /work/download.webm")
        let reading = try XCTUnwrap(parser.consume("[download]  25.0% of 8.00MiB at 1.00MiB/s ETA 00:06"))
        XCTAssertEqual(reading.phase, .audio)
        XCTAssertEqual(try XCTUnwrap(reading.fraction), 0.25, accuracy: 0.001)
        XCTAssertEqual(parser.consume("[ExtractAudio] Destination: /work/download.mp3")?.phase, .finishing)
    }

    func testProgressWithoutASizeFallsBackToStreamCounting() throws {
        let parser = ProgressParser(format: .mp4)
        _ = parser.consume("[download] Destination: /work/download.f137.mp4")
        let reading = try XCTUnwrap(parser.consume("[download]  50.0% of Unknown at Unknown B/s ETA Unknown"))
        XCTAssertEqual(try XCTUnwrap(reading.fraction), 0.25, accuracy: 0.001)
        XCTAssertNil(reading.bytesPerSecond)
        XCTAssertNil(reading.secondsLeft)
    }

    func testProgressIgnoresOtherLines() {
        let parser = ProgressParser(format: .mp4)
        XCTAssertNil(parser.consume("[youtube] abc: Downloading webpage"))
        XCTAssertNil(parser.consume("[info] Writing video thumbnail to: /work/thumb.webp"))
        XCTAssertNil(parser.consume("[download] Sleeping 4.00 seconds as required by the site..."))
        XCTAssertNil(parser.consume(""))
    }

    func testProgressNeverExceedsOne() throws {
        let parser = ProgressParser(format: .mp3)
        _ = parser.consume("[download] Destination: a")
        _ = parser.consume("[download] Destination: b")
        XCTAssertEqual(try XCTUnwrap(parser.consume("[download] 100% of 1.00MiB")).fraction, 1)
    }

    func testStatusLinesSayWhatIsHappening() {
        XCTAssertEqual(
            DownloadProgress(phase: .video, fraction: 0.45, bytesPerSecond: 3.2e6, secondsLeft: 80).statusLine,
            "Downloading video \u{00B7} 45% \u{00B7} \(ByteCountFormatter.string(fromByteCount: 3_200_000, countStyle: .file))/s \u{00B7} 1:20 left"
        )
        XCTAssertEqual(DownloadProgress(phase: .audio).statusLine, "Downloading audio")
        XCTAssertEqual(DownloadProgress(phase: .merging).statusLine, "Merging video and audio")
        XCTAssertEqual(DownloadProgress(phase: .finishing).statusLine, "Finishing\u{2026}")
        XCTAssertEqual(DownloadProgress(phase: .video, fraction: 0.5, secondsLeft: 3725).statusLine,
                       "Downloading video \u{00B7} 50% \u{00B7} 1:02:05 left")
    }

    func testClockTimesAreRead() {
        XCTAssertEqual(ProgressParser.Reading.clock("01:20"), 80)
        XCTAssertEqual(ProgressParser.Reading.clock("1:02:03"), 3723)
        XCTAssertNil(ProgressParser.Reading.clock("Unknown"))
        XCTAssertEqual(ProgressParser.Reading.bytes("~316.00MiB"), 316 * mebibyte)
        XCTAssertEqual(ProgressParser.Reading.bytes("512.00KiB"), 512 * 1024)
        XCTAssertNil(ProgressParser.Reading.bytes("Unknown"))
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
            ("ERROR: [youtube] x: Sign in to confirm you\u{2019}re not a bot. Use --cookies-from-browser", .botCheck),
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

    func testWarningsDontDecideWhatWentWrong() {
        let lines = [
            "WARNING: [youtube] x: Some formats may be missing. Sign in or use --cookies for the authentication",
            "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            "[download] Got error: timed out",
        ]
        XCTAssertEqual(
            DownloadError.fromToolOutput(lines),
            .toolFailed("ERROR: unable to download video data: HTTP Error 403: Forbidden")
        )
        XCTAssertEqual(DownloadError.fromToolOutput(["[youtube] x: Video unavailable"]), .unavailable,
                       "with no ERROR line every line is read")
    }

    func testOnlyALinkNoClientCanDownloadSkipsTheNormalLookup() {
        for error: DownloadError in [.unavailable, .privateVideo, .loginRequired, .botCheck, .network, .lookupTimedOut, .toolFailed("x")] {
            XCTAssertTrue(error.worthRetryingLookup, "\(error)")
        }
        for error: DownloadError in [.liveNotSupported, .playlistNotSupported, .unsupportedSite] {
            XCTAssertFalse(error.worthRetryingLookup, "\(error)")
        }
    }
}
