import FileConverterCore
import SwiftUI
import UniformTypeIdentifiers

/// The Lyrics Formatter tab: the song's details across the top, the pasted
/// lyrics on the left, and the slides they make on the right.
struct LyricsFormatterView: View {
    @EnvironmentObject private var draft: LyricsDraft
    @EnvironmentObject private var queue: ConversionQueue
    /// The operator's ProPresenter library, if chosen. Only the names of the
    /// presentations in it are read, to keep a new song from taking one.
    @AppStorage("proPresenterLibraryPath") private var libraryPath = ""
    @State private var choosingLibrary = false
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case saved(String)
        case failed(String)
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
        .fileImporter(isPresented: $choosingLibrary, allowedContentTypes: [.folder]) { picked in
            if case .success(let url) = picked { libraryPath = url.path }
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

    private var libraryURL: URL? {
        libraryPath.isEmpty ? nil : URL(fileURLWithPath: libraryPath, isDirectory: true)
    }

    private func create() {
        let song = draft.song
        do {
            let saved = try queue.addSong(song, libraryFolder: libraryURL)
            outcome = .saved(saved.wasRenamed
                ? "Saved as \u{201C}\(saved.name)\u{201D} in the bin, because \u{201C}\(song.title)\u{201D} is already taken."
                : "Saved \u{201C}\(saved.name)\u{201D} in the bin. Drag its card into ProPresenter.")
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    // MARK: - Song details

    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            field("Song title", prompt: "Required", text: $draft.title)
                .frame(maxWidth: .infinity)
            field("Artist (optional)", prompt: "", text: $draft.artist)
                .frame(maxWidth: .infinity)
            field("CCLI number (optional)", prompt: "", text: $draft.ccliNumber)
                .frame(width: 170)
        }
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
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
                    ForEach(Array(LyricsParser.linesPerSlideRange), id: \.self) { Text("\($0)").tag($0) }
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
            if let libraryURL {
                Text("Titles are checked against your ProPresenter library \u{201C}\(libraryURL.lastPathComponent)\u{201D}.")
                Button("Change\u{2026}") { choosingLibrary = true }.buttonStyle(.link)
                Button("Stop checking") { libraryPath = "" }.buttonStyle(.link)
            } else {
                Text("Titles are checked against the bin only.")
                Button("Choose ProPresenter library\u{2026}") { choosingLibrary = true }.buttonStyle(.link)
            }
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
    }
}
