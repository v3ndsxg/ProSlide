import FileConverterCore
import SwiftUI

/// The Lyrics Formatter tab: the song's details across the top, the pasted
/// lyrics on the left, and the slides they make on the right.
struct LyricsFormatterView: View {
    @EnvironmentObject private var draft: LyricsDraft
    @EnvironmentObject private var queue: ConversionQueue
    @State private var outcome: Outcome?
    /// Why Create Presentation saved nothing, shown as an alert.
    @State private var duplicate: Duplicate?
    @FocusState private var artistFocused: Bool

    private enum Outcome: Equatable {
        case saved(String)
        case failed(String)
    }

    private enum Duplicate: Equatable {
        /// The title is in a library and there is no artist.
        case needsArtist
        /// "Title (Artist)" is in a library too.
        case inLibrary(String)

        var message: String {
            switch self {
            case .needsArtist:
                "Hey, a song with that name already exists in your ProPresenter Library. Please add an artist name and create the presentation again."
            case .inLibrary(let name):
                "A song named \u{201C}\(name)\u{201D} already exists in your ProPresenter Library."
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            AppTitleView()
            Text("Paste song lyrics with section labels to turn them into ProPresenter slides.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                details
                libraryRow
            }
            HStack(alignment: .top, spacing: 16) {
                pastePane
                previewPane
            }
            .frame(maxHeight: .infinity)
            outcomeLine
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .alert(
            "Song already exists",
            isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
            presenting: duplicate
        ) { shown in
            Button("OK") {
                if shown == .needsArtist { artistFocused = true }
            }
        } message: { shown in
            Text(shown.message)
        }
        // A result describes the song just saved; editing starts the next one.
        .onChange(of: draft.lyrics) { _ in outcome = nil }
        .onChange(of: draft.title) { _ in outcome = nil }
    }

    @ViewBuilder
    private var outcomeLine: some View {
        switch outcome {
        case .saved(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        case nil:
            EmptyView()
        }
    }

    private var librariesURL: URL { LyricsPackage.proPresenterLibrariesURL }

    private var librariesFound: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: librariesURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func create() {
        let song = draft.song
        do {
            switch try queue.addSong(song, librariesFolder: librariesURL) {
            case .saved(let saved):
                outcome = .saved(message(for: saved, title: song.title))
            case .needsArtist:
                outcome = nil
                duplicate = .needsArtist
            case .alreadyInLibrary(let name):
                outcome = nil
                duplicate = .inLibrary(name)
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    private func message(for saved: LyricsPackage.Saved, title: String) -> String {
        if saved.addedArtist {
            return "Saved as \u{201C}\(saved.name)\u{201D}, because \u{201C}\(title)\u{201D} is already in your ProPresenter Library."
        }
        if saved.replacedInBin {
            return "Replaced \u{201C}\(saved.name)\u{201D} in the bin. Drag its card into ProPresenter."
        }
        return "Saved \u{201C}\(saved.name)\u{201D} in the bin. Drag its card into ProPresenter."
    }

    // MARK: - Song details

    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            field("Song title", prompt: "Required", text: $draft.title)
                .frame(maxWidth: .infinity)
            field("Artist (optional)", prompt: "", text: $draft.artist, focused: $artistFocused)
                .frame(maxWidth: .infinity)
            field("CCLI number (optional)", prompt: "", text: $draft.ccliNumber)
                .frame(width: 170)
        }
    }

    private func field(
        _ label: String, prompt: String, text: Binding<String>, focused: FocusState<Bool>.Binding? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let focused {
                TextField(label, text: text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused(focused)
            } else {
                TextField(label, text: text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        }
    }

    // MARK: - 1 · Paste lyrics

    private var pastePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            paneHeading("1 \u{00B7} Paste lyrics")
            Text("Unformatted lyrics go here.")
                .font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.lyrics)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if draft.lyrics.isEmpty {
                    Text("Paste lyrics with section labels, like Verse 1, Chorus, Bridge\u{2026}")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 2 · Slide preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                paneHeading("2 \u{00B7} Slide preview")
                Spacer()
                Picker("Lines per slide", selection: $draft.linesPerSlide) {
                    ForEach(LinesPerSlide.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Text("Read-only. Edit the lyrics on the left.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                previewContent
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var previewContent: some View {
        if draft.isMissingLabels {
            Label(
                "No section labels found. Put a label such as Verse 1, Chorus or Bridge on its own line above each part.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
        } else if draft.parsed.sections.isEmpty {
            Text("Slides appear here as you paste.")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                if draft.parsed.droppedLineCount > 0 {
                    let count = draft.parsed.droppedLineCount
                    Text("\(count) line\(count == 1 ? "" : "s") before the first label \(count == 1 ? "was" : "were") left out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.parsed.longSlideCount > 0 {
                    let count = draft.parsed.longSlideCount
                    Label(
                        "\(count) slide\(count == 1 ? " has" : "s have") more than \(LyricsSlide.longLineCount) lines and may need resizing in ProPresenter.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.lyricsWarning)
                }
                ForEach(draft.parsed.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        GroupHeading(section: section)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            ForEach(Array(section.slides.enumerated()), id: \.offset) { _, slide in
                                SlideCard(slide: slide)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { draft.clear() }
                .disabled(draft.lyrics.isEmpty && draft.title.isEmpty && draft.artist.isEmpty && draft.ccliNumber.isEmpty)
            Button("Create Presentation") { create() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.isReady)
                .help(draft.isReady ? "Save this song in the bin as a ProPresenter presentation." : "Needs a song title and at least one slide.")
        }
    }

    /// Where duplicate titles are checked, beside the details.
    private var libraryRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical").foregroundStyle(.secondary)
            Text(librariesFound
                ? "Titles are checked against your ProPresenter libraries."
                : "No ProPresenter libraries found in Documents.")
                .help(librariesURL.path)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var summary: String {
        let slides = draft.parsed.slideCount
        let groups = draft.parsed.sections.count
        guard slides > 0 else { return "Section labels become groups in ProPresenter." }
        return "\(slides) slide\(slides == 1 ? "" : "s") in \(groups) group\(groups == 1 ? "" : "s")"
    }

    private func paneHeading(_ text: String) -> some View {
        Text(text).font(.headline)
    }
}

/// A group's name on its colour, as ProPresenter shows it.
private struct GroupHeading: View {
    let section: LyricsSection

    var body: some View {
        Text(section.name)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: section.kind.color)))
            .foregroundStyle(Self.isLight(section.kind.color) ? Color.black : Color.white)
    }

    /// Light pink and yellow need dark text to stay readable.
    private static func isLight(_ hex: UInt32) -> Bool {
        let red = Double((hex >> 16) & 0xFF), green = Double((hex >> 8) & 0xFF), blue = Double(hex & 0xFF)
        return (0.299 * red + 0.587 * green + 0.114 * blue) / 255 > 0.65
    }
}

/// One slide: white, centred text on black, at the 16:9 of a 1920×1080 slide.
private struct SlideCard: View {
    let slide: LyricsSlide

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black)
            Text(slide.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding(8)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if slide.isLong {
                Label("\(slide.lines.count) lines", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow))
                    .padding(4)
                    .help("More than \(LyricsSlide.longLineCount) lines may not fit. Resize the text in ProPresenter after importing.")
            }
        }
    }
}

private extension Color {
    /// A darker yellow than the system one, which is hard to read on white.
    static let lyricsWarning = Color(red: 0.72, green: 0.47, blue: 0.12)
}
