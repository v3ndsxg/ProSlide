import Foundation

/// Writes a song as a `.probundle` into the bin's `Lyrics` folder, and reads
/// what is there back for the bin.
///
/// A lyrics bundle is a zip holding only `<Name>.pro`; text slides have no
/// media. Beside each bundle is a hidden `.<Name>.json` with what its bin card
/// shows, so the bin never has to decode a presentation to draw a card.
public enum LyricsPackage {

    /// Where ProPresenter keeps its libraries on a Mac. Every library in it,
    /// and every folder inside those, is checked for a song's title.
    public static var proPresenterLibrariesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ProPresenter/Libraries", isDirectory: true)
    }

    /// What a new song can be called, given the names in the ProPresenter libraries.
    public enum NameCheck: Equatable, Sendable {
        /// The title is free.
        case free(String)
        /// The title is taken, so the song is "Title (Artist)".
        case withArtist(String)
        /// The title is taken and there is no artist to tell the songs apart.
        case needsArtist
        /// The title and "Title (Artist)" are both taken: the song is already there.
        case taken(String)
    }

    /// The title if no library has it, otherwise "Title (Artist)" if that is
    /// free. Names are compared by `foldedName`. Songs are never numbered.
    public static func checkName(title: String, artist: String, libraryNames: Set<String>) -> NameCheck {
        let title = DownloadFileNames.sanitize(title)
        // The sanitiser names an empty string "Download", so an empty artist
        // must not go through it.
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTaken = { (name: String) in libraryNames.contains(foldedName(name)) }
        if !isTaken(title) { return .free(title) }
        guard !artist.isEmpty else { return .needsArtist }
        let withArtist = "\(title) (\(DownloadFileNames.sanitize(artist)))"
        return isTaken(withArtist) ? .taken(withArtist) : .withArtist(withArtist)
    }

    /// What Create Presentation did.
    public enum SaveResult: Equatable, Sendable {
        case saved(Saved)
        /// Nothing was saved: the title is in a library and there is no artist.
        case needsArtist
        /// Nothing was saved: a song with this name is already in a library.
        case alreadyInLibrary(String)
    }

    /// A song written into the bin.
    public struct Saved: Equatable, Sendable {
        public let url: URL
        /// The name the song was saved under.
        public let name: String
        /// Whether the artist was added because a library has the title.
        public let addedArtist: Bool
        /// Whether a song of the same name in the bin was replaced.
        public let replacedInBin: Bool
    }

    // MARK: - Writing

    /// Checks the song's title against `libraryNames` and, if it can be
    /// saved, writes it into `directory`.
    public static func save(_ song: LyricsSong, to directory: URL, libraryNames: Set<String>) throws -> SaveResult {
        switch checkName(title: song.title, artist: song.artist, libraryNames: libraryNames) {
        case .free(let name):
            return .saved(try write(song, as: name, to: directory, addedArtist: false))
        case .withArtist(let name):
            return .saved(try write(song, as: name, to: directory, addedArtist: true))
        case .needsArtist:
            return .needsArtist
        case .taken(let name):
            return .alreadyInLibrary(name)
        }
    }

    /// Writes `song` into `directory` as `name`, replacing a song of the same
    /// name there (compared by `foldedName`): the bin only stages songs on
    /// their way into ProPresenter, so a second Create is a correction.
    @discardableResult
    static func write(_ song: LyricsSong, as name: String, to directory: URL, addedArtist: Bool = false) throws -> Saved {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = LyricsDocument.encode(name: name, song: song)
        let destination = directory.appendingPathComponent(name).appendingPathExtension(ProPresenterPackage.fileExtension)
        let partial = destination.appendingPathExtension(ProPresenterPackage.partialExtension)
        let earlier = bundles(in: directory).filter { foldedName($0.deletingPathExtension().lastPathComponent) == foldedName(name) }
        do {
            try ZipWriter.write([ZipWriter.Entry(name: name + ".pro", source: .data(manifest))], to: partial)
            for bundle in earlier {
                try FileManager.default.removeItem(at: bundle)
                try? FileManager.default.removeItem(at: cardURL(for: bundle))
            }
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
        return Saved(url: destination, name: name, addedArtist: addedArtist, replacedInBin: !earlier.isEmpty)
    }

    private static func bundles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == ProPresenterPackage.fileExtension }
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

    /// The folded names of the presentations (`.pro` and `.probundle`) in
    /// `root` and every folder inside it, or nil if `root` doesn't exist.
    /// Only names are read, never the files themselves.
    public static func libraryNames(in root: URL) -> Set<String>? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let files = FileManager.default.enumerator(
                  at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return nil }
        var names: Set<String> = []
        for case let url as URL in files
        where ["pro", ProPresenterPackage.fileExtension].contains(url.pathExtension.lowercased()) {
            names.insert(foldedName(url.deletingPathExtension().lastPathComponent))
        }
        return names
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
