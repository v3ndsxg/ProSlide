import Foundation

/// Writes a song as a `.probundle` into the bin's `Lyrics` folder, and reads
/// what is there back for the bin.
///
/// A lyrics bundle is a zip holding only `<Name>.pro`; text slides have no
/// media. Beside each bundle is a hidden `.<Name>.json` with what its bin card
/// shows, so the bin never has to decode a presentation to draw a card.
public enum LyricsPackage {

    /// What a song's name is changed to when it is taken.
    public struct Saved: Equatable, Sendable {
        public let url: URL
        /// The name the song was saved under.
        public let name: String
        /// Whether `name` differs from the title because the title was taken.
        public let wasRenamed: Bool
    }

    // MARK: - Writing

    /// Writes `song` into `directory` and returns where it went.
    ///
    /// - Parameter takenNames: names already used elsewhere, such as the
    ///   operator's ProPresenter library. A name is taken if it matches one of
    ///   these or a bundle already in `directory`, compared by `foldedName`.
    @discardableResult
    public static func write(_ song: LyricsSong, to directory: URL, takenNames: Set<String> = []) throws -> Saved {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taken = takenNames.union(names(in: directory))
        let title = DownloadFileNames.sanitize(song.title)
        // The sanitiser names an empty title "Download", so an empty artist
        // must not go through it.
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = uniqueName(title: title, artist: artist.isEmpty ? "" : DownloadFileNames.sanitize(artist), taken: taken)

        let manifest = LyricsDocument.encode(name: name, song: song)
        let destination = directory.appendingPathComponent(name).appendingPathExtension(ProPresenterPackage.fileExtension)
        let partial = destination.appendingPathExtension(ProPresenterPackage.partialExtension)
        do {
            try ZipWriter.write([ZipWriter.Entry(name: name + ".pro", source: .data(manifest))], to: partial)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw ProPackageError.writeFailed("The song could not be saved.")
        }

        let card = Card(
            artist: song.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            slideCount: song.slideCount,
            groups: song.sections.map(\.shortName)
        )
        if let data = try? JSONEncoder().encode(card) {
            try? data.write(to: cardURL(for: destination), options: .atomic)
        }
        return Saved(url: destination, name: name, wasRenamed: name != title)
    }

    /// The title if it is free; otherwise "Title (Artist)"; otherwise
    /// "Title (2)", "Title (3)" and so on.
    static func uniqueName(title: String, artist: String, taken: Set<String>) -> String {
        let isTaken = { (name: String) in taken.contains(foldedName(name)) }
        if !isTaken(title) { return title }
        let withArtist = "\(title) (\(artist))"
        if !artist.isEmpty, !isTaken(withArtist) { return withArtist }
        var number = 2
        while isTaken("\(title) (\(number))") { number += 1 }
        return "\(title) (\(number))"
    }

    // MARK: - Names

    /// A name as it is compared: lowercased, spaces tidied, and Cyrillic
    /// letters that look like Latin ones read as Latin, so "На Троні Cлави"
    /// typed with a Latin "C" matches the same title typed in Cyrillic.
    public static func foldedName(_ name: String) -> String {
        var folded = ""
        for character in name.lowercased() {
            folded.append(lookalikes[character] ?? character)
        }
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let lookalikes: [Character: Character] = [
        "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
        "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
    ]

    /// The folded names of the presentations in `directory`: its `.probundle`
    /// and `.pro` files. Only names are read, never the files themselves, and
    /// subfolders are not searched.
    public static func names(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return Set(files.compactMap { url in
            ["pro", ProPresenterPackage.fileExtension].contains(url.pathExtension.lowercased())
                ? foldedName(url.deletingPathExtension().lastPathComponent)
                : nil
        })
    }

    // MARK: - The bin card

    struct Card: Codable, Equatable {
        let artist: String
        let slideCount: Int
        let groups: [String]
    }

    /// `.<Name>.json` beside `<Name>.probundle`. Hidden, so the scan skips it.
    static func cardURL(for bundle: URL) -> URL {
        bundle.deletingLastPathComponent()
            .appendingPathComponent(".\(bundle.deletingPathExtension().lastPathComponent).json")
    }
}

/// A song in the bin: its bundle, and what its card says.
public struct LyricsItem: Identifiable, Equatable, Sendable {
    public let bundleURL: URL
    public let name: String
    public let artist: String
    /// Nil when the card file is missing, so the card shows the name alone.
    public let slideCount: Int?
    /// "V1 C V2 B".
    public let groupSummary: String
    public let modified: Date

    public var id: String { bundleURL.path }

    /// "12 slides · V1 C V2 B".
    public var detail: String {
        var parts: [String] = []
        if let slideCount { parts.append("\(slideCount) slide\(slideCount == 1 ? "" : "s")") }
        if !groupSummary.isEmpty { parts.append(groupSummary) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The songs in `directory`, newest first. A missing folder is an empty one.
    public static func scan(in directory: URL) -> [LyricsItem] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == ProPresenterPackage.fileExtension }
            .map { url in
                let card = (try? Data(contentsOf: LyricsPackage.cardURL(for: url)))
                    .flatMap { try? JSONDecoder().decode(LyricsPackage.Card.self, from: $0) }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return LyricsItem(
                    bundleURL: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    artist: card?.artist ?? "",
                    slideCount: card?.slideCount,
                    groupSummary: card?.groups.joined(separator: " ") ?? "",
                    modified: modified ?? .distantPast
                )
            }
            .sorted { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
    }
}
