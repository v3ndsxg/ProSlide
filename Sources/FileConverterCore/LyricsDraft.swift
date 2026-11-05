import Foundation

/// The Lyrics Formatter's working state: the pasted lyrics, the song's details
/// and the slides they make.
///
/// It lives for the whole session rather than inside the tab's view, so
/// switching to the Converter and back keeps what was pasted.
@MainActor
public final class LyricsDraft: ObservableObject {
    @Published public var lyrics: String = "" {
        didSet { reparse() }
    }
    @Published public var title: String = ""
    @Published public var artist: String = ""
    @Published public var ccliNumber: String = ""
    /// Remembered between launches.
    @Published public var linesPerSlide: Int {
        didSet {
            defaults.set(linesPerSlide, forKey: Keys.linesPerSlide)
            reparse()
        }
    }
    @Published public private(set) var parsed: ParsedLyrics = .empty

    private enum Keys {
        static let linesPerSlide = "lyricsLinesPerSlide"
    }

    private let defaults: UserDefaults
    /// The footer values last copied into the fields. A value is copied only
    /// when it changes, so clearing a field you didn't want filled keeps it clear.
    private var footerArtist: String?
    private var footerCCLI: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Keys.linesPerSlide)
        linesPerSlide = LyricsParser.linesPerSlideRange.contains(stored) ? stored : LyricsParser.defaultLinesPerSlide
    }

    /// Whether there is enough to make a presentation: a title and at least one slide.
    public var isReady: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.slideCount > 0
    }

    /// Lyrics were pasted, but no line was read as a section label, so there are no slides.
    public var isMissingLabels: Bool {
        !parsed.foundLabels && !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Empties the lyrics and the song's details. The bin isn't touched.
    public func clear() {
        lyrics = ""
        title = ""
        artist = ""
        ccliNumber = ""
        footerArtist = nil
        footerCCLI = nil
    }

    private func reparse() {
        parsed = LyricsParser.parse(lyrics, linesPerSlide: linesPerSlide)
        // A footer fills in the details, but never over something typed.
        if let found = parsed.artist, found != footerArtist {
            footerArtist = found
            if artist.trimmingCharacters(in: .whitespaces).isEmpty { artist = found }
        }
        if let found = parsed.ccliNumber, found != footerCCLI {
            footerCCLI = found
            if ccliNumber.trimmingCharacters(in: .whitespaces).isEmpty { ccliNumber = found }
        }
    }
}
