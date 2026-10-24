import Foundation

/// A plain-text record of what the download tools were asked to do and what they
/// printed, so a download that stalls can be explained from the file rather than
/// from memory.
///
/// Kept small: when the file passes `maxBytes` the older half is dropped.
public final class DownloadLog: @unchecked Sendable {
    /// `~/Library/Logs/<app name>/downloads.log`
    public static let shared = DownloadLog(fileURL: defaultURL)

    public static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppIdentity.current.displayName, isDirectory: true)
            .appendingPathComponent("downloads.log")
    }

    public let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    /// Longer lines than this are cut. A lookup prints about a megabyte of JSON
    /// on one line, which would swamp the log.
    private static let maxLineLength = 2_000

    public init(fileURL: URL, maxBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    public func note(_ text: String) {
        var line = text
        if line.count > DownloadLog.maxLineLength {
            line = String(line.prefix(DownloadLog.maxLineLength)) + "\u{2026} (\(text.count - DownloadLog.maxLineLength) more characters)"
        }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        lock.lock(); defer { lock.unlock() }
        append(stamped)
    }

    /// Creates the file if it doesn't exist, so there is something to show.
    public func ensureExists() {
        lock.lock(); defer { lock.unlock() }
        prepareFile()
    }

    private func prepareFile() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private func append(_ text: String) {
        prepareFile()
        guard let data = text.data(using: .utf8), let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes, let data = try? Data(contentsOf: fileURL) else { return }
        // Keep the newer half, starting at a line boundary.
        var kept = data.suffix(maxBytes / 2)
        if let newline = kept.firstIndex(of: 10) { kept = kept[kept.index(after: newline)...] }
        try? Data(kept).write(to: fileURL, options: .atomic)
    }
}
