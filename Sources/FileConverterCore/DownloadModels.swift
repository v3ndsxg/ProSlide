import Foundation

public enum DownloadFormat: String, CaseIterable, Identifiable, Sendable {
    case mp4
    case mp3

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4: "MP4 Video"
        case .mp3: "MP3 Audio"
        }
    }
}

/// The tallest picture to download. It means "up to this": a video without it
/// downloads at the best it has.
public enum DownloadQuality: Int, CaseIterable, Identifiable, Sendable {
    case p2160 = 2160
    case p1440 = 1440
    case p1080 = 1080
    case p720 = 720
    case p480 = 480
    case p360 = 360

    public static let standard: DownloadQuality = .p1080

    public var id: Int { rawValue }

    public var title: String {
        self == .p2160 ? "4K" : "\(rawValue)p"
    }

    /// Whether any of `infos` has a picture this tall. False means the option
    /// would do nothing for these links, so the picker greys it out. The lowest
    /// option stays available so the picker is never empty, and nothing is
    /// greyed out while no links have been looked at.
    public func isOffered(by infos: [VideoInfo]) -> Bool {
        if self == .p360 || infos.isEmpty { return true }
        return infos.contains { ($0.maxHeight ?? Int.max) >= rawValue }
    }
}

/// Where one download is up to, for the card in the bin and the Downloader's
/// list.
public struct DownloadProgress: Equatable, Sendable {
    /// In the order a download goes through them. Updates can arrive late, so
    /// the queue never moves an item back to an earlier phase.
    public enum Phase: Int, Comparable, Sendable {
        case video, audio, merging, finishing, converting

        public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var phase: Phase
    /// How far through the whole job, 0 to 1, or nil when that isn't known.
    public var fraction: Double?
    public var bytesPerSecond: Double?
    public var secondsLeft: Int?

    public init(phase: Phase, fraction: Double? = nil, bytesPerSecond: Double? = nil, secondsLeft: Int? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.bytesPerSecond = bytesPerSecond
        self.secondsLeft = secondsLeft
    }

    /// One line saying what is happening, such as
    /// "Downloading video · 45% · 3.2 MB/s · 1:20 left".
    public var statusLine: String {
        var parts: [String]
        switch phase {
        case .video: parts = ["Downloading video"]
        case .audio: parts = ["Downloading audio"]
        case .merging: return "Merging video and audio"
        case .finishing: return "Finishing\u{2026}"
        case .converting: parts = ["Converting to H.264"]
        }
        if let fraction { parts.append("\(Int((fraction * 100).rounded()))%") }
        if phase == .video || phase == .audio, let speed = bytesPerSecond, speed > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
        }
        if let left = secondsLeft { parts.append("\(DownloadProgress.clock(left)) left") }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func clock(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// One picture quality a video is offered in.
public struct VideoFormat: Equatable, Sendable {
    /// The shorter side in pixels. This is how yt-dlp, and so the quality
    /// picker, measures a picture: a vertical 1080x1920 Short is 1080, not 1920.
    public let resolution: Int
    /// True for H.264, and for a codec the site doesn't name, which is given the
    /// benefit of the doubt: the file is checked after it downloads anyway.
    public let isH264: Bool

    public init(resolution: Int, isH264: Bool) {
        self.resolution = resolution
        self.isH264 = isH264
    }
}

/// What yt-dlp reports about a link before anything is downloaded.
public struct VideoInfo: Equatable, Sendable {
    public let title: String
    public let duration: TimeInterval?
    /// The best picture on offer, measured by its shorter side, or nil when the
    /// site doesn't say.
    public let maxHeight: Int?
    public let isLive: Bool
    public let formats: [VideoFormat]

    /// The lookup's raw output and when it was made. A download can start from
    /// these instead of asking the site again, which saves the second round of
    /// extraction and, on YouTube, a wait the site imposes at the start.
    public let json: Data?
    public let fetchedAt: Date

    /// Saved addresses expire after hours; this is well inside that.
    static let reusableFor: TimeInterval = 2 * 3600

    public var canBeReused: Bool {
        json != nil && Date().timeIntervalSince(fetchedAt) < VideoInfo.reusableFor
    }

    public init(
        title: String,
        duration: TimeInterval?,
        maxHeight: Int?,
        isLive: Bool,
        formats: [VideoFormat] = [],
        json: Data? = nil,
        fetchedAt: Date = Date()
    ) {
        self.title = title
        self.duration = duration
        self.maxHeight = maxHeight
        self.isLive = isLive
        self.formats = formats
        self.json = json
        self.fetchedAt = fetchedAt
    }

    /// The raw output and the time are left out: two lookups that found the same
    /// thing are equal.
    public static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        lhs.title == rhs.title && lhs.duration == rhs.duration && lhs.maxHeight == rhs.maxHeight
            && lhs.isLive == rhs.isLive && lhs.formats == rhs.formats
    }

    /// Whether downloading at `quality` ends in a video that isn't H.264 and has
    /// to be converted. It follows what the download asks for: the best picture
    /// up to the chosen height (or the smallest above it if none is that small),
    /// preferring H.264 at that height.
    public func convertsToH264(at quality: DownloadQuality) -> Bool {
        guard !formats.isEmpty else { return false }
        let within = formats.filter { $0.resolution <= quality.rawValue }
        let target = within.isEmpty
            ? formats.map(\.resolution).min() ?? 0
            : within.map(\.resolution).max() ?? 0
        return !formats.contains { $0.resolution == target && $0.isH264 }
    }

    /// Reads the JSON that `yt-dlp --dump-single-json` prints.
    public static func parse(_ json: Data, fetchedAt: Date = Date()) throws -> VideoInfo {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DownloadError.badMetadata
        }
        if (object["_type"] as? String) == "playlist" {
            throw DownloadError.playlistNotSupported
        }

        func shorterSide(_ format: [String: Any]) -> Int? {
            let sides = [format["height"], format["width"]].compactMap { ($0 as? NSNumber)?.intValue }
            return sides.min()
        }

        let formats: [VideoFormat] = (object["formats"] as? [[String: Any]] ?? []).compactMap { format in
            let codec = (format["vcodec"] as? String) ?? ""
            guard codec != "none", let side = shorterSide(format) else { return nil }
            let isH264 = codec.isEmpty || codec == "unknown" || codec.hasPrefix("avc") || codec.hasPrefix("h264")
            return VideoFormat(resolution: side, isH264: isH264)
        }
        return VideoInfo(
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Download",
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            maxHeight: formats.map(\.resolution).max() ?? shorterSide(object),
            isLive: (object["is_live"] as? Bool) ?? false,
            formats: formats,
            json: json,
            fetchedAt: fetchedAt
        )
    }
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case toolsMissing
    case unsupportedHardware
    case playlistNotSupported
    case liveNotSupported
    case loginRequired
    case ageRestricted
    case privateVideo
    case unavailable
    case geoBlocked
    case unsupportedSite
    case network
    case timedOut
    case lookupTimedOut
    case badMetadata
    case noOutput
    case conversionFailed(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolsMissing:
            "The download tools are missing from this build of the app."
        case .unsupportedHardware:
            "Downloads aren\u{2019}t supported on Intel Macs yet."
        case .playlistNotSupported:
            "Playlists aren\u{2019}t supported. Paste a single video link."
        case .liveNotSupported:
            "Live streams can\u{2019}t be downloaded."
        case .loginRequired:
            "This video needs a login, so it can\u{2019}t be downloaded."
        case .ageRestricted:
            "This video is age-restricted and needs a login, so it can\u{2019}t be downloaded."
        case .privateVideo:
            "This video is private."
        case .unavailable:
            "This video is unavailable."
        case .geoBlocked:
            "This video isn\u{2019}t available in your country."
        case .unsupportedSite:
            "This link isn\u{2019}t supported."
        case .network:
            "Couldn\u{2019}t reach the site. Check the internet connection and try again."
        case .timedOut:
            "The download stalled and was stopped."
        case .lookupTimedOut:
            "Couldn\u{2019}t check this link in time. Download will still try."
        case .badMetadata:
            "Couldn\u{2019}t read this video\u{2019}s details."
        case .noOutput:
            "The download finished but produced no file."
        case .conversionFailed(let detail):
            "Couldn\u{2019}t convert the video to MP4. \(detail)"
        case .toolFailed(let detail):
            "The download failed. The site may have changed; check for a ProSlide Beta update. \(detail)"
        }
    }

    /// Whether trying the same thing again could plausibly work, so the item
    /// offers a Retry button.
    public var isRetryable: Bool {
        switch self {
        case .timedOut, .network, .toolFailed, .noOutput, .conversionFailed, .lookupTimedOut: true
        default: false
        }
    }

    /// A failed fast lookup is worth repeating with YouTube's normal clients
    /// when the fast one may simply have been refused. A video that is private
    /// or gone is the same whichever way it is asked.
    var worthRetryingLookup: Bool {
        switch self {
        case .toolFailed, .badMetadata, .loginRequired, .ageRestricted: true
        default: false
        }
    }

    /// A download from saved lookup results that failed, and might work from a
    /// fresh lookup instead.
    var worthRetryingFresh: Bool {
        switch self {
        case .toolFailed, .network, .noOutput: true
        default: false
        }
    }

    /// Turns the tail of yt-dlp's output into the reason a person can act on.
    static func fromToolOutput(_ lines: [String]) -> DownloadError {
        let text = lines.joined(separator: "\n").lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("confirm your age", "age-restricted", "age restricted") { return .ageRestricted }
        if has("private video") { return .privateVideo }
        if has("sign in", "log in", "login", "requires authentication", "--cookies") { return .loginRequired }
        if has("available in your country", "blocked it in your country", "geo restrict", "geo-restrict") { return .geoBlocked }
        if has("video unavailable", "has been removed", "no longer available", "does not exist") { return .unavailable }
        if has("unsupported url") { return .unsupportedSite }
        if has("unable to download webpage", "name or service not known", "timed out",
               "network is unreachable", "http error 429", "nodename nor servname") { return .network }

        let detail = lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? ""
        return .toolFailed(detail)
    }
}
