import Foundation

/// One line pasted into the Downloader, checked before anything is fetched.
public struct DownloadLink: Identifiable, Equatable, Sendable {
    /// What was pasted, trimmed.
    public let text: String
    /// The link that is looked up and downloaded: `text` with `https://` added
    /// if it was left off, and a YouTube video in its plain `watch?v=` form.
    public let url: URL?
    /// Why this link can't be downloaded, or nil if it can be tried.
    public let unsupportedReason: String?

    /// The tidied link, so one video pasted in two forms is one link.
    public var id: String { url?.absoluteString ?? text }
    public var isDownloadable: Bool { unsupportedReason == nil && url != nil }

    /// Splits pasted text into links, one per whitespace-separated piece,
    /// dropping repeats and keeping the order they were pasted in.
    public static func parse(_ pasted: String) -> [DownloadLink] {
        var seen = Set<String>()
        return pasted
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map(classify)
            .filter { seen.insert($0.id).inserted }
    }

    /// Pasted text with one link per line, which the link box shows as it is
    /// typed or pasted. Links that arrive run together, separated by spaces, or
    /// separated by a newline written out as `%0A` (as text copied out of an
    /// encoded email can be) are split onto lines of their own. A space at the
    /// very end is left alone, so typing isn't disturbed.
    public static func onePerLine(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "%0D%0A|%0A|%0D", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        // A link starting part-way along a line: "…watch?v=abchttps://…". One
        // inside another link, as a query value ("?u=https://…") or in a path
        // ("/web/2020/https://…"), stays where it is.
        result = result.replacingOccurrences(
            of: #"(?<=[^\s=/])(?=https?://)"#, with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        // Spaces or tabs between two pieces of text.
        result = result.replacingOccurrences(of: #"(?<=\S)[ \t]+(?=\S)"#, with: "\n", options: .regularExpression)
        return result
    }

    static func classify(_ text: String) -> DownloadLink {
        guard let url = webURL(text),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return DownloadLink(text: text, url: nil, unsupportedReason: "That isn\u{2019}t a web link.")
        }
        if let video = youTubeVideoID(url: url, host: host) {
            return DownloadLink(text: text, url: URL(string: "https://www.youtube.com/watch?v=\(video)"), unsupportedReason: nil)
        }
        return DownloadLink(text: text, url: url, unsupportedReason: youTubeProblem(url: url, host: host))
    }

    /// `text` as an http or https link. A link pasted without its scheme, such as
    /// `youtube.com/watch?v=…`, gets `https://`; anything else with a scheme is
    /// refused.
    private static func webURL(_ text: String) -> URL? {
        var candidate = text
        if !text.contains("://") {
            // Only something shaped like a site name: "example.com/…", not "-o" or "hello".
            let site = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard site.contains("."), !site.hasPrefix("."), !site.hasSuffix("."), !site.contains(":"), !site.contains("@") else {
                return nil
            }
            candidate = "https://" + text
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func isYouTube(_ host: String) -> Bool {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// The video's id when `url` is a YouTube link to one video in any of its
    /// forms: `watch?v=`, `youtu.be/`, Shorts, `/live/`, embeds, and the mobile
    /// and Music sites. Tracking, timestamps and playlist ids are dropped with
    /// the rest of the link.
    static func youTubeVideoID(url: URL, host: String) -> String? {
        guard isYouTube(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            candidate = parts.first
        } else if parts == ["watch"] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            candidate = items.first { $0.name == "v" }?.value
                // "watch?v%3DID": the "=" was encoded, so "v=ID" reads as the item's name.
                ?? items.first { $0.name.hasPrefix("v=") }.map { String($0.name.dropFirst(2)) }
        } else if parts.count >= 2, ["shorts", "live", "embed", "v", "e"].contains(parts[0]) {
            candidate = parts[1]
        } else {
            candidate = nil
        }
        guard var id = candidate else { return nil }
        // "watch?v=3DID": the link passed through an email's quoted-printable
        // encoding, which writes "=" as "=3D".
        if id.count == 13, id.hasPrefix("3D"), isVideoID(String(id.dropFirst(2))) {
            id = String(id.dropFirst(2))
        }
        return isVideoID(id) ? id : nil
    }

    /// YouTube video ids are 11 letters, digits, `-` and `_`.
    private static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    /// Playlists and channels are refused; a video link that merely carries a
    /// playlist id (`watch?v=…&list=…`) is one video and downloads as that.
    private static func youTubeProblem(url: URL, host: String) -> String? {
        guard isYouTube(host) else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

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
