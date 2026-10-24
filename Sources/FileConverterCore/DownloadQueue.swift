import Combine
import Foundation

/// One link on its way into the bin.
public struct DownloadItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case queued
        /// Fraction of the whole download, 0 to 1.
        case downloading(Double)
        case finishing
        case done(URL)
        case failed(String)
    }

    public let id = UUID()
    /// The pasted text this came from, which is how its lookup is found again.
    public let linkID: String
    public let url: URL
    public let format: DownloadFormat
    public let quality: DownloadQuality
    public var title: String
    public var status: Status = .queued

    /// Queued or in progress: shown as a card in the bin until it is a file.
    public var isActive: Bool {
        switch status {
        case .queued, .downloading, .finishing: true
        case .done, .failed: false
        }
    }

    /// For example "MP4 · 1080p" or "MP3".
    public var detail: String {
        format == .mp4 ? "MP4 \u{00B7} \(quality.title)" : "MP3"
    }
}

/// What looking a pasted link up has found so far.
public enum LinkLookup: Equatable, Sendable {
    case looking
    case found(VideoInfo)
    case failed(String)
}

/// The Downloader tab's state: the pasted links, what is known about them, the
/// remembered format and quality, and the downloads running one at a time.
///
/// Like `ConversionQueue`, it takes its work as injected closures so its
/// behaviour is tested without the network or the tools.
@MainActor
public final class DownloadQueue: ObservableObject {
    public typealias LookUp = @Sendable (URL) async throws -> VideoInfo
    public typealias Fetch = @Sendable (
        _ url: URL,
        _ info: VideoInfo,
        _ format: DownloadFormat,
        _ quality: DownloadQuality,
        _ directory: URL,
        _ progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL

    /// What the link box holds. Changing it looks up any new links.
    @Published public var linkText = "" {
        didSet { if linkText != oldValue { lookUpNewLinks() } }
    }
    @Published public private(set) var lookups: [String: LinkLookup] = [:]

    /// Remembered between launches.
    @Published public var format: DownloadFormat {
        didSet { defaults.set(format.rawValue, forKey: Keys.format) }
    }
    @Published public var quality: DownloadQuality {
        didSet { defaults.set(quality.rawValue, forKey: Keys.quality) }
    }

    @Published public private(set) var items: [DownloadItem] = []
    @Published public private(set) var isDownloading = false
    @Published public var message: String?

    /// Whether this Mac can download at all, and if not why.
    public let availability: DownloadAvailability

    /// Called whenever a download finishes, so the bin can show the new file.
    public var onBinChanged: @MainActor () -> Void = {}

    private enum Keys {
        static let format = "downloadFormat"
        static let quality = "downloadQuality"
    }

    private let defaults: UserDefaults
    private let downloadsDirectory: URL
    private let lookUp: LookUp
    private let fetch: Fetch
    private var runTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?

    init(
        availability: DownloadAvailability,
        defaults: UserDefaults,
        downloadsDirectory: URL,
        lookUp: @escaping LookUp,
        fetch: @escaping Fetch
    ) {
        self.availability = availability
        self.defaults = defaults
        self.downloadsDirectory = downloadsDirectory
        self.lookUp = lookUp
        self.fetch = fetch
        format = DownloadFormat(rawValue: defaults.string(forKey: Keys.format) ?? "") ?? .mp4
        quality = DownloadQuality(rawValue: defaults.integer(forKey: Keys.quality)) ?? .standard
    }

    /// The queue the app uses: the packaged tools if this Mac can run them, and
    /// the real downloads folder beside the bin.
    public convenience init(
        availability: DownloadAvailability = DownloadAvailability.current(),
        defaults: UserDefaults = .standard
    ) {
        let directory = BinStorage.downloadsDirectory(besideBin: BinStorage.rootURL)
        if case .available(let tools) = availability {
            let engine = DownloadEngine(tools: tools)
            self.init(
                availability: availability,
                defaults: defaults,
                downloadsDirectory: directory,
                lookUp: { url in try await engine.fetchInfo(for: url) },
                fetch: { url, info, format, quality, directory, progress in
                    try await engine.download(
                        url: url, info: info, format: format, quality: quality,
                        into: directory, progress: progress
                    )
                }
            )
        } else {
            let reason = availability.error ?? .toolsMissing
            self.init(
                availability: availability,
                defaults: defaults,
                downloadsDirectory: directory,
                lookUp: { _ in throw reason },
                fetch: { _, _, _, _, _, _ in throw reason }
            )
        }
    }

    // MARK: - The pasted links

    public var links: [DownloadLink] { DownloadLink.parse(linkText) }

    /// The links that would be downloaded now.
    public var downloadableLinks: [DownloadLink] { links.filter(\.isDownloadable) }

    /// What is known about the pasted links, for greying out qualities.
    public var pastedInfos: [VideoInfo] {
        downloadableLinks.compactMap { link in
            if case .found(let info) = lookups[link.id] { info } else { nil }
        }
    }

    public func isOffered(_ quality: DownloadQuality) -> Bool {
        quality.isOffered(by: pastedInfos)
    }

    /// Looks up each new link, one at a time, so a long paste doesn't open a
    /// dozen connections at once.
    private func lookUpNewLinks() {
        guard availability.error == nil else { return }
        for link in downloadableLinks where lookups[link.id] == nil {
            lookups[link.id] = .looking
        }
        guard lookupTask == nil else { return }
        lookupTask = Task { [weak self] in
            while let self, let next = self.nextLinkToLookUp() {
                guard let url = next.url else {
                    self.lookups[next.id] = .failed("That isn\u{2019}t a web link.")
                    continue
                }
                let result: LinkLookup
                do {
                    result = .found(try await self.lookUp(url))
                } catch is CancellationError {
                    break
                } catch {
                    result = .failed(error.localizedDescription)
                }
                self.lookups[next.id] = result
            }
            self?.lookupTask = nil
        }
    }

    private func nextLinkToLookUp() -> DownloadLink? {
        downloadableLinks.first { lookups[$0.id] == .looking }
    }

    // MARK: - Downloading

    public var activeItems: [DownloadItem] { items.filter(\.isActive) }

    /// Queues every downloadable pasted link and starts downloading them one
    /// after another. A failure is recorded on its item and the rest carry on.
    public func download() {
        guard !isDownloading else { return }
        if let reason = availability.error {
            message = reason.localizedDescription
            return
        }
        let chosen = downloadableLinks
        guard !chosen.isEmpty else { return }
        message = nil

        let known = lookups
        let format = self.format
        let quality = self.quality
        let queued = chosen.compactMap { link -> DownloadItem? in
            guard let url = link.url else { return nil }
            var title = link.text
            if case .found(let info)? = known[link.id] { title = info.title }
            return DownloadItem(linkID: link.id, url: url, format: format, quality: quality, title: title)
        }
        items.append(contentsOf: queued)
        linkText = ""
        isDownloading = true

        let ids = queued.map(\.id)
        let directory = downloadsDirectory
        runTask = Task { [weak self] in
            for id in ids {
                guard let self, !Task.isCancelled else { break }
                await self.run(id, known: known, directory: directory)
            }
            self?.finishRun()
        }
    }

    /// Stops the download in progress and drops everything still waiting.
    public func cancel() {
        runTask?.cancel()
        items.removeAll { $0.isActive }
    }

    /// Removes finished and failed items from the list.
    public func clearFinished() {
        guard !isDownloading else { return }
        items.removeAll { !$0.isActive }
    }

    private func run(_ id: UUID, known: [String: LinkLookup], directory: URL) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .downloading(0) }
        do {
            let info: VideoInfo
            if case .found(let cached)? = known[item.linkID] {
                info = cached
            } else {
                info = try await lookUp(item.url)
            }
            update(id) { $0.title = info.title }
            let file = try await fetch(item.url, info, item.format, item.quality, directory) { [weak self] progress in
                Task { @MainActor in self?.apply(progress, to: id) }
            }
            update(id) { $0.status = .done(file) }
            onBinChanged()
        } catch is CancellationError {
            // Stop already dropped the item.
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    /// Progress arrives from a background task, possibly late, so it only ever
    /// moves an item forward and never revives one that has finished or gone.
    private func apply(_ progress: DownloadProgress, to id: UUID) {
        update(id) { item in
            switch (item.status, progress) {
            case (.downloading(let current), .downloading(let value)):
                item.status = .downloading(max(current, value))
            case (.downloading, .finishing):
                item.status = .finishing
            default:
                break
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func finishRun() {
        isDownloading = false
        runTask = nil
    }
}
