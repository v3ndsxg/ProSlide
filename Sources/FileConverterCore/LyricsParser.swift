import Foundation

/// The kind of song section a label names. It decides the group's colour, the
/// same whatever language the label is written in.
public enum LyricsSectionKind: String, Sendable, CaseIterable {
    case verse
    case preChorus
    case chorus
    case bridge
    case tag
    case intro
    case outro
    case interlude
    case ending
    case vamp
    case turnaround
    /// A label the parser doesn't know, kept as written.
    case other

    /// The group colour, as 0xRRGGBB. These are the church's own ProPresenter
    /// colours: Verse blue, Chorus pink, Pre-Chorus a lighter pink, Bridge
    /// purple, the instrumental sections green, the song's edges yellow, Tag
    /// orange and anything else grey.
    public var color: UInt32 {
        switch self {
        case .verse: 0x2F7BF5
        case .chorus: 0xE8458B
        case .preChorus: 0xF5A3C7
        case .bridge: 0x8E44D9
        case .interlude, .vamp, .turnaround: 0x2EAD4B
        case .intro, .outro, .ending: 0xF2C318
        case .tag: 0xF28A1F
        case .other: 0x8E8E93
        }
    }

    /// How a label of this kind is written in English. Short forms such as `PC`
    /// and English labels in any case come out like this.
    var englishName: String {
        switch self {
        case .verse: "Verse"
        case .preChorus: "Pre-Chorus"
        case .chorus: "Chorus"
        case .bridge: "Bridge"
        case .tag: "Tag"
        case .intro: "Intro"
        case .outro: "Outro"
        case .interlude: "Interlude"
        case .ending: "Ending"
        case .vamp: "Vamp"
        case .turnaround: "Turnaround"
        case .other: ""
        }
    }
}

/// One slide: the lines shown together on screen.
public struct LyricsSlide: Equatable, Sendable {
    public let lines: [String]

    public var text: String { lines.joined(separator: "\n") }
}

/// A labelled section of the song, which becomes a ProPresenter group.
public struct LyricsSection: Equatable, Sendable, Identifiable {
    /// The section's position in the song.
    public let id: Int
    /// The group name, tidied and ending with a colon: "Verse 1:", "Приспів:".
    public let name: String
    public let kind: LyricsSectionKind
    public let slides: [LyricsSlide]
}

/// What the parser made of the pasted lyrics.
public struct ParsedLyrics: Equatable, Sendable {
    public let sections: [LyricsSection]
    /// Found in a footer such as "Words and Music by …" or "A | B" under a CCLI line.
    public let artist: String?
    /// Found in a footer line such as "CCLI Song # 1234567".
    public let ccliNumber: String?
    /// Whether any line was read as a section label.
    public let foundLabels: Bool
    /// Lines that came before the first label and so were left out.
    public let droppedLineCount: Int

    public static let empty = ParsedLyrics(
        sections: [], artist: nil, ccliNumber: nil, foundLabels: false, droppedLineCount: 0
    )

    public var slideCount: Int { sections.reduce(0) { $0 + $1.slides.count } }
}

/// Turns lyrics pasted from Planning Center, SongSelect or a document into
/// labelled sections of slides.
///
/// - A section starts at a label line: `Verse 1`, `VERSE 1:`, `[Verse 1]`,
///   `Verse 1 -`, the short forms `V1`, `C`, `PC` and `B`, and the Ukrainian
///   and Russian labels (Куплет, Приспів, Припев, …). A standalone line of up to
///   three words in `[ ]` or ending with a colon is a label too, of kind `other`.
/// - Lines before the first label are left out.
/// - Each lyric line is cleaned: anything in `( )` or `[ ]` goes, repeat
///   markers (`x2`, `2x`, `×3`, Cyrillic `х2`) go, a hyphen inside a word joins
///   its parts, a spaced dash becomes a space, and every character other than
///   letters, digits, spaces, commas and apostrophes goes. Capitalisation is
///   left exactly as pasted.
/// - A line starting in lowercase joins the line above it, since it was a
///   long line cut in two when it was copied.
/// - Blank lines split slides. A longer block is split evenly into slides of at
///   most `linesPerSlide` lines, so five lines at four per slide are 3 + 2.
/// - A section repeated word for word, or a label repeated with nothing under
///   it, adds no slides. A repeated label with different words is renamed
///   "Chorus 2:".
/// - CCLI and copyright footer lines never reach a slide. They supply the
///   artist and CCLI number when they carry them.
public enum LyricsParser {
    public static let linesPerSlideRange = 1...6
    public static let defaultLinesPerSlide = 4

    public static func parse(_ text: String, linesPerSlide: Int = defaultLinesPerSlide) -> ParsedLyrics {
        let perSlide = min(max(linesPerSlide, linesPerSlideRange.lowerBound), linesPerSlideRange.upperBound)
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var builder = SectionBuilder(linesPerSlide: perSlide)
        var footer = FooterReader()
        var current: Label?
        var blocks: [[String]] = []
        var block: [String] = []
        var foundLabels = false
        var dropped = 0
        var inFooter = false
        var bracketDepth = 0

        func endBlock() {
            if !block.isEmpty { blocks.append(block) }
            block = []
        }
        func endSection() {
            endBlock()
            if let current { builder.add(current, blocks: blocks) }
            blocks = []
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if inFooter {
                footer.read(line, inFooter: true)
                continue
            }
            if FooterReader.isFooterLine(line) {
                footer.read(line, inFooter: current != nil)
                // A footer under the lyrics runs to the end: the author line
                // SongSelect puts under "CCLI Song #" looks like any other line.
                if current != nil { inFooter = true }
                continue
            }
            if line.isEmpty {
                endBlock()
                bracketDepth = 0
                continue
            }
            if let label = Label.read(line) {
                endSection()
                current = label
                foundLabels = true
                bracketDepth = label.openBrackets
                continue
            }
            guard current != nil else {
                dropped += 1
                continue
            }
            let cleaned = clean(line, bracketDepth: &bracketDepth)
            guard !cleaned.isEmpty else { continue }
            // A line starting in lowercase is the end of the one above, cut
            // off by the width of whatever it was copied from: "…за Вселенну" / "всю?".
            if let first = cleaned.first, first.isLowercase, let last = block.indices.last {
                block[last] += " " + cleaned
            } else {
                block.append(cleaned)
            }
        }
        endSection()

        return ParsedLyrics(
            sections: builder.sections,
            artist: footer.artist,
            ccliNumber: footer.ccliNumber,
            foundLabels: foundLabels,
            droppedLineCount: dropped
        )
    }

    // MARK: - Cleaning a lyric line

    /// Cleans one lyric line. `bracketDepth` carries an open `(` or `[` over to
    /// the next line, so a backing part written across two lines goes whole;
    /// a blank line or a label closes it, so a stray `(` can't eat the song.
    static func clean(_ line: String, bracketDepth: inout Int) -> String {
        var kept = ""
        for character in line {
            switch character {
            case "(", "[":
                bracketDepth += 1
            case ")", "]":
                bracketDepth = max(bracketDepth - 1, 0)
            default:
                if bracketDepth == 0 { kept.append(character) }
            }
        }
        var text = kept
        for apostrophe in Self.apostrophes {
            text = text.replacingOccurrences(of: apostrophe, with: "'")
        }
        text = text.replacingMatches(of: Pattern.repeatMarker, with: " ")
        text = text.replacingMatches(of: Pattern.trailingCount, with: "")
        text = text.replacingMatches(of: Pattern.hyphenInWord, with: "")
        text = text.replacingMatches(of: Pattern.dash, with: " ")
        text = text.replacingMatches(of: Pattern.notKept, with: " ")
        text = text.replacingMatches(of: Pattern.strayMark, with: "")
        text = text.replacingMatches(of: Pattern.spaces, with: " ")
        text = text.replacingOccurrences(of: " ,", with: ",")
        text = text.trimmingCharacters(in: .whitespaces)
        // A line left with only commas or apostrophes has no words to show.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return text
    }

    /// Curly quotes, the Ukrainian modifier apostrophe (м'я written мʼя), and
    /// the accents people type for an apostrophe.
    private static let apostrophes = ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{0060}", "\u{00B4}", "\u{2032}"]

    enum Pattern {
        /// `x2`, `X 2`, `2x`, `×3`, the Cyrillic `х2`, and `3р.` or `2 рази`
        /// ("times"), standing apart from any word.
        static let repeatMarker = regex(
            #"(?<![\p{L}\p{N}])(?:[xXхХ×]\s?\d+|\d+\s?(?:[xXхХ×]|р(?:аз[аи]?)?\.?))(?![\p{L}\p{N}])"#
        )
        /// A count after a dash at the end of a line: "The Name above all-3".
        static let trailingCount = regex(#"\s?[-\u2010-\u2015]\s?\d+\s*$"#)
        /// A hyphen between letters: `Hal-le-lu-jah`.
        static let hyphenInWord = regex(#"(?<=[\p{L}\p{M}])[-‐‑](?=\p{L})"#)
        /// Any dash left over, such as one between phrases.
        static let dash = regex(#"[-‐-―]"#)
        /// Everything except letters, their accents, digits, spaces, commas and apostrophes.
        static let notKept = regex(#"[^\p{L}\p{M}\p{N}\s,']"#)
        /// An accent or variation selector left without its letter, such as
        /// the one that follows many emoji.
        static let strayMark = regex(#"(?<![\p{L}\p{M}])\p{M}+"#)
        static let spaces = regex(#"\s+"#)
    }

    // MARK: - Labels

    struct Label: Equatable {
        let name: String
        let kind: LyricsSectionKind
        /// Brackets a note after the label opened and didn't close, as in
        /// `БРІДЖ:3р.(1-тихо(дів.)2-голосніше`. The lyric lines go on removing
        /// text until they close, so a note wrapped onto the next line goes too.
        var openBrackets = 0

        /// The label a line holds, or nil if it is a lyric.
        static func read(_ line: String) -> Label? {
            // A known label, a colon, then a note for the band or singers:
            // "Chorus:2x", "КУПЛЕТ 1:(соло)", "Програш:G". The note is dropped.
            if let colon = line.firstIndex(of: ":") {
                let note = line[line.index(after: colon)...]
                if note.contains(where: { !$0.isWhitespace }), let label = known(String(line[..<colon])) {
                    var opened = 0
                    for character in note {
                        if character == "(" || character == "[" { opened += 1 }
                        if character == ")" || character == "]" { opened = max(opened - 1, 0) }
                    }
                    return Label(name: label.name, kind: label.kind, openBrackets: opened)
                }
            }
            if let label = known(line) { return label }

            // An unknown label: short, alone, and marked as a label by brackets
            // or a colon. A bare word stays a lyric; it could be a real line.
            let bracketed = Pattern.bracketed.matches(line)
            let colon = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t-\u{2013}\u{2014}")).hasSuffix(":")
            let text = stripped(line)
            let words = text.split(separator: " ")
            if (bracketed || colon), !words.isEmpty, words.count <= 3, !text.contains(","), text.contains(where: \.isLetter) {
                return Label(name: tidyCase(text) + ":", kind: .other)
            }
            return nil
        }

        /// The line as a known label, or nil.
        private static func known(_ line: String) -> Label? {
            let text = stripped(line)
            guard !text.isEmpty else { return nil }
            if let groups = Pattern.shortForm.groups(in: text), let kind = shortForms[groups[0]] {
                return Label(name: name(kind.englishName, number: groups[1]), kind: kind)
            }
            // "1 Verse" as well as "Verse 1".
            guard let groups = Pattern.numberAndWord.groups(in: text).map({ [$0[1], $0[0]] })
                ?? Pattern.wordAndNumber.groups(in: text) else { return nil }
            let word = groups[0], number = groups[1]
            let key = word.lowercased().filter { !" -\u{2010}\u{2011}.".contains($0) }
            guard let kind = vocabulary[key] else { return nil }
            let isEnglish = word.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
            let display = isEnglish && kind != .other ? kind.englishName : tidyCase(word)
            return Label(name: name(display, number: number), kind: kind)
        }

        /// The label's words alone: without the brackets around it, a colon or
        /// dash after it, and repeat markers such as "(x2)" or "x2".
        private static func stripped(_ line: String) -> String {
            var text = line.trimmingCharacters(in: .whitespaces)
            if let inside = Pattern.bracketed.firstGroup(in: text) { text = inside }
            while let last = text.last, ":-\u{2013}\u{2014} \t".contains(last) {
                text.removeLast()
            }
            text = text.replacingMatches(of: Pattern.parenthesised, with: " ")
            text = text.replacingMatches(of: LyricsParser.Pattern.repeatMarker, with: " ")
            return text.replacingMatches(of: LyricsParser.Pattern.spaces, with: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        private static func name(_ word: String, number: String) -> String {
            number.isEmpty ? "\(word):" : "\(word) \(number):"
        }

        /// "VERSE" → "Verse", "приспів" → "Приспів". Mixed case is left alone
        /// apart from the first letter.
        static func tidyCase(_ text: String) -> String {
            let hasLetters = text.contains(where: \.isLetter)
            let base = hasLetters && text == text.uppercased() ? text.lowercased() : text
            guard let first = base.first else { return base }
            return first.uppercased() + base.dropFirst()
        }

        private static let shortForms: [String: LyricsSectionKind] = [
            "V": .verse, "C": .chorus, "PC": .preChorus, "B": .bridge,
        ]

        /// Label words, lowercased with spaces, hyphens and dots removed:
        /// English, Ukrainian and Russian.
        static let vocabulary: [String: LyricsSectionKind] = {
            let words: [(LyricsSectionKind, [String])] = [
                (.verse, ["verse", "куплет"]),
                (.preChorus, ["prechorus", "передприспів", "предприспів", "преприспів", "предприпев", "преприпев"]),
                (.chorus, ["chorus", "приспів", "припев"]),
                (.bridge, ["bridge", "бридж", "брідж", "мост", "міст"]),
                (.tag, ["tag", "тег"]),
                (.intro, ["intro", "интро", "інтро", "вступ", "вступление"]),
                (.outro, ["outro", "аутро"]),
                (.interlude, ["interlude", "интерлюдия", "інтерлюдія", "проигрыш", "програш"]),
                (.ending, ["ending", "концовка", "кінцівка", "окончание", "закінчення", "завершение", "завершення"]),
                (.vamp, ["vamp", "вамп"]),
                (.turnaround, ["turnaround"]),
                // Planning Center's own catch-all section.
                (.other, ["misc"]),
            ]
            var vocabulary: [String: LyricsSectionKind] = [:]
            for (kind, list) in words {
                for word in list { vocabulary[word] = kind }
            }
            return vocabulary
        }()

        enum Pattern {
            /// `[Verse 1]`, `[Verse 1]:`, with the inside captured.
            static let bracketed = regex(#"^\[\s*([^\]]+?)\s*\]\s*[:\-–—]?\s*$"#)
            static let parenthesised = regex(#"\([^)]*\)"#)
            /// `V1`, `C`, `PC2`, `B`: capitals only, so a lowercase "c" in a lyric is never a label.
            static let shortForm = regex(#"^(PC|V|C|B)\s?(\d{0,2})$"#)
            /// "Verse 1", "Pre-Chorus", "Куплет 2".
            static let wordAndNumber = regex(#"^(.*?\S)\s*(\d{1,2})?$"#)
            /// "1 Verse", "2 Куплет".
            static let numberAndWord = regex(#"^(\d{1,2})\s*(\D.*)$"#)
        }
    }

    // MARK: - Sections and slides

    /// Collects sections in order, skipping repeats and naming variants.
    struct SectionBuilder {
        let linesPerSlide: Int
        private(set) var sections: [LyricsSection] = []
        /// For each label (lowercased, no colon), the words of every section
        /// that has used it, so a repeat can be recognised.
        private var seen: [String: [[String]]] = [:]

        init(linesPerSlide: Int) {
            self.linesPerSlide = linesPerSlide
        }

        mutating func add(_ label: Label, blocks: [[String]]) {
            // A bare label ("Chorus" with nothing under it) repeats a section,
            // and a label with no lyrics at all ("[Instrumental]") has nothing to show.
            guard !blocks.isEmpty else { return }
            let words = blocks.flatMap { $0 }
            let base = String(label.name.dropLast())
            let key = base.lowercased()
            let earlier = seen[key, default: []]
            if earlier.contains(words) { return }
            seen[key, default: []].append(words)

            var name = label.name
            if !earlier.isEmpty {
                let count = earlier.count + 1
                // "Chorus" → "Chorus 2:", but "Verse 1" → "Verse 1 (2):", so it
                // can't be confused with a real Verse 2.
                let endsInNumber = base.last?.isNumber ?? false
                name = endsInNumber ? "\(base) (\(count)):" : "\(base) \(count):"
            }
            let slides = blocks.flatMap { LyricsParser.slides(from: $0, linesPerSlide: linesPerSlide) }
            sections.append(LyricsSection(id: sections.count, name: name, kind: label.kind, slides: slides))
        }
    }

    /// Splits one block (lines between blank lines) into slides of at most
    /// `linesPerSlide` lines, as evenly as possible: 5 lines at 4 per slide
    /// are 3 + 2, not 4 + 1. In a block that alternates between Cyrillic and
    /// Latin lines, each pair (a line and its translation) stays on one slide.
    static func slides(from block: [String], linesPerSlide: Int) -> [LyricsSlide] {
        let units: [[String]]
        let unitsPerSlide: Int
        if isBilingual(block) {
            units = stride(from: 0, to: block.count, by: 2).map { Array(block[$0...$0 + 1]) }
            unitsPerSlide = max(linesPerSlide / 2, 1)
        } else {
            units = block.map { [$0] }
            unitsPerSlide = max(linesPerSlide, 1)
        }
        guard !units.isEmpty else { return [] }
        let slideCount = (units.count + unitsPerSlide - 1) / unitsPerSlide
        let base = units.count / slideCount
        let extra = units.count % slideCount
        var slides: [LyricsSlide] = []
        var index = 0
        for slide in 0..<slideCount {
            let size = base + (slide < extra ? 1 : 0)
            slides.append(LyricsSlide(lines: units[index..<index + size].flatMap { $0 }))
            index += size
        }
        return slides
    }

    private enum Script { case cyrillic, latin, neither }

    private static func script(of line: String) -> Script {
        var cyrillic = 0, latin = 0
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        if cyrillic > latin { return .cyrillic }
        if latin > cyrillic { return .latin }
        return .neither
    }

    /// Lines that switch script every line, starting from either: a line and
    /// its translation, then the next pair.
    static func isBilingual(_ block: [String]) -> Bool {
        guard block.count >= 2, block.count.isMultiple(of: 2) else { return false }
        let scripts = block.map(script(of:))
        guard !scripts.contains(.neither) else { return false }
        return zip(scripts, scripts.dropFirst()).allSatisfy { $0 != $1 }
    }

    // MARK: - Footer

    /// Reads CCLI and copyright lines for the song's details.
    struct FooterReader {
        private(set) var artist: String?
        private(set) var ccliNumber: String?

        static func isFooterLine(_ line: String) -> Bool {
            Pattern.footer.matches(line)
        }

        /// `inFooter` is true under the lyrics, where a plain line (SongSelect's
        /// "Author A | Author B") is the authors.
        mutating func read(_ line: String, inFooter: Bool) {
            guard !line.isEmpty else { return }
            if Pattern.footer.matches(line) {
                if ccliNumber == nil, !Pattern.licence.matches(line),
                   let groups = Pattern.ccliNumber.groups(in: line) {
                    ccliNumber = groups[0]
                }
                if artist == nil, let groups = Pattern.byLine.groups(in: line) {
                    artist = groups[0].trimmingCharacters(in: .whitespaces)
                }
                return
            }
            guard inFooter, artist == nil, line.contains(where: \.isLetter) else { return }
            artist = line
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        enum Pattern {
            static let footer = regex(
                #"^(?:ccli\b|©|\(c\)|copyright\b|(?:words and music|music and words|words|music|lyrics|written) by\b|for use solely\b|all rights reserved)|www\.ccli\.com|©"#,
                .caseInsensitive
            )
            static let licence = regex(#"licen[cs]e"#, .caseInsensitive)
            static let ccliNumber = regex(#"ccli\s*(?:song)?\s*(?:#|no\.?|number|№)?\s*:?\s*(\d{3,})"#, .caseInsensitive)
            static let byLine = regex(
                #"^(?:words and music|music and words|words|music|lyrics|written) by\s+(.+)$"#,
                .caseInsensitive
            )
        }
    }
}

// MARK: - Regular expressions

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // The patterns are fixed, so a bad one is a programming error caught by the tests.
    try! NSRegularExpression(pattern: pattern, options: options)
}

private extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first capture group of the first match.
    func firstGroup(in text: String) -> String? {
        groups(in: text)?.first
    }

    /// Every capture group of the first match, with "" for a group that didn't take part.
    func groups(in text: String) -> [String]? {
        guard let match = firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(match.numberOfRanges, 1)).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

private extension String {
    func replacingMatches(of regex: NSRegularExpression, with template: String) -> String {
        regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
