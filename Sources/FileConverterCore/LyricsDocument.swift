import Foundation

/// A song ready to become a ProPresenter presentation.
public struct LyricsSong: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var ccliNumber: String
    public var sections: [LyricsSection]
    /// Section ids in the order the lyrics name them, for the arrangement.
    public var order: [Int]

    public init(title: String, artist: String, ccliNumber: String, sections: [LyricsSection], order: [Int]) {
        self.title = title
        self.artist = artist
        self.ccliNumber = ccliNumber
        self.sections = sections
        self.order = order
    }

    public var slideCount: Int { sections.reduce(0) { $0 + $1.slides.count } }
}

/// Builds the `rv.data.Presentation` for a song: one text slide per lyric
/// slide, a group per section, a Blank group first, one arrangement in the
/// pasted order, and the song's CCLI details.
///
/// The slide is copied from a song ProPresenter exported from the church's own
/// library ("Always And Forever", November 2026): one text box filling the
/// 1920×1080 slide, Lato Bold 60 pt, white, centred across and down, with a
/// soft shadow. The words are RTF in the shape Cocoa writes, and the text's
/// custom attributes cover its whole length, in UTF-16 units, as that export's do.
///
/// As with `ProPresenterDocument`, the schema is community-reverse-engineered,
/// so the rule is to write what ProPresenter's own export holds and to change
/// nothing without an import to check against.
///
/// Deliberately absent, though the export has them:
///
/// - Application info (field 1) and the timeline (17), as in `ProPresenterDocument`.
/// - The export's second, hidden "ALT Text" box, which is empty.
/// - Links from a group to the operator's preset groups (group field 5). Those
///   identifiers belong to one Mac's ProPresenter; the colour is written instead.
/// - The CCLI "display" flag (14.7), so the details are stored for reference
///   and reporting but never shown on screen.
enum LyricsDocument {

    // MARK: - Schema constants

    /// `rv.data.Action.ActionType.ACTION_TYPE_PRESENTATION_SLIDE`.
    private static let presentationSlideAction: UInt64 = 11
    /// `rv.data.Cue.CompletionActionType`, as the export has it.
    private static let completionLast: UInt64 = 1
    /// `Graphics.Text.Attributes.Paragraph.Alignment.CENTER`.
    private static let alignCentre: UInt64 = 2
    /// `Graphics.Text.VerticalAlignment.MIDDLE`.
    private static let alignMiddle: UInt64 = 1
    /// `Graphics.Text.ScaleBehavior`, as the export has it.
    private static let scaleDownToFit: UInt64 = 2

    static let canvasWidth = 1920.0
    static let canvasHeight = 1080.0

    static let fontName = "Lato-Bold"
    static let fontFamily = "Lato"
    static let fontSize = 60.0

    static let blankGroupName = "Blank"
    static let arrangementName = "Default"

    // MARK: - Entry point

    /// The manifest for `song`, as a presentation named `name`.
    static func encode(name: String, song: LyricsSong) -> Data {
        var document = ProtoWriter(reservingCapacity: (song.slideCount + 1) * 2048)
        document.message(2) { $0.string(1, newUUID()) }
        document.string(3, name)
        // The export's background is an empty message, and so is its chord
        // chart link apart from naming the Mac platform.
        document.message(8) { _ in }
        document.message(9) { $0.uint(3, 1) }

        // Groups: Blank first, then one per section. Cue identifiers are
        // minted once and shared by each cue and the group that lists it.
        struct Group {
            let uuid = LyricsDocument.newUUID()
            let name: String
            let color: UInt32
            let slides: [[String]]
            var cueUUIDs: [String] = []
        }
        var groups = [Group(name: blankGroupName, color: LyricsSectionKind.other.color, slides: [[]])]
        for section in song.sections {
            groups.append(Group(name: section.name, color: section.kind.color, slides: section.slides.map(\.lines)))
        }
        for index in groups.indices {
            groups[index].cueUUIDs = groups[index].slides.map { _ in newUUID() }
        }

        // One arrangement: Blank, then the sections as the lyrics name them.
        let groupForSection = Dictionary(uniqueKeysWithValues: song.sections.enumerated().map { ($1.id, groups[$0 + 1].uuid) })
        let arranged = [groups[0].uuid] + song.order.compactMap { groupForSection[$0] }
        document.message(11) { arrangement in
            arrangement.message(1) { $0.string(1, newUUID()) }
            arrangement.string(2, arrangementName)
            for uuid in arranged {
                arrangement.message(3) { $0.string(1, uuid) }
            }
        }

        for group in groups {
            document.message(12) { cueGroup in
                cueGroup.message(1) { inner in
                    inner.message(1) { $0.string(1, group.uuid) }
                    inner.string(2, group.name)
                    inner.message(3) { color(&$0, hex: group.color) }
                    inner.message(4) { _ in }
                }
                for cueUUID in group.cueUUIDs {
                    cueGroup.message(2) { $0.string(1, cueUUID) }
                }
            }
        }
        for group in groups {
            for (lines, cueUUID) in zip(group.slides, group.cueUUIDs) {
                document.data(13, cue(lines: lines, uuid: cueUUID))
            }
        }

        document.message(14) { ccli in
            ccli.string(1, song.artist.trimmingCharacters(in: .whitespacesAndNewlines))
            ccli.string(3, song.title.trimmingCharacters(in: .whitespacesAndNewlines))
            if let number = UInt64(song.ccliNumber.filter(\.isNumber)) {
                ccli.uint(6, number)
            }
        }
        return document.data
    }

    // MARK: - Cues

    /// One slide. `lines` is empty for the Blank slide.
    private static func cue(lines: [String], uuid: String) -> Data {
        var cue = ProtoWriter()
        cue.message(1) { $0.string(1, uuid) }
        cue.uint(5, completionLast)
        cue.message(8) { _ in }
        cue.message(10) { action in
            action.message(1) { $0.string(1, newUUID()) }
            action.bool(6, true)  // enabled
            action.uint(9, presentationSlideAction)
            action.message(23) { slideType in
                slideType.message(2) { presentationSlide in
                    presentationSlide.message(1) { baseSlide in
                        baseSlide.message(1) { textBox(&$0, lines: lines) }
                        baseSlide.message(6) { canvas in
                            canvas.double(1, canvasWidth)
                            canvas.double(2, canvasHeight)
                        }
                        baseSlide.message(7) { $0.string(1, newUUID()) }
                    }
                    presentationSlide.message(4) { $0.uint(3, 1) }
                }
            }
        }
        cue.bool(12, true)  // enabled
        return cue.data
    }

    /// `rv.data.Slide.Element`: the "Lyrics" text box filling the slide.
    private static func textBox(_ element: inout ProtoWriter, lines: [String]) {
        element.message(1) { graphics in
            graphics.message(1) { $0.string(1, newUUID()) }
            graphics.string(2, "Lyrics")
            graphics.message(3) { bounds in
                bounds.message(1) { _ in }  // origin 0, 0
                bounds.message(2) { size in
                    size.double(1, canvasWidth)
                    size.double(2, canvasHeight)
                }
            }
            graphics.double(5, 1)  // opacity
            graphics.message(8) { rectangle(&$0) }
            // A fill and stroke as the export has them; neither is switched on.
            graphics.message(9) { fill in
                fill.message(1) { color(&$0, red: 0.11764705926179886, green: 0.5647059082984924, blue: 1) }
            }
            graphics.message(10) { stroke in
                stroke.double(2, 3)
                stroke.message(3) { color(&$0, red: 1, green: 1, blue: 1) }
            }
            graphics.message(11) { shadow(&$0, opacity: 1) }
            graphics.message(12) { $0.double(2, 0.05) }  // feather
            graphics.message(13) { text(&$0, lines: lines) }
            graphics.message(14) { _ in }
        }
        element.uint(4, 3)
        element.message(9) { scroller in
            scroller.double(2, 0.5)
            scroller.uint(3, 1)
            scroller.double(4, 0.051951698960966027)
        }
    }

    /// `Graphics.Text`: the words, as RTF, and how they are drawn.
    private static func text(_ text: inout ProtoWriter, lines: [String]) {
        let length = UInt64(lines.joined(separator: "\n").utf16.count)
        text.message(3) { attributes in
            attributes.message(1) { font(&$0) }
            attributes.uint(2, 1)
            attributes.message(3) { color(&$0, red: 1, green: 1, blue: 1) }
            attributes.message(4) { _ in }
            attributes.message(6) { paragraph in
                paragraph.uint(1, alignCentre)
                paragraph.double(5, 1)  // line height multiple
                paragraph.message(11) { _ in }
                paragraph.double(12, 65)  // default tab interval
                paragraph.message(13) { _ in }
            }
            attributes.double(7, 2)  // kerning
            attributes.message(9) { _ in }
            if length > 0 {
                attributes.message(13) { custom in
                    custom.message(1) { $0.uint(2, length) }
                    custom.uint(2, 1)
                }
                attributes.message(13) { custom in
                    custom.message(1) { $0.uint(2, length) }
                    custom.message(12) { font(&$0) }
                }
            }
        }
        text.message(4) { shadow(&$0, opacity: 0.75) }
        text.data(5, rtf(lines: lines))
        text.uint(6, alignMiddle)
        text.uint(7, scaleDownToFit)
        text.message(8) { margins in
            for side in 1...4 { margins.double(side, 10) }
        }
        text.uint(9, 1)
        text.string(11, "  \u{2022}  ")
        text.message(12) { $0.message(3) { $0.float(4, 1) } }
    }

    // MARK: - RTF

    /// The words as Cocoa writes them: Lato Bold at 60 pt (`\fs120`), white,
    /// centred, one paragraph with a line break (`\` then a newline) between
    /// lines. Anything beyond ASCII is written as `\uN`, so Cyrillic survives
    /// the RTF's Windows-1252 code page.
    static func rtf(lines: [String]) -> Data {
        guard !lines.isEmpty else {
            return Data((
                "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n"
                + "\\cocoatextscaling0\\cocoaplatform0{\\fonttbl}\n"
                + "{\\colortbl;\\red255\\green255\\blue255;}\n"
                + "{\\*\\expandedcolortbl;;}\n"
                + "}"
            ).utf8)
        }
        var rtf = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n"
            + "\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fnil\\fcharset0 \(fontName);}\n"
            + "{\\colortbl;\\red255\\green255\\blue255;\\red255\\green255\\blue255;}\n"
            + "{\\*\\expandedcolortbl;;\\cssrgb\\c100000\\c100000\\c100000;}\n"
            + "\\deftab1300\n"
            + "\\pard\\tx0\\pardeftab1300\\pardirnatural\\qc\\partightenfactor0\n"
            + "\n"
            + "\\f0\\b\\fs\(Int(fontSize * 2)) \\cf2 \\kerning1\\expnd8\\expndtw40\n"
        rtf += lines.map(escape).joined(separator: "\\\n")
        rtf += "}"
        return Data(rtf.utf8)
    }

    private static func escape(_ line: String) -> String {
        var escaped = ""
        for unit in line.utf16 {
            switch unit {
            case 0x5C: escaped += "\\\\"
            case 0x7B: escaped += "\\{"
            case 0x7D: escaped += "\\}"
            case 0x20...0x7E: escaped.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                // RTF's \u takes a signed 16-bit number; \uc0 says no fallback
                // character follows it. The space ends the number and is not text.
                escaped += "\\uc0\\u\(Int16(bitPattern: unit)) "
            }
        }
        return escaped
    }

    // MARK: - Shared fragments

    private static func font(_ font: inout ProtoWriter) {
        font.string(1, fontName)
        font.double(2, fontSize)
        font.bool(8, true)  // bold
        font.string(9, fontFamily)
    }

    private static func shadow(_ shadow: inout ProtoWriter, opacity: Double) {
        shadow.double(2, 315)  // angle
        shadow.double(3, 5)  // offset
        shadow.double(4, 5)  // radius
        shadow.message(5) { $0.float(4, 1) }  // black
        shadow.double(6, opacity)
        shadow.bool(7, true)  // on
    }

    /// The text box's outline: a rectangle through the four corners of the
    /// unit square, each point with its two control points on it.
    private static func rectangle(_ path: inout ProtoWriter) {
        path.uint(1, 1)  // closed
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
            path.message(2) { point in
                for field in 1...3 {
                    point.message(field) { position in
                        position.double(1, x)
                        position.double(2, y)
                    }
                }
            }
        }
        path.message(3) { $0.uint(1, 1) }  // shape: rectangle
    }

    private static func color(_ writer: inout ProtoWriter, hex: UInt32) {
        color(
            &writer,
            red: Float((hex >> 16) & 0xFF) / 255,
            green: Float((hex >> 8) & 0xFF) / 255,
            blue: Float(hex & 0xFF) / 255
        )
    }

    /// `rv.data.Color`, opaque.
    private static func color(_ writer: inout ProtoWriter, red: Float, green: Float, blue: Float) {
        writer.float(1, red)
        writer.float(2, green)
        writer.float(3, blue)
        writer.float(4, 1)
    }

    private static func newUUID() -> String {
        UUID().uuidString.uppercased()
    }
}
