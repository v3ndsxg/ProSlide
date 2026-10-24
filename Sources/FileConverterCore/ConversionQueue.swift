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

    /// Which of the two card-drag payloads the bin offers.
    ///
    /// Deliberately not a toggle that controls writing: every conversion writes
    /// its deck's bundle as part of the same run, so switching modes is instant
    /// and a drag only ever hands over a file that already exists.
    @Published public var dragMode: DragMode = .presentation

    /// Written bundles, keyed by deck folder path. Filled by a conversion or a
    /// rebuild as it writes them, and at launch from the bundles already on
    /// disk — opening the app never builds one.
    @Published public private(set) var presentations: [String: URL] = [:]

    /// Decks whose presentation could not be written, keyed by deck folder path.
    @Published public private(set) var presentationFailures: [String: String] = [:]

    /// Decks whose bundle a rebuild is writing right now, keyed by folder path.
    @Published public private(set) var presentationsInProgress: Set<String> = []

    /// Where this queue's bin lives. The real one in the app; a temporary folder
    /// in tests. A test that scanned the real bin and then cleared it deleted
    /// the operator's decks, so nothing below reaches for `BinStorage` directly.
    public let binRootURL: URL
    public let binPresentationsURL: URL

    /// The old bin location to bring decks across from, or nil not to look.
    private let legacyBinURL: URL?

    /// The single-file conversion injected by the initialiser. Deliberately
    /// not named `convert`: a stored property and a `convert()` method cannot
    /// share a name in one type.
    private let convertOne: ConvertOperation

    /// Writes one deck's bundle. Injected so the queue's tests never write
    /// into the real bin.
    public typealias PackageOperation = @Sendable (ConversionGroup) throws -> URL
    private let packageOne: PackageOperation

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
    init(
        options: ConversionOptions,
        convert: @escaping ConvertOperation,
        package: PackageOperation? = nil,
        binRoot: URL = BinStorage.rootURL,
        presentationsDirectory: URL = BinStorage.presentationsDirectory,
        legacyBin: URL? = AppIdentity.current.ownsLegacyBin ? BinStorage.legacyRootURL : nil
    ) {
        self.options = options
        self.convertOne = convert
        self.packageOne = package ?? { group in
            try ProPresenterPackage.package(group: group, destinationDirectory: presentationsDirectory)
        }
        self.binRootURL = binRoot
        self.binPresentationsURL = presentationsDirectory
        self.legacyBinURL = legacyBin
    }

    // MARK: - Input

    /// Adds documents to the queue, ignoring anything that is not a PDF,
    /// .pptx or .ppt. Unsupported files are reported together rather than
    /// failing the whole batch.
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
        ConversionEngine.supportedExtensions.contains(url.pathExtension.lowercased())
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

    /// Documents that still need converting: anything not already done.
    ///
    /// A finished document stays in the list for reference but is not converted
    /// again, or adding one file to a completed batch would re-convert all the
    /// others into `… JPEGs 2` duplicates. To convert a finished file again, drop
    /// it again.
    public var pendingCount: Int {
        items.filter { !$0.status.isSucceeded }.count
    }

    /// Runs every document that has not yet succeeded, including earlier failures
    /// and anything a previous run was stopped before reaching. One document
    /// failing never stops the rest.
    public func convert() {
        guard !isConverting, pendingCount > 0 else { return }
        isConverting = true
        progress = 0
        message = nil
        for index in items.indices where !items[index].status.isSucceeded {
            items[index].status = .pending
        }

        let batch = items.filter { !$0.status.isSucceeded }.map(\.id)
        let profile = makeTemporaryProfile()
        temporaryProfile = profile
        let convertOne = self.convertOne

        runTask = Task(priority: .userInitiated) { [weak self] in
            for (offset, id) in batch.enumerated() {
                if Task.isCancelled { break }
                guard let self else { return }
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                let url = self.items[index].url

                self.items[index].status = .converting
                do {
                    let folder = try await convertOne(url, self.options, profile) { [weak self] fraction in
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
                    // The bundle is part of the same run, so by the time the
                    // deck reaches the bin its card is ready to drag. A bundle
                    // that fails is reported on the card; the JPEGs still stand.
                    await self.writePresentation(
                        ConversionGroup(sourceName: folder.lastPathComponent, folderURL: folder)
                    )
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
        let root = binRootURL
        let legacy = legacyBinURL
        Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                // Before the first scan of a fresh bin, bring across anything
                // left in the old Application Support location, where
                // ProPresenter could never read it.
                if let legacy { BinStorage.migrateDecks(from: legacy, to: root) }
                return ConversionQueue.scanBin(at: root)
            }.value
            self?.groups = scanned
            self?.discoverPresentations()
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

    // MARK: - ProPresenter presentations

    /// The payload for dragging a whole document into ProPresenter, or nil when
    /// there is nothing to drag.
    ///
    /// In presentation mode there is deliberately **no** fallback to the JPEG
    /// folder. One existed, and it was harmful: a deck whose presentation could
    /// not be written dragged its JPEG folder instead, which is a different
    /// payload producing a different result in ProPresenter. The two were
    /// indistinguishable from the outside, so a presentation that failed to be written
    /// at all looked exactly like a working drag — and six commits of work on the
    /// writer went untested because of it.
    ///
    /// A drag that does nothing is a legible failure; a drag that silently does
    /// something else is not.
    public func dragPayload(for group: ConversionGroup) -> URL? {
        switch dragMode {
        case .jpegFolder:
            return group.folderURL
        case .presentation:
            return presentation(for: group)
        }
    }

    /// The state of `group`'s card in the current drag mode.
    ///
    /// In JPEG Files mode the images are all that is dragged and they already
    /// exist, so the card is ready whatever became of its presentation. In
    /// presentation mode a deck is ready only once its bundle is written; a stale
    /// failure is ignored when a bundle exists, so a rebuild that worked clears
    /// the chip.
    public func deckStatus(for group: ConversionGroup) -> DeckStatus {
        switch dragMode {
        case .jpegFolder:
            return .ready
        case .presentation:
            if presentationsInProgress.contains(group.id) { return .preparing }
            if presentation(for: group) != nil { return .ready }
            if let reason = presentationFailures[group.id] { return .failed(reason) }
            return .missing
        }
    }

    /// The presentation to drag for `group`, or nil when there isn't one yet.
    public func presentation(for group: ConversionGroup) -> URL? {
        presentations[group.id]
    }

    /// Writes one deck's bundle now, replacing any it already has. The per-card
    /// button calls this, which is also the only way a deck converted before
    /// bundles existed gets one.
    public func buildPresentation(_ group: ConversionGroup) {
        guard !presentationsInProgress.contains(group.id) else { return }
        presentationsInProgress.insert(group.id)
        Task { [weak self] in
            await self?.writePresentation(group)
            self?.presentationsInProgress.remove(group.id)
        }
    }

    /// Writes `group`'s bundle off the main actor and records the outcome.
    private func writePresentation(_ group: ConversionGroup) async {
        let packageOne = self.packageOne
        let result = await Task.detached(priority: .userInitiated) {
            Result { try packageOne(group) }
        }.value
        switch result {
        case .success(let url):
            // Every conversion of one document shares one bundle, so another
            // deck that pointed here now names this deck's slides. It goes back
            // to not built rather than dragging something it did not make.
            for (other, existing) in presentations where existing == url && other != group.id {
                presentations[other] = nil
            }
            presentations[group.id] = url
            presentationFailures[group.id] = nil
        case .failure(let error):
            recordPresentationFailure(Self.message(for: error), for: group)
        }
    }

    /// Records why a deck's presentation could not be written.
    ///
    /// Split out from the write itself so the failure path can be exercised
    /// directly. Provoking a genuine failure — a full disk, or a denied write —
    /// is the only way to prove a failure is *reported* rather than swallowed,
    /// and that cannot be arranged on demand. The silent fallback this now backs
    /// was itself caused by nobody testing it.
    public func recordPresentationFailure(_ message: String, for group: ConversionGroup) {
        presentations[group.id] = nil
        presentationFailures[group.id] = message
    }

    /// Offers every bundle already written for the decks in the bin.
    ///
    /// Reads only: opening the app never builds a bundle. A deck without one
    /// shows as not built until it is converted again or rebuilt, and a
    /// `.partial` left by an interrupted build is never picked up.
    ///
    /// Two conversions of one document share a bundle. It goes to the newest,
    /// `Name JPEGs 2` over `Name JPEGs` — the bin lists newest first — which is
    /// the deck that wrote it unless an older one was rebuilt since.
    private func discoverPresentations() {
        var claimed = Set(presentations.values)
        for group in groups where presentations[group.id] == nil {
            if let url = ProPresenterPackage.existingBundle(for: group, in: binPresentationsURL),
               !claimed.contains(url) {
                presentations[group.id] = url
                claimed.insert(url)
            }
        }
    }

    /// Every deck whose presentation could not be written, with its reason.
    ///
    /// Ordered as the bin shows them, so the bin can report the first failure in
    /// full rather than counting them and leaving the operator to go hunting
    /// through the cards for which one went wrong.
    public var presentationFailureMessages: [(group: ConversionGroup, message: String)] {
        groups.compactMap { group in
            presentationFailures[group.id].map { (group, $0) }
        }
    }

    /// One sentence naming how many decks could not be written and why the first
    /// one could not.
    ///
    /// The reason matters more than the count. "The size of Deck-004.jpg could
    /// not be read" tells the operator what to go and fix; a bare count tells them
    /// only that something is wrong somewhere.
    public var presentationFailureSummary: String {
        let failures = presentationFailureMessages
        guard let first = failures.first else { return "" }
        if failures.count == 1 {
            return "1 deck could not be written: \(first.message) Its card does not drag."
        }
        return "\(failures.count) decks could not be written. The first: \(first.message) Those cards do not drag."
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Copies a deck's JPEGs into a folder the operator chose.
    ///
    /// Only correct in JPEG Files mode. In presentation mode the thing this
    /// saves is not what the card drags, and offering it there is a trap: it sits
    /// directly beside a caption describing a different payload, hands over
    /// something else, and gives no indication which. That is not a subtle
    /// mistake to make — it is the reason a working `.pro` was believed not to
    /// exist for several rounds.
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

    /// Copies a deck's `.probundle` into a folder the operator chose.
    ///
    /// The presentation mode counterpart to `save(group:to:)`: what it writes is
    /// the payload the card drags, not the deck's loose images.
    public func savePresentation(for group: ConversionGroup, to destination: URL) throws {
        guard let source = presentation(for: group) else {
            // Deliberately not falling back to the JPEG folder: see `dragPayload`.
            throw ProPackageError.noPresentation(group.sourceName)
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }

    /// Resets the app to a clean slate: empties the bin (every converted document
    /// and the bundle written for each) and clears the file list on the main page.
    ///
    /// Presentations live in their own folder rather than inside each document's,
    /// so that folder has to go too or Clear would leave them behind. Nothing in
    /// ProPresenter's own folders is touched: what it imported is its own copy.
    ///
    /// The file list is left alone while a batch is running, since those files are
    /// in use; the UI does not offer Clear then.
    ///
    public func clearBin() throws {
        removeAll()
        message = nil
        presentations = [:]
        presentationFailures = [:]
        for folder in groups.map(\.folderURL) {
            try FileManager.default.removeItem(at: folder)
        }
        // `try?`: the folder may never have been created, and failing to clear a
        // bin because of that would be worse than leaving it.
        try? FileManager.default.removeItem(at: binPresentationsURL)
        reloadBin()
    }
}
