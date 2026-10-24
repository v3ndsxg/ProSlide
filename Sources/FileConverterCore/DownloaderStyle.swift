import Foundation

/// What to say under the quality tabs, and how loudly.
public struct QualityAdvice: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case neutral
        /// Shown in yellow.
        case warning
        /// Shown in red.
        case error
    }

    public let text: String
    public let severity: Severity

    /// Only the two top qualities get a warning when none of the pasted links
    /// offer the one chosen: 4K in red, since it is the one people choose on
    /// purpose, and 1440p in yellow. For anything lower the ordinary line is
    /// enough, because nearly every video has it.
    public static func make(selected: DownloadQuality, infos: [VideoInfo]) -> QualityAdvice {
        if !selected.isOffered(by: infos) {
            switch selected {
            case .p2160:
                return QualityAdvice(text: "None of these links offer 4K. Each downloads at its best.", severity: .error)
            case .p1440:
                return QualityAdvice(text: "None of these links offer 1440p. Each downloads at its best.", severity: .warning)
            default:
                break
            }
        }
        return QualityAdvice(text: "Up to this quality. A video without it downloads at its best.", severity: .neutral)
    }
}

/// The small coloured badge beside a link: a couple of letters on the site's colour.
public struct SiteBadge: Equatable, Sendable {
    public let label: String
    /// 0xRRGGBB.
    public let color: UInt32

    private static let known: [(suffixes: [String], badge: SiteBadge)] = [
        (["youtube.com", "youtu.be"], SiteBadge(label: "YT", color: 0xE62117)),
        (["vimeo.com"], SiteBadge(label: "V", color: 0x1AB7EA)),
        (["tiktok.com"], SiteBadge(label: "TT", color: 0x111111)),
        (["instagram.com"], SiteBadge(label: "IG", color: 0xC13584)),
        (["facebook.com", "fb.watch"], SiteBadge(label: "f", color: 0x1877F2)),
        (["twitter.com", "x.com"], SiteBadge(label: "X", color: 0x14171A)),
        (["reddit.com"], SiteBadge(label: "R", color: 0xFF4500)),
    ]

    /// The badge for a link's host. Sites not listed get their first letter on grey.
    public static func forHost(_ host: String?) -> SiteBadge {
        guard let host = host?.lowercased(), !host.isEmpty else {
            return SiteBadge(label: "?", color: 0x8E8E93)
        }
        for entry in known {
            if entry.suffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return entry.badge }
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return SiteBadge(label: bare.first.map { String($0).uppercased() } ?? "?", color: 0x8E8E93)
    }
}
