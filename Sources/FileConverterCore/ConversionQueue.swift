import Combine
import Foundation

/// Owns the list of documents to convert and drives them one at a time.
///
/// This lives in the engine library rather than the app target so the batch
/// behaviour — ordering, per-file error isolation, aggregate progress and
/// security-scoped resource lifetimes — is covered by `swift test` and CI.
/// Nothing here touches AppKit or SwiftUI.
@MainActor
public final class ConversionQueue: ObservableObject {

    /// Converts one document and returns the folder of JPEGs it produced.
    ///
    /// - Parameters:
    ///   - profileDirectory: a LibreOffice profile to reuse for this call, or
    ///     nil to let the engine make an isolated one. The queue passes the
    ///     same profile to every file in a run.
    ///   - progress: fraction of the *current* file, from 0 to 1.
    public typealias ConvertOperation = @Sendable (
        _ input: URL,
        _ options: ConversionOptions,
        _ profileDirectory: URL?,
        _ progress: @Sendable (Double) -> Void
    ) async throws -> URL

    @Published public var options: ConversionOptions
    @Published public private(set) var items: [ConversionQueueItem] = []
    @Published public private(set) var groups: [ConversionGroup] = []
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var isConverting = false
    @Published public var message: String?

    public var binRootURL: URL { BinStorage.rootURL }

    private let convert: ConvertOperation
    private var runTask: Task<Void, Never>?
    private var temporaryProfile: URL?

    /// Which security scope was taken for each item, so it is released
    /// exactly once. A `fileImporter` URL is only readable while its scope is
    /// held, which is why scopes are taken when the file is accepted rather
    /// than when Convert is pressed.
    private var scoped: [UUID: (url: URL, tookScope: Bool)] = [:]

    /// Counted so tests can assert scopes are balanced; not part of the UI.
    private(set) var scopesStarted = 0
    private(set) var scopesStopped = 0

    public convenience init(options: ConversionOptions = ConversionOptions()) {
        self.init(options: options, convert: { input, options, profileDirectory, progress in
            try await ConversionEngine().convert(
                input: input,
                options: options,
                profileDirectory: profileDirectory
            ) { value in
                progress(value)
            }
        })
    }
    init(options: ConversionOptions, convert: @escaping ConvertOperation) {
        self.options = options
        self.convert = convert
    }

    // MARK: - Input

    /// Adds documents to the queue, ignoring anything that is not a PDF or
    /// .pptx. Unsupported files are reported together rather than failing the
    /// whole batch.
    public func accept(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var rejected: [String] = []
        for url in urls {
            guard ConversionQueue.isSupported(url) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            if let existing = items.firstIndex(where: { $0.url == url }) {
                items[existing].status = .pending
                // A previous run released the scope, so a file dropped a second
                // time has to claim it again or it would be unreadable.
                takeScope(for: items[existing])
                continue
            }
            let item = ConversionQueueItem(url: url)
            takeScope(for: item)
            items.append(item)
        }

        // NSItemProvider does not preserve the order files were dropped in, so
        // sort by name to make a batch predictable and repeatable. The skipped
        // names are sorted for the same reason: the message should not depend
        // on the order the provider happened to hand them over.
        items.sort {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
        rejected.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        if !isConverting { progress = 0 }
        message = rejected.isEmpty
            ? nil
            : "Skipped \(rejected.count) unsupported file\(rejected.count == 1 ? "" : "s"): \(rejected.joined(separator: ", "))"
    }

    public func removeAll() {
        guard !isConverting else { return }
        for id in Array(scoped.keys) { releaseScope(for: id) }
        items.removeAll()
        progress = 0
        message = nil
    }

    public static func isSupported(_ url: URL) -> Bool {
        ["pdf", "pptx"].contains(url.pathExtension.lowercased())
    }

    /// Folds a converter's progress within the current file into overall batch
    /// progress. Pure so the arithmetic can be asserted directly instead of
    /// racing the published property from a background task.
    nonisolated static func aggregateProgress(offset: Int, fraction: Double, total: Int) -> Double {
        guard total > 0 else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        return (Double(offset) + clamped) / Double(total)
    }

    // MARK: - Conversion

    /// Re-queues every document and runs the batch. One document failing never
    /// stops the rest.
    public func convert() {
        guard !isConverting, !items.isEmpty else { return }
        isConverting = true
        progress = 0
        message = nil
        for index in items.indices {
            items[index].status = .pending
        }

        let batch = items.map(\.id)
        let profile = makeTemporaryProfile()
        temporaryProfile = profile
        let convert = self.convert

        runTask = Task(priority: .userInitiated) { [weak self] in
            for (offset, id) in batch.enumerated() {
                if Task.isCancelled { break }
                guard let self else { return }
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                let url = self.items[index].url

                self.items[index].status = .converting
                do {
                    let folder = try await convert(url, self.options, profile) { [weak self] fraction in
                        let value = ConversionQueue.aggregateProgress(
                            offset: offset, fraction: fraction, total: batch.count
                        )
                        Task { @MainActor in
                            // A late callback from a finished or cancelled run
                            // must not drag the bar backwards.
                            guard let self, self.isConverting else { return }
                            self.progress = value
                        }
                    }
                    // `accept` may re-sort `items` while this file was in
                    // flight, so look the row up again rather than trusting the
                    // index captured above.
                    if let current = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[current].status = .succeeded(folder: folder)
                    }
                } catch {
                    if let current = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[current].status = Task.isCancelled
                            ? .pending
                            : .failed(error.localizedDescription)
                    }
                }
                self.releaseScope(for: id)
                self.progress = ConversionQueue.aggregateProgress(
                    offset: offset + 1, fraction: 0, total: batch.count
                )
            }

            guard let self else { return }
            self.finishRun()
        }
    }

    public func cancel() {
        runTask?.cancel()
    }

    private func finishRun() {
        for id in Array(scoped.keys) { releaseScope(for: id) }
        if let temporaryProfile {
            try? FileManager.default.removeItem(at: temporaryProfile)
            self.temporaryProfile = nil
        }
        isConverting = false
        runTask = nil
        reloadBin()
    }

    /// One profile for the whole run. LibreOffice pays a real cost to create a
    /// user profile, so reusing it makes a multi-PPTX batch noticeably faster.
    private func makeTemporaryProfile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSlide-Profile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func releaseScope(for id: UUID) {
        guard let entry = scoped.removeValue(forKey: id), entry.tookScope else { return }
        entry.url.stopAccessingSecurityScopedResource()
        scopesStopped += 1
    }

    /// Claims the item's read scope once, so repeated drops of the same file
    /// cannot leak a second scope.
    private func takeScope(for item: ConversionQueueItem) {
        guard scoped[item.id] == nil else { return }
        let tookScope = item.url.startAccessingSecurityScopedResource()
        scoped[item.id] = (item.url, tookScope)
        if tookScope { scopesStarted += 1 }
    }

    // MARK: - Bin

    /// Scans the bin off the main actor and publishes the result, so a large
    /// bin cannot stall the window while it opens.
    public func reloadBin() {
        let root = BinStorage.rootURL
        Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                ConversionQueue.scanBin(at: root)
            }.value
            self?.groups = scanned
        }
    }

    nonisolated static func scanBin(at root: URL) -> [ConversionGroup] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending } ?? []
        return folders.compactMap { folder in
            guard !ConversionGroup.exportedImages(in: folder).isEmpty else { return nil }
            return ConversionGroup(sourceName: folder.lastPathComponent, folderURL: folder)
        }
    }

    public func save(group: ConversionGroup, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for image in group.imageURLs {
            let target = destination.appendingPathComponent(image.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: image, to: target)
        }
    }

    public func clearBin() throws {
        for folder in groups.map(\.folderURL) {
            try FileManager.default.removeItem(at: folder)
        }
        reloadBin()
    }
}
