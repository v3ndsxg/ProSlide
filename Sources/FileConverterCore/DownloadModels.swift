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

/// Progress of one download, for the card in the bin.
public enum DownloadProgress: Equatable, Sendable {
    /// Fraction of the whole download, 0 to 1.
    case downloading(Double)
    /// Downloaded; being merged, converted or tidied up.
    case finishing
}

/// What yt-dlp reports about a link before anything is downloaded.
public struct VideoInfo: Equatable, Sendable {
    public let title: String
    public let duration: TimeInterval?
    /// The tallest picture on offer, or nil when the site doesn't say.
    public let maxHeight: Int?
    public let isLive: Bool

    public init(title: String, duration: TimeInterval?, maxHeight: Int?, isLive: Bool) {
        self.title = title
        self.duration = duration
        self.maxHeight = maxHeight
        self.isLive = isLive
    }

    /// Reads the JSON that `yt-dlp --dump-single-json` prints.
    public static func parse(_ json: Data) throws -> VideoInfo {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DownloadError.badMetadata
        }
        if (object["_type"] as? String) == "playlist" {
            throw DownloadError.playlistNotSupported
        }
        let formats = object["formats"] as? [[String: Any]] ?? []
        let heights = formats.compactMap { format -> Int? in
            guard (format["vcodec"] as? String) != "none" else { return nil }
            return (format["height"] as? NSNumber)?.intValue
        }
        let single = (object["height"] as? NSNumber)?.intValue
        return VideoInfo(
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Download",
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            maxHeight: heights.max() ?? single,
            isLive: (object["is_live"] as? Bool) ?? false
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
