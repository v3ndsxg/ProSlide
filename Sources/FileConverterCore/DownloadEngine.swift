import Foundation

/// Fetches one video or audio file from a link and puts it in the downloads
/// folder, ready to drag into ProPresenter.
///
/// Everything that touches the network is `yt-dlp`; this type only builds its
/// command line, reads what it prints, and tidies the result. `yt-dlp` writes
/// into a private work folder and the finished file is moved into place only
/// when complete, so the bin never shows a half-downloaded file and Stop leaves
/// nothing behind.
public struct DownloadEngine: Sendable {
    public let tools: DownloadTools

    /// How long a download may go without a line of output before it is stopped.
    public var idleTimeout: TimeInterval
    /// How long looking a link up may take, all attempts included.
    public var lookupTimeout: TimeInterval
    public var log: DownloadLog?

    public init(
        tools: DownloadTools,
        idleTimeout: TimeInterval = 60,
        lookupTimeout: TimeInterval = 45,
        log: DownloadLog? = nil
    ) {
        self.tools = tools
        self.idleTimeout = idleTimeout
        self.lookupTimeout = lookupTimeout
        self.log = log
    }

    // MARK: - Looking a link up

    /// Asks `yt-dlp` about a link. It first uses YouTube's fastest client, which
    /// reports the same pictures in about half the time, and falls back to the
    /// normal clients if that is refused.
    public func fetchInfo(for url: URL) async throws -> VideoInfo {
        let engine = self
        return try await withTimeout(lookupTimeout) {
            do {
                return try await engine.lookUp(url, fast: true)
            } catch let error as DownloadError where error.worthRetryingLookup {
                engine.log?.note("Fast lookup failed (\(error)); trying the normal clients")
                return try await engine.lookUp(url, fast: false)
            }
        }
    }

    private func lookUp(_ url: URL, fast: Bool) async throws -> VideoInfo {
        let result = try await ToolProcess.run(
            executable: tools.ytDlp,
            arguments: DownloadArguments.info(url: url, tools: tools, fast: fast),
            keepStdout: true,
            // The overall cap is what ends a slow lookup, so this must not beat it.
            idleTimeout: lookupTimeout * 2,
            log: log,
            onLine: { _ in }
        )
        guard result.status == 0 else { throw DownloadError.fromToolOutput(result.tail) }
        let info = try VideoInfo.parse(Data(result.stdout.utf8))
        if info.isLive { throw DownloadError.liveNotSupported }
        return info
    }

    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw DownloadError.lookupTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DownloadError.noOutput }
            return first
        }
    }

    // MARK: - Downloading

    /// Downloads `url` and returns the file now in `downloadsDirectory`.
    ///
    /// With a recent `info` the download starts from the lookup's saved results
    /// instead of asking the site again. If that fails it is tried once more
    /// from scratch. `info` can be nil, when the lookup failed or timed out; the
    /// download then works out the title itself.
    ///
    /// The file is named after the video's title, and a repeat gets " 2", " 3"
    /// rather than overwriting an earlier download.
    public func download(
        url: URL,
        info: VideoInfo?,
        format: DownloadFormat,
        quality: DownloadQuality,
        into downloadsDirectory: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        if info?.isLive == true { throw DownloadError.liveNotSupported }

        if let info, info.canBeReused, let json = info.json {
            do {
                return try await run(url, info: info, json: json, format: format, quality: quality,
                                     into: downloadsDirectory, progress: progress)
            } catch let error as DownloadError where error.worthRetryingFresh {
                log?.note("Download from saved lookup failed (\(error)); starting again from a fresh lookup")
            }
        }
        return try await run(url, info: info, json: nil, format: format, quality: quality,
                             into: downloadsDirectory, progress: progress)
    }

    private func run(
        _ url: URL,
        info: VideoInfo?,
        json: Data?,
        format: DownloadFormat,
        quality: DownloadQuality,
        into downloadsDirectory: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let work = downloadsDirectory
            .appendingPathComponent(DownloadFileNames.workFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        // Success moves the file out first; anything else, Stop included,
        // leaves nothing in the bin's folder.
        defer { try? fileManager.removeItem(at: work) }

        var savedLookup: URL?
        if let json {
            let file = work.appendingPathComponent("info.json")
            try json.write(to: file)
            savedLookup = file
        }

        let parser = ProgressParser(format: format)
        let result = try await ToolProcess.run(
            executable: tools.ytDlp,
            arguments: DownloadArguments.download(
                url: url, savedLookup: savedLookup, titleKnown: info != nil,
                format: format, quality: quality, work: work, tools: tools
            ),
            idleTimeout: idleTimeout,
            log: log,
            onLine: { line in
                if let update = parser.consume(line) { progress(update) }
            }
        )
        guard result.status == 0 else { throw DownloadError.fromToolOutput(result.tail) }
        progress(DownloadProgress(phase: .finishing))

        let finished = try downloadedFile(in: work, format: format)
        let title = info?.title ?? finished.deletingPathExtension().lastPathComponent

        let name = DownloadFileNames.sanitize(title)
        let destination = DownloadFileNames.uniqueURL(base: name, extension: format.rawValue, in: downloadsDirectory)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: finished, to: destination)

        let thumbnail = work.appendingPathComponent(DownloadArguments.thumbnailFileName)
        if fileManager.fileExists(atPath: thumbnail.path) {
            let target = MediaItem.thumbnailURL(for: destination)
            try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: target)
            try? fileManager.moveItem(at: thumbnail, to: target)
        }
        return destination
    }

    /// The media file `yt-dlp` produced. It is always an MP4 or MP3: `yt-dlp`
    /// repackages any other container itself, or fails.
    private func downloadedFile(in work: URL, format: DownloadFormat) throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.pathExtension.lowercased() == format.rawValue }) else {
            throw DownloadError.noOutput
        }
        return file
    }
}

// MARK: - Command lines

enum DownloadArguments {
    static let mediaBaseName = "download"
    static let thumbnailFileName = "thumb.jpg"

    /// YouTube's fastest client. It reports the same pictures and codecs as the
    /// normal ones in about half the time, and its links need no challenge
    /// solving. `skip=hls` leaves out the streaming formats a download never
    /// picks. Other sites ignore the option.
    static let fastYouTube = "youtube:player_client=visionos;skip=hls"

    /// Options for every `yt-dlp` run.
    ///
    /// `--ignore-config` keeps a user's own yt-dlp settings from changing what
    /// the app does, and `--no-update` keeps the pinned build as it is. Both
    /// helper programs are named by path because a program started from the
    /// Finder has almost no `PATH`.
    private static func common(_ tools: DownloadTools) -> [String] {
        [
            "--ignore-config",
            "--no-update",
            "--no-playlist",
            "--ffmpeg-location", tools.ffmpeg.deletingLastPathComponent().path,
            "--js-runtimes", "deno:\(tools.deno.path)",
            "--socket-timeout", "30",
        ]
    }

    /// `--` ends the options, so a link can never be read as one.
    static func info(url: URL, tools: DownloadTools, fast: Bool = false) -> [String] {
        common(tools)
            + (fast ? ["--extractor-args", fastYouTube] : [])
            + ["--dump-single-json", "--skip-download", "--no-warnings", "--", url.absoluteString]
    }

    /// With `savedLookup`, `yt-dlp` reads the lookup's results from that file and
    /// is given no link at all.
    static func download(
        url: URL,
        savedLookup: URL? = nil,
        titleKnown: Bool = true,
        format: DownloadFormat,
        quality: DownloadQuality,
        work: URL,
        tools: DownloadTools
    ) -> [String] {
        // Without a title from the lookup, yt-dlp names the file after it.
        let base = titleKnown ? mediaBaseName : "%(title).120B"
        var arguments = common(tools) + [
            "--newline",
            // The file's date is when it was downloaded, so the bin sorts by it.
            "--no-mtime",
            "--write-thumbnail", "--convert-thumbnails", "jpg",
            "-o", work.appendingPathComponent("\(base).%(ext)s").path,
            "-o", "thumbnail:" + work.appendingPathComponent("thumb.%(ext)s").path,
        ]
        switch format {
        case .mp4:
            // Merged or repackaged into an MP4 by copying, never re-encoded.
            arguments += [
                "-f", videoFormats,
                "-S", videoOrder(quality),
                "--merge-output-format", "mp4",
                "--remux-video", "mp4",
            ]
        case .mp3:
            arguments += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "320K"]
        }
        if let savedLookup {
            return arguments + ["--load-info-json", savedLookup.path]
        }
        return arguments + ["--", url.absoluteString]
    }

    /// Nothing is converted: the download is picked so it plays as it comes.
    /// AV1 is left out because Macs before the M3 can't decode it, so it wouldn't
    /// play in ProPresenter; it is used only if a video has nothing else. A codec
    /// the site doesn't name (`?`) is kept. YouTube's VP9, its only choice above
    /// 1080p, plays in ProPresenter.
    static let videoFormats = "bv*[vcodec!^=?av01]+ba/b[vcodec!^=?av01]/bv*+ba/b"

    /// Which of those to prefer, in order: the tallest picture up to the chosen
    /// height; standard over HDR, since ProPresenter shows standard colour; then
    /// H.264, which every Mac decodes in hardware, before HEVC and VP9; a direct
    /// download before a streamed one (YouTube's HLS copy comes in fragments and
    /// is slower); and AAC sound, which YouTube offers on nearly every video.
    static func videoOrder(_ quality: DownloadQuality) -> String {
        "res:\(quality.rawValue),+hdr,+vcodec:avc,proto,acodec:aac"
    }
}

// MARK: - Progress

/// Turns `yt-dlp`'s "[download]  45.3% of 316.00MiB at 3.20MiB/s ETA 01:20"
/// lines into one steady picture of the whole download.
///
/// A video and its audio download as two streams, each running 0 to 100. The
/// audio is a few percent of the bytes, so the fraction is weighted by size
/// rather than by stream: counting each as half had the bar jump to 50% almost
/// at once and then crawl.
final class ProgressParser: @unchecked Sendable {
    private let format: DownloadFormat
    private let lock = NSLock()
    private var stream = 0
    private var totals: [Int: Double] = [:]

    /// Audio is about this fraction of a video's size, used until its real size
    /// is known.
    private static let audioShare = 0.05

    init(format: DownloadFormat) { self.format = format }

    func consume(_ line: String) -> DownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        if line.hasPrefix("[download] Destination:") {
            stream += 1
            return nil
        }
        if line.hasPrefix("[Merger]") { return DownloadProgress(phase: .merging) }
        if line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[VideoRemuxer]")
            || line.hasPrefix("[Fixup") {
            return DownloadProgress(phase: .finishing)
        }
        guard line.hasPrefix("[download]"), let reading = Reading(line) else { return nil }

        let phase: DownloadProgress.Phase = (format == .mp4 && stream <= 1) ? .video : .audio
        let fraction: Double
        var secondsLeft = reading.secondsLeft
        if let total = reading.totalBytes {
            totals[max(stream, 1)] = total
            let first = totals[1] ?? total
            let done: Double
            let expected: Double
            if format == .mp4 {
                let second = totals[2] ?? first * ProgressParser.audioShare
                expected = first + second
                done = stream <= 1 ? reading.percent / 100 * first : first + reading.percent / 100 * second
            } else {
                expected = first
                done = reading.percent / 100 * first
            }
            fraction = expected > 0 ? done / expected : 0
            if let speed = reading.bytesPerSecond, speed > 0 {
                secondsLeft = Int(max(expected - done, 0) / speed)
            }
        } else {
            let streams = format == .mp4 ? 2.0 : 1.0
            fraction = (Double(max(stream - 1, 0)) + reading.percent / 100) / streams
        }
        return DownloadProgress(
            phase: phase,
            fraction: min(max(fraction, 0), 1),
            bytesPerSecond: reading.bytesPerSecond,
            secondsLeft: secondsLeft
        )
    }

    /// The numbers on one progress line.
    struct Reading {
        let percent: Double
        let totalBytes: Double?
        let bytesPerSecond: Double?
        let secondsLeft: Int?

        init?(_ line: String) {
            let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard let percentToken = tokens.first(where: { $0.hasSuffix("%") }),
                  let percent = Double(percentToken.dropLast()) else { return nil }
            self.percent = percent

            func after(_ word: String) -> String? {
                guard let index = tokens.firstIndex(of: word) else { return nil }
                // The size of an estimated total is written "~ 316.00MiB".
                return tokens[(index + 1)...].first { $0 != "~" }
            }
            totalBytes = after("of").flatMap { Reading.bytes($0) }
            bytesPerSecond = after("at").flatMap { Reading.bytes($0.replacingOccurrences(of: "/s", with: "")) }
            secondsLeft = after("ETA").flatMap { Reading.clock($0) }
        }

        /// "316.00MiB", "~316.00MiB" or "512.00KiB" as a number of bytes.
        static func bytes(_ text: String) -> Double? {
            let trimmed = text.hasPrefix("~") ? String(text.dropFirst()) : text
            let units: [(String, Double)] = [
                ("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1_024),
                ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1),
            ]
            for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
                guard let value = Double(trimmed.dropLast(suffix.count)) else { return nil }
                return value * factor
            }
            return nil
        }

        /// "01:20" or "1:02:03" as seconds.
        static func clock(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == text.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
    }
}

// MARK: - File names

enum DownloadFileNames {
    /// Hidden, so the bin's scan skips it. Each download works in a folder here.
    static let workFolderName = ".work"

    /// A title made safe as a file name: characters Finder can't show are
    /// replaced or dropped, and it can't start with a dot, which would hide it.
    static func sanitize(_ title: String) -> String {
        var name = ""
        for character in title {
            switch character {
            case "/", "\\", ":": name.append("-")
            case "*", "?", "\"", "<", ">", "|": break
            default:
                if character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    name.append(character)
                }
            }
        }
        let collapsed = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var trimmed = String(collapsed.drop(while: { $0 == "." || $0 == "-" || $0 == " " }))
        if trimmed.count > 120 { trimmed = String(trimmed.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return trimmed.isEmpty ? "Download" : trimmed
    }

    /// `Base.ext`, or `Base 2.ext`, `Base 3.ext`… if that is taken.
    static func uniqueURL(base: String, extension ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
