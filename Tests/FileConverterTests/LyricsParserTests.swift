@testable import FileConverterCore
import XCTest

/// The lyrics here are made up for the tests. Real songs are copyrighted and
/// stay out of the repository; these only copy the shapes real pastes have.
final class LyricsParserTests: XCTestCase {

    private func label(_ line: String) -> LyricsParser.Label? {
        LyricsParser.Label.read(line)
    }

    private func clean(_ line: String) -> String {
        var depth = 0
        return LyricsParser.clean(line, bracketDepth: &depth)
    }

    private func lines(_ parsed: ParsedLyrics) -> [[[String]]] {
        parsed.sections.map { $0.slides.map(\.lines) }
    }

    // MARK: - Labels

    func testEnglishLabelsInEveryFormBecomeTidyGroupNames() {
        let cases: [(String, String, LyricsSectionKind)] = [
            ("Verse 1", "Verse 1:", .verse),
            ("VERSE 1:", "Verse 1:", .verse),
            ("[Verse 1]", "Verse 1:", .verse),
            ("[Verse 1]:", "Verse 1:", .verse),
            ("Verse 1 -", "Verse 1:", .verse),
            ("verse 2", "Verse 2:", .verse),
            ("Verse", "Verse:", .verse),
            ("Chorus", "Chorus:", .chorus),
            ("Pre-Chorus", "Pre-Chorus:", .preChorus),
            ("PreChorus", "Pre-Chorus:", .preChorus),
            ("Pre Chorus 2", "Pre-Chorus 2:", .preChorus),
            ("Bridge", "Bridge:", .bridge),
            ("Tag:", "Tag:", .tag),
            ("Intro", "Intro:", .intro),
            ("Outro", "Outro:", .outro),
            ("Interlude", "Interlude:", .interlude),
            ("Ending", "Ending:", .ending),
            ("Vamp", "Vamp:", .vamp),
            ("Turnaround", "Turnaround:", .turnaround),
            ("Chorus x2", "Chorus:", .chorus),
            ("Chorus (x2)", "Chorus:", .chorus),
        ]
        for (line, name, kind) in cases {
            XCTAssertEqual(label(line), LyricsParser.Label(name: name, kind: kind), line)
        }
    }

    func testShortFormsExpandToEnglish() {
        XCTAssertEqual(label("V1"), LyricsParser.Label(name: "Verse 1:", kind: .verse))
        XCTAssertEqual(label("C"), LyricsParser.Label(name: "Chorus:", kind: .chorus))
        XCTAssertEqual(label("PC"), LyricsParser.Label(name: "Pre-Chorus:", kind: .preChorus))
        XCTAssertEqual(label("B"), LyricsParser.Label(name: "Bridge:", kind: .bridge))
        XCTAssertEqual(label("C2"), LyricsParser.Label(name: "Chorus 2:", kind: .chorus))
    }

    func testUkrainianAndRussianLabelsKeepTheirOwnWords() {
        let cases: [(String, String, LyricsSectionKind)] = [
            ("Куплет 1", "Куплет 1:", .verse),
            ("КУПЛЕТ 2:", "Куплет 2:", .verse),
            ("Приспів", "Приспів:", .chorus),
            ("[Припев]", "Припев:", .chorus),
            ("Передприспів", "Передприспів:", .preChorus),
            ("Предприпев:", "Предприпев:", .preChorus),
            ("Бридж", "Бридж:", .bridge),
            ("Міст", "Міст:", .bridge),
            ("Кінцівка", "Кінцівка:", .ending),
            ("Концовка", "Концовка:", .ending),
        ]
        for (line, name, kind) in cases {
            XCTAssertEqual(label(line), LyricsParser.Label(name: name, kind: kind), line)
        }
    }

    func testANumberBeforeTheWordIsReadToo() {
        XCTAssertEqual(label("1 Verse:"), LyricsParser.Label(name: "Verse 1:", kind: .verse))
        XCTAssertEqual(label("2 Verse"), LyricsParser.Label(name: "Verse 2:", kind: .verse))
        XCTAssertEqual(label("1 Куплет"), LyricsParser.Label(name: "Куплет 1:", kind: .verse))
        XCTAssertNil(label("23 sings in me"))
    }

    /// Planning Center charts put notes for the band after the label's colon.
    func testNotesAfterALabelsColonAreDropped() {
        let cases: [(String, String, LyricsSectionKind)] = [
            ("Chorus:1х", "Chorus:", .chorus),
            ("Chorus:2x", "Chorus:", .chorus),
            ("Chorus: 2x", "Chorus:", .chorus),
            ("Програш:G", "Програш:", .interlude),
            ("КУПЛЕТ 1:(соло)", "Куплет 1:", .verse),
            ("ПРИСПІВ:(разом тихо)", "Приспів:", .chorus),
            ("БРІДЖ:3р. (1,2-голосно 3-тихо)", "Брідж:", .bridge),
        ]
        for (line, name, kind) in cases {
            XCTAssertEqual(label(line), LyricsParser.Label(name: name, kind: kind), line)
        }
        XCTAssertEqual(label("БРІДЖ:3р.(1-тихо(дів.)2-голосніше")?.openBrackets, 1)
    }

    func testMiscIsAGreyGroup() {
        XCTAssertEqual(label("Misc 1"), LyricsParser.Label(name: "Misc 1:", kind: .other))
        XCTAssertEqual(label("MISC"), LyricsParser.Label(name: "Misc:", kind: .other))
    }

    func testUnknownLabelsAreGreyAndNamedAsWritten() {
        XCTAssertEqual(label("[Hook]"), LyricsParser.Label(name: "Hook:", kind: .other))
        XCTAssertEqual(label("[SPONTANEOUS]"), LyricsParser.Label(name: "Spontaneous:", kind: .other))
        XCTAssertEqual(label("Spontaneous Worship:"), LyricsParser.Label(name: "Spontaneous Worship:", kind: .other))
    }

    func testLyricLinesAreNotMistakenForLabels() {
        for line in [
            "Instrumental",  // a bare unknown word could be a real one-word line
            "Lift up your eyes",
            "c",  // short forms are capitals only
            "Verse of my heart",
            "Holy, holy, holy:",  // commas mean words, not a label
            "We will sing your praise:",  // more than three words
        ] {
            XCTAssertNil(label(line), line)
        }
    }

    // MARK: - Cleaning

    func testParenthesesAndTheirContentsGo() {
        XCTAssertEqual(clean("Hallelujah (hallelujah)"), "Hallelujah")
        XCTAssertEqual(clean("(Oh oh oh)"), "")
        XCTAssertEqual(clean("Shine [softly] on us"), "Shine on us")
    }

    func testABackingPartAcrossTwoLinesGoesWhole() {
        var depth = 0
        XCTAssertEqual(LyricsParser.clean("Sing (oh", bracketDepth: &depth), "Sing")
        XCTAssertEqual(LyricsParser.clean("my soul) forever", bracketDepth: &depth), "forever")
        XCTAssertEqual(depth, 0)
    }

    func testRepeatMarkersGoInEveryForm() {
        XCTAssertEqual(clean("Holy is the Lord x2"), "Holy is the Lord")
        XCTAssertEqual(clean("Holy is the Lord X 3"), "Holy is the Lord")
        XCTAssertEqual(clean("Holy is the Lord 2x"), "Holy is the Lord")
        XCTAssertEqual(clean("Holy is the Lord ×4"), "Holy is the Lord")
        XCTAssertEqual(clean("Свят Господь х2"), "Свят Господь")  // Cyrillic х
        XCTAssertEqual(clean("x2"), "")
        XCTAssertEqual(clean("Psalm 23 sings in me"), "Psalm 23 sings in me")
        XCTAssertEqual(clean("Glory to the King-3"), "Glory to the King")
        XCTAssertEqual(clean("Слава Царю!-2х"), "Слава Царю")
        XCTAssertEqual(clean("Співай 3р."), "Співай")
        XCTAssertEqual(clean("Співай 2 рази"), "Співай")
        XCTAssertEqual(clean("Співай радісно"), "Співай радісно")
    }

    func testSpacesBeforeCommasAndCommaOnlyLinesAreTidied() {
        XCTAssertEqual(clean("Світло моє , Ти що в серці ,"), "Світло моє, Ти що в серці,")
        XCTAssertEqual(clean(","), "")
    }

    func testHyphensJoinWordsAndDashesBecomeSpaces() {
        XCTAssertEqual(clean("Hal-le-lu-jah"), "Hallelujah")
        XCTAssertEqual(clean("ever-lasting love"), "everlasting love")
        XCTAssertEqual(clean("Jesus - my Lord"), "Jesus my Lord")
        XCTAssertEqual(clean("Jesus\u{2014}my Lord"), "Jesus my Lord")
        XCTAssertEqual(clean("- Rise up"), "Rise up")
    }

    func testPunctuationGoesButCommasAndApostrophesStay() {
        XCTAssertEqual(clean("Who is like You? No one!"), "Who is like You No one")
        XCTAssertEqual(clean("Wait. Rest: here; now \"always\""), "Wait Rest here now always")
        XCTAssertEqual(clean("Lord, You are good"), "Lord, You are good")
        XCTAssertEqual(clean("Joy & peace / hope"), "Joy peace hope")
        XCTAssertEqual(clean("I can\u{2019}t stop"), "I can't stop")
        XCTAssertEqual(clean("Shine \u{2600}\u{FE0F} on \u{1F64C}"), "Shine on")
    }

    func testUkrainianAndRussianLettersAndApostrophesStay() {
        XCTAssertEqual(clean("Твоя любов безмежна"), "Твоя любов безмежна")
        XCTAssertEqual(clean("Слава Тебе, Боже!"), "Слава Тебе, Боже")
        XCTAssertEqual(clean("Твоє ім\u{02BC}я"), "Твоє ім'я")
        XCTAssertEqual(clean("Твоє ім'я"), "Твоє ім'я")
        XCTAssertEqual(clean("Ты мой Спаситель"), "Ты мой Спаситель")
    }

    func testCapitalisationIsLeftAsPasted() {
        XCTAssertEqual(clean("LORD of all"), "LORD of all")
        XCTAssertEqual(clean("lowercase line"), "lowercase line")
    }

    // MARK: - Sections and slides

    func testLabelsStartSectionsAndTheirLyricsBecomeSlides() {
        let parsed = LyricsParser.parse("""
        Verse 1
        Morning breaks across the hills
        Every shadow runs away
        Light is pouring through the windows
        Here begins a brand new day

        Chorus
        Sing it out, sing it out
        Let the whole world hear
        """)
        XCTAssertTrue(parsed.foundLabels)
        XCTAssertEqual(parsed.sections.map(\.name), ["Verse 1:", "Chorus:"])
        XCTAssertEqual(parsed.sections.map(\.kind), [.verse, .chorus])
        XCTAssertEqual(lines(parsed), [
            [["Morning breaks across the hills", "Every shadow runs away",
              "Light is pouring through the windows", "Here begins a brand new day"]],
            [["Sing it out, sing it out", "Let the whole world hear"]],
        ])
        XCTAssertEqual(parsed.slideCount, 2)
    }

    func testLongBlocksSplitEvenly() {
        let verse = "Verse 1\none\ntwo\nthree\nfour\nfive"
        XCTAssertEqual(lines(LyricsParser.parse(verse, linesPerSlide: 4)), [[["one", "two", "three"], ["four", "five"]]])
        XCTAssertEqual(lines(LyricsParser.parse(verse, linesPerSlide: 2)), [[["one", "two"], ["three", "four"], ["five"]]])
        XCTAssertEqual(lines(LyricsParser.parse(verse, linesPerSlide: 1)), [[["one"], ["two"], ["three"], ["four"], ["five"]]])
        let nine = "Verse 1\n" + (1...9).map(String.init).joined(separator: "\n")
        XCTAssertEqual(LyricsParser.parse(nine, linesPerSlide: 4).sections[0].slides.map(\.lines.count), [3, 3, 3])
    }

    func testBlankLinesSplitSlidesWithinASection() {
        let parsed = LyricsParser.parse("Verse 1\none\ntwo\n\nthree\nfour", linesPerSlide: 4)
        XCTAssertEqual(lines(parsed), [[["one", "two"], ["three", "four"]]])
    }

    func testLinesPerSlideIsKeptInRange() {
        let verse = "Verse 1\none\ntwo"
        XCTAssertEqual(lines(LyricsParser.parse(verse, linesPerSlide: 0)), [[["one"], ["two"]]])
        XCTAssertEqual(lines(LyricsParser.parse(verse, linesPerSlide: 99)), [[["one", "two"]]])
    }

    func testLinesBeforeTheFirstLabelAreLeftOut() {
        let parsed = LyricsParser.parse("Morning Song\nKey: G\n\nVerse 1\nMorning breaks")
        XCTAssertEqual(parsed.droppedLineCount, 2)
        XCTAssertEqual(lines(parsed), [[["Morning breaks"]]])
    }

    func testLyricsWithNoLabelsMakeNoSlides() {
        let parsed = LyricsParser.parse("Just some words\nMore words")
        XCTAssertFalse(parsed.foundLabels)
        XCTAssertTrue(parsed.sections.isEmpty)
        XCTAssertEqual(parsed.droppedLineCount, 2)
    }

    func testABackingPartAcrossLinesInASong() {
        let parsed = LyricsParser.parse("""
        Verse 1
        We lift our voices (lift them high
        higher still)
        And sing
        """)
        XCTAssertEqual(lines(parsed), [[["We lift our voices", "And sing"]]])
    }

    func testRepeatsAddNoSlidesAndDifferentWordsAreNumbered() {
        let parsed = LyricsParser.parse("""
        Chorus
        Sing it out
        Let the whole world hear

        Verse 2
        Second verse line

        Chorus

        Chorus
        Sing it out
        Let the whole world hear

        Chorus
        Sing it louder
        Let the heavens hear

        Verse 2
        A different second verse
        """)
        XCTAssertEqual(parsed.sections.map(\.name), ["Chorus:", "Verse 2:", "Chorus 2:", "Verse 2 (2):"])
        XCTAssertEqual(parsed.sections.map(\.id), [0, 1, 2, 3])
    }

    /// The shape of a Ukrainian chart from Planning Center, with made-up words.
    func testAPlanningCenterChartWithNotesAndBareRepeats() {
        let parsed = LyricsParser.parse("""
        1 Verse:
        Світло моє , Ти що в серці ,
        Сила моя .
        Prechorus:
        Ти ведеш мене
        Chorus:1х
        Співаю Тобі , Співаю завжди
        ,
        ПРОГРАШ
        2 Verse:
        Голос мій для Тебе
        Prechorus:
        Chorus:2x
        Програш:
        БРІДЖ:3р.(1-тихо(дів.)2-голосніше
        3-голосно)
        Хай світло сяє!
        ПРОГРАШ:
        БРІДЖ:3р. (1,2-голосно 3-тихо)
        """)
        XCTAssertEqual(parsed.sections.map(\.name), ["Verse 1:", "Pre-Chorus:", "Chorus:", "Verse 2:", "Брідж:"])
        XCTAssertEqual(lines(parsed), [
            [["Світло моє, Ти що в серці,", "Сила моя"]],
            [["Ти ведеш мене"]],
            [["Співаю Тобі, Співаю завжди"]],
            [["Голос мій для Тебе"]],
            [["Хай світло сяє"]],
        ])
    }

    func testALabelWithNothingUnderItAddsNoGroup() {
        let parsed = LyricsParser.parse("[Instrumental]\n\nVerse 1\nMorning breaks")
        XCTAssertEqual(parsed.sections.map(\.name), ["Verse 1:"])
    }

    func testBilingualPairsStayOnOneSlide() {
        let verse = """
        Verse 1
        Ти мій Бог
        You are my God
        Ти мій Цар
        You are my King
        Ти мій Спас
        You are my Savior
        """
        XCTAssertEqual(lines(LyricsParser.parse(verse, linesPerSlide: 4)), [[
            ["Ти мій Бог", "You are my God", "Ти мій Цар", "You are my King"],
            ["Ти мій Спас", "You are my Savior"],
        ]])
        XCTAssertEqual(LyricsParser.parse(verse, linesPerSlide: 1).sections[0].slides.map(\.lines.count), [2, 2, 2])
        XCTAssertFalse(LyricsParser.isBilingual(["Ти мій Бог", "Ти мій Цар"]))
        XCTAssertFalse(LyricsParser.isBilingual(["Ти мій Бог", "You are my God", "Ти мій Цар"]))
    }

    // MARK: - Footer

    func testASongSelectFooterGivesTheDetailsAndNoSlides() {
        let parsed = LyricsParser.parse("""
        Verse 1
        Morning breaks across the hills

        CCLI Song # 1234567
        Jane Doe | John Smith
        © 2020 Example Music Publishing
        For use solely with the SongSelect® Terms of Use. All rights reserved. www.ccli.com
        CCLI License # 7654321
        """)
        XCTAssertEqual(parsed.ccliNumber, "1234567")
        XCTAssertEqual(parsed.artist, "Jane Doe, John Smith")
        XCTAssertEqual(lines(parsed), [[["Morning breaks across the hills"]]])
    }

    func testAWordsAndMusicFooter() {
        let parsed = LyricsParser.parse("""
        Chorus
        Holy holy
        Words and Music by Jane Doe
        © 2019 Example Songs
        CCLI Song No. 2345678
        """)
        XCTAssertEqual(parsed.artist, "Jane Doe")
        XCTAssertEqual(parsed.ccliNumber, "2345678")
        XCTAssertEqual(lines(parsed), [[["Holy holy"]]])
    }

    func testALicenceNumberIsNotTheSongNumber() {
        let parsed = LyricsParser.parse("Verse 1\nMorning breaks\nCCLI License # 999999")
        XCTAssertNil(parsed.ccliNumber)
        XCTAssertEqual(lines(parsed), [[["Morning breaks"]]])
    }

    // MARK: - Colours

    func testGroupColoursFollowTheKind() {
        XCTAssertEqual(LyricsSectionKind.interlude.color, LyricsSectionKind.vamp.color)
        XCTAssertEqual(LyricsSectionKind.vamp.color, LyricsSectionKind.turnaround.color)
        XCTAssertEqual(LyricsSectionKind.intro.color, LyricsSectionKind.outro.color)
        XCTAssertEqual(LyricsSectionKind.outro.color, LyricsSectionKind.ending.color)
        XCTAssertNotEqual(LyricsSectionKind.preChorus.color, LyricsSectionKind.chorus.color)
        XCTAssertEqual(LyricsSectionKind.other.color, 0x8E8E93)
        let distinct: [LyricsSectionKind] = [.verse, .chorus, .preChorus, .bridge, .interlude, .intro, .tag, .other]
        XCTAssertEqual(Set(distinct.map(\.color)).count, distinct.count)
    }

    func testAUkrainianChorusIsColouredLikeAChorus() {
        let parsed = LyricsParser.parse("Приспів\nСлава Тобі")
        XCTAssertEqual(parsed.sections.first?.kind.color, LyricsSectionKind.chorus.color)
    }
}

@MainActor
final class LyricsDraftTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let name = "LyricsDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let footerLyrics = """
    Verse 1
    Morning breaks across the hills
    CCLI Song # 1234567
    Jane Doe | John Smith
    """

    func testLinesPerSlideDefaultsToFourAndIsRemembered() throws {
        let defaults = try makeDefaults()
        let draft = LyricsDraft(defaults: defaults)
        XCTAssertEqual(draft.linesPerSlide, 4)
        draft.linesPerSlide = 2
        XCTAssertEqual(LyricsDraft(defaults: defaults).linesPerSlide, 2)

        defaults.set(9, forKey: "lyricsLinesPerSlide")
        XCTAssertEqual(LyricsDraft(defaults: defaults).linesPerSlide, 4)
    }

    func testChangingLinesPerSlideReparses() throws {
        let draft = LyricsDraft(defaults: try makeDefaults())
        draft.lyrics = "Verse 1\none\ntwo\nthree\nfour"
        XCTAssertEqual(draft.parsed.slideCount, 1)
        draft.linesPerSlide = 2
        XCTAssertEqual(draft.parsed.slideCount, 2)
    }

    func testAFooterFillsEmptyDetails() throws {
        let draft = LyricsDraft(defaults: try makeDefaults())
        draft.lyrics = footerLyrics
        XCTAssertEqual(draft.artist, "Jane Doe, John Smith")
        XCTAssertEqual(draft.ccliNumber, "1234567")
    }

    func testAFooterNeverOverwritesWhatWasTyped() throws {
        let draft = LyricsDraft(defaults: try makeDefaults())
        draft.artist = "Typed Artist"
        draft.ccliNumber = "42"
        draft.lyrics = footerLyrics
        XCTAssertEqual(draft.artist, "Typed Artist")
        XCTAssertEqual(draft.ccliNumber, "42")
    }

    func testAClearedFieldStaysClearWhileTheFooterIsUnchanged() throws {
        let draft = LyricsDraft(defaults: try makeDefaults())
        draft.lyrics = footerLyrics
        draft.artist = ""
        draft.lyrics += "\n"
        XCTAssertEqual(draft.artist, "")
    }

    func testReadinessNeedsATitleAndSlides() throws {
        let draft = LyricsDraft(defaults: try makeDefaults())
        draft.lyrics = "Some words with no label"
        XCTAssertTrue(draft.isMissingLabels)
        XCTAssertFalse(draft.isReady)

        draft.lyrics = "Verse 1\nMorning breaks"
        XCTAssertFalse(draft.isMissingLabels)
        XCTAssertFalse(draft.isReady, "a title is required")
        draft.title = "Morning Song"
        XCTAssertTrue(draft.isReady)
    }

    func testClearEmptiesEverything() throws {
        let draft = LyricsDraft(defaults: try makeDefaults())
        draft.lyrics = footerLyrics
        draft.title = "Morning Song"
        draft.clear()
        XCTAssertEqual(draft.lyrics, "")
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.artist, "")
        XCTAssertEqual(draft.ccliNumber, "")
        XCTAssertEqual(draft.parsed, .empty)
        XCTAssertFalse(draft.isMissingLabels)
    }
}
