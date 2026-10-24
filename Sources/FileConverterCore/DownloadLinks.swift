import Foundation

/// One line pasted into the Downloader, checked before anything is fetched.
public struct DownloadLink: Identifiable, Equatable, Sendable {
    /// What was pasted, trimmed.
    public let text: String
    public let url: URL?
    /// Why this link can't be downloaded, or nil if it can be tried.
    public let unsupportedReason: String?

    public var id: String { text }
    public var isDownloadable: Bool { unsupportedReason == nil && url != nil }

    /// Splits pasted text into links, one per whitespace-separated piece,
    /// dropping repeats and keeping the order they were pasted in.
    public static func parse(_ pasted: String) -> [DownloadLink] {
        var seen = Set<String>()
        return pasted
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .map(classify)
    }

    static func classify(_ text: String) -> DownloadLink {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return DownloadLink(text: text, url: nil, unsupportedReason: "That isn\u{2019}t a web link.")
        }
        return DownloadLink(text: text, url: url, unsupportedReason: youTubeProblem(url: url, host: host))
    }

    /// Playlists and channels are refused; a video link that merely carries a
    /// playlist id (`watch?v=…&list=…`) is one video and downloads as that.
    private static func youTubeProblem(url: URL, host: String) -> String? {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let isYouTube = bare == "youtube.com" || bare.hasSuffix(".youtube.com") || bare == "youtu.be"
        guard isYouTube else { return nil }

        let path = url.path
        if bare == "youtu.be" {
            return path.count > 1 ? nil : "This link doesn\u{2019}t point to a video."
        }
        if path == "/playlist" {
            return "Playlists aren\u{2019}t supported. Paste a single video link."
        }
        if ["/channel/", "/c/", "/user/", "/@"].contains(where: { path.hasPrefix($0) }) {
            return "Channels aren\u{2019}t supported. Paste a single video link."
        }
        if path == "/watch" {
            let hasVideo = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false
            return hasVideo ? nil : "This link doesn\u{2019}t point to a video."
        }
        if path.isEmpty || path == "/" {
            return "This link doesn\u{2019}t point to a video."
        }
        return nil
    }
}
