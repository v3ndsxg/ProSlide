import Foundation

/// What a downloaded file is, taken from its extension.
public enum MediaKind: String, Sendable {
    case video
    case audio

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mp4": self = .video
        case "mp3": self = .audio
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .video: "MP4"
        case .audio: "MP3"
        }
    }
}

/// One downloaded video or audio file in the bin.
///
/// Unlike a deck, which is a folder of JPEGs with a bundle kept elsewhere, a
/// download is a single file, so a drag hands over that file itself.
public struct MediaItem: Identifiable, Equatable, Sendable {
    /// The folder, inside `Downloads`, that holds thumbnails. Hidden, so the
    /// scan and the operator both ignore it.
    public static let thumbnailsFolderName = ".thumbnails"

    public let fileURL: URL
    public let kind: MediaKind
    public let byteCount: Int64
    public let thumbnailURL: URL?

    public var id: String { fileURL.path }

    public var title: String { fileURL.deletingPathExtension().lastPathComponent }

    /// For example "MP4 · 86 MB".
    public var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return "\(kind.label) \u{00B7} \(size)"
    }

    /// Where the thumbnail for `fileURL` is kept, whether or not one exists yet.
    public static func thumbnailURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(thumbnailsFolderName, isDirectory: true)
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".jpg")
    }

    /// The downloads in `directory`, newest first. A missing folder is an empty
    /// bin, not an error.
    public static func scan(in directory: URL) -> [MediaItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let found: [(item: MediaItem, modified: Date)] = files.compactMap { url in
            guard let kind = MediaKind(fileExtension: url.pathExtension) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let thumbnail = thumbnailURL(for: url)
            let item = MediaItem(
                fileURL: url,
                kind: kind,
                byteCount: Int64(values?.fileSize ?? 0),
                thumbnailURL: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
            )
            return (item, values?.contentModificationDate ?? .distantPast)
        }
        return found.sorted { $0.modified > $1.modified }.map(\.item)
    }
}
