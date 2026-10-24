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

    /// How long a tool may go without printing before it is stopped.
    public var idleTimeout: TimeInterval

    public init(tools: DownloadTools, idleTimeout: TimeInterval = 120) {
        self.tools = tools
        self.idleTimeout = idleTimeout
    }

    // MARK: - Looking a link up

    public func fetchInfo(for url: URL) async throws -> VideoInfo {
        let result = try await ToolProcess.run(
            executable: tools.ytDlp,
            arguments: DownloadArguments.info(url: url, tools: tools),
            keepStdout: true,
            idleTimeout: idleTimeout,
            onLine: { _ in }
        )
        guard result.status == 0 else { throw DownloadError.fromToolOutput(result.tail) }
        let info = try VideoInfo.parse(Data(result.stdout.utf8))
        if info.isLive { throw DownloadError.liveNotSupported }
        return info
    }

    // MARK: - Downloading

    /// Downloads `url` and returns the file now in `downloadsDirectory`.
    ///
    /// The file is named after the video's title, and a repeat gets " 2", " 3"
    /// rather than overwriting an earlier download.
    public func download(
        url: URL,
        info: VideoInfo,
        format: DownloadFormat,
        quality: DownloadQuality,
        into downloadsDirectory: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        if info.isLive { throw DownloadError.liveNotSupported }

        let fileManager = FileManager.default
        let work = downloadsDirectory
            .appendingPathComponent(DownloadFileNames.workFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        // Success moves the file out first; anything else, Stop included,
        // leaves nothing in the bin's folder.
        defer { try? fileManager.removeItem(at: work) }

        let parser = ProgressParser(expectedStreams: format == .mp4 ? 2 : 1)
        let result = try await ToolProcess.run(
            executable: tools.ytDlp,
            arguments: DownloadArguments.download(url: url, format: format, quality: quality, work: work, tools: tools),
            idleTimeout: idleTimeout,
            onLine: { line in
                if let update = parser.consume(line) { progress(update) }
            }
        )
        guard result.status == 0 else { throw DownloadError.fromToolOutput(result.tail) }
        progress(.finishing)

        var finished = try downloadedFile(in: work, format: format)
        if format == .mp4 {
            finished = try await makeCompatible(finished, quality: quality, work: work)
        }

        let name = DownloadFileNames.sanitize(info.title)
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

    /// The media file `yt-dlp` produced, whatever container it picked.
    private func downloadedFile(in work: URL, format: DownloadFormat) throws -> URL {
        let wanted = format == .mp4 ? ["mp4", "mkv", "webm", "mov", "m4v"] : ["mp3"]
        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: {
            $0.deletingPathExtension().lastPathComponent == DownloadArguments.mediaBaseName
                && wanted.contains($0.pathExtension.lowercased())
        }) else { throw DownloadError.noOutput }
        return file
    }

    // MARK: - Making the video play in ProPresenter

    /// Leaves a file that is already H.264 video and AAC audio in an MP4 alone,
    /// and otherwise converts only what has to change. This is what 4K needs:
    /// YouTube serves it as VP9 or AV1, which ProPresenter doesn't list.
    private func makeCompatible(_ file: URL, quality: DownloadQuality, work: URL) async throws -> URL {
        let streams = try await inspect(file)
        let videoIsH264 = streams.video == "h264"
        let audioIsAAC = streams.audio == nil || streams.audio == "aac"
        if file.pathExtension.lowercased() == "mp4" && videoIsH264 && audioIsAAC { return file }

        let output = work.appendingPathComponent("converted.mp4")
        let tries: [String] = videoIsH264 ? ["copy"] : ["h264_videotoolbox", "libx264"]
        var lastTail: [String] = []
        for encoder in tries {
            try? FileManager.default.removeItem(at: output)
            let result = try await ToolProcess.run(
                executable: tools.ffmpeg,
                arguments: DownloadArguments.convert(
                    input: file, output: output, videoEncoder: encoder,
                    copyAudio: audioIsAAC, quality: quality
                ),
                idleTimeout: idleTimeout,
                onLine: { _ in }
            )
            if result.status == 0, FileManager.default.fileExists(atPath: output.path) { return output }
            lastTail = result.tail
        }
        throw DownloadError.conversionFailed(lastTail.last ?? "")
    }

    /// The video and audio codecs in `file`. ffmpeg prints them and exits with an
    /// error when given no output, so that exit status is ignored; this avoids
    /// needing ffprobe.
    private func inspect(_ file: URL) async throws -> (video: String?, audio: String?) {
        let result = try await ToolProcess.run(
            executable: tools.ffmpeg,
            arguments: ["-hide_banner", "-i", file.path],
            idleTimeout: idleTimeout,
            onLine: { _ in }
        )
        let text = result.tail.joined(separator: "\n")
        return (DownloadArguments.codec("Video", in: text), DownloadArguments.codec("Audio", in: text))
    }
}

// MARK: - Command lines

enum DownloadArguments {
    static let mediaBaseName = "download"
    static let thumbnailFileName = "thumb.jpg"

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
    static func info(url: URL, tools: DownloadTools) -> [String] {
        common(tools) + ["--dump-single-json", "--skip-download", "--no-warnings", "--", url.absoluteString]
    }

    static func download(
        url: URL,
        format: DownloadFormat,
        quality: DownloadQuality,
        work: URL,
        tools: DownloadTools
    ) -> [String] {
        var arguments = common(tools) + [
            "--newline",
            // The file's date is when it was downloaded, so the bin sorts by it.
            "--no-mtime",
            "--write-thumbnail", "--convert-thumbnails", "jpg",
            "-o", work.appendingPathComponent("\(mediaBaseName).%(ext)s").path,
            "-o", "thumbnail:" + work.appendingPathComponent("thumb.%(ext)s").path,
        ]
        switch format {
        case .mp4:
            // The tallest picture up to the chosen height, and at that height
            // H.264 and AAC when they exist, since those play in ProPresenter
            // without conversion.
            arguments += [
                "-f", "bv*+ba/b",
                "-S", "res:\(quality.rawValue),vcodec:h264,acodec:aac",
                "--merge-output-format", "mp4",
            ]
        case .mp3:
            arguments += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "320K"]
        }
        return arguments + ["--", url.absoluteString]
    }

    /// Converts `input` to an MP4 with H.264 video and AAC audio. Video and audio
    /// that are already right are copied, not re-encoded.
    static func convert(
        input: URL,
        output: URL,
        videoEncoder: String,
        copyAudio: Bool,
        quality: DownloadQuality
    ) -> [String] {
        var arguments = ["-hide_banner", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", videoEncoder]
        switch videoEncoder {
        case "copy":
            break
        case "libx264":
            arguments += ["-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p"]
        default:
            arguments += ["-b:v", bitrate(for: quality), "-pix_fmt", "yuv420p"]
        }
        arguments += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        return arguments + ["-movflags", "+faststart", output.path]
    }

    /// Video bitrates within what ProPresenter recommends for HD and 4K.
    static func bitrate(for quality: DownloadQuality) -> String {
        switch quality {
        case .p2160: "35M"
        case .p1440: "20M"
        case .p1080: "12M"
        case .p720: "8M"
        default: "5M"
        }
    }

    /// The codec on the first `kind` stream line of `ffmpeg -i` output, such as
    /// "h264" from "Stream #0:0: Video: h264 (High), yuv420p".
    static func codec(_ kind: String, in text: String) -> String? {
        guard let range = text.range(of: "\(kind): ") else { return nil }
        let rest = text[range.upperBound...]
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name).lowercased()
    }
}

// MARK: - Progress

/// Turns `yt-dlp`'s "[download]  45.3% of …" lines into one steady fraction.
///
/// A video and its audio download as two streams, each running 0 to 100, so the
/// fraction is spread across them rather than jumping back at the second.
final class ProgressParser: @unchecked Sendable {
    private let expectedStreams: Int
    private let lock = NSLock()
    private var stream = 0

    init(expectedStreams: Int) { self.expectedStreams = max(expectedStreams, 1) }

    func consume(_ line: String) -> DownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        if line.hasPrefix("[download] Destination:") {
            stream += 1
            return nil
        }
        if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoConvertor]") {
            return .finishing
        }
        guard line.hasPrefix("[download]"),
              let percent = ProgressParser.percent(in: line) else { return nil }
        let done = Double(max(stream - 1, 0)) + percent / 100
        return .downloading(min(done / Double(expectedStreams), 1))
    }

    private static func percent(in line: String) -> Double? {
        guard let end = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<end].reversed().prefix { $0.isNumber || $0 == "." }
        return Double(String(digits.reversed()))
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
