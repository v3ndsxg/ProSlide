import AppKit
import FileConverterCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var queue: ConversionQueue
    @State private var showingImporter = false
    @State private var showingSaveImporter = false
    @State private var saveTarget: ConversionGroup?
    @State private var confirmingClear = false
    @State private var isTargeted = false
    @State private var expandedDecks: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            // Each importer sits on its own view. SwiftUI keeps only the last
            // `fileImporter` attached to a given view, so two on one view left the
            // first one -- "click to choose files" -- unable to open at all.
            mainPane
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: [.pdf] + ["pptx", "ppt"].compactMap { UTType(filenameExtension: $0) },
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result { queue.accept(urls) }
                }
            if !queue.groups.isEmpty {
                Divider()
                binPanel
                    .fileImporter(isPresented: $showingSaveImporter, allowedContentTypes: [.folder]) { result in
                        guard case .success(let url) = result, let group = saveTarget else { return }
                        saveTarget = nil
                        do {
                            // What is saved is what the card drags. It used to always
                            // be the JPEG folder, in presentation mode too -- beside a
                            // caption describing a different payload, which is how a
                            // working presentation came to be believed missing.
                            if queue.dragMode == .presentation {
                                try queue.savePresentation(for: group, to: url)
                            } else {
                                try queue.save(group: group, to: url)
                            }
                        } catch {
                            queue.message = error.localizedDescription
                        }
                    }
            }
        }
        .task { queue.reloadBin() }
        .confirmationDialog("Clear the bin and the file list?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Everything", role: .destructive) {
                do {
                    try queue.clearBin()
                } catch {
                    queue.message = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every converted deck, its presentation, and the files queued on the main page, so you can start fresh.")
        }
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Text(AppIdentity.current.displayName).font(.largeTitle.weight(.semibold))
                if AppIdentity.current.isBeta {
                    Text("BETA")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                        .foregroundStyle(.black)
                }
            }
            Text("Turn PDFs and PowerPoint slides into dependable JPEG images.")
                .foregroundStyle(.secondary)

            dropZone
            options
            if !queue.items.isEmpty { queueList }
            if queue.isConverting {
                ProgressView(value: queue.progress) { Text("Converting…") }
                    .frame(maxWidth: 510)
            }
            if let message = queue.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var dropZone: some View {
        Button { showingImporter = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").font(.system(size: 34))
                Text(queue.items.isEmpty
                     ? "Drop PDF, .pptx or .ppt files here"
                     : "\(queue.items.count) file\(queue.items.count == 1 ? "" : "s") queued")
                Text("or click to choose files").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(isTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: acceptDrop)
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow { Text("Resolution"); Picker("Resolution", selection: $queue.options.resolution) { ForEach(ResolutionPreset.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }
            GridRow {
                Text("Font Rendering")
                Picker("Embed Fonts", selection: $queue.options.fontEmbed) {
                    Text("Yes (Recommended)").tag(true)
                    Text("No").tag(false)
                }
            }
            GridRow {
                Text("JPEG quality")
                Text("Always maximum").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Files").font(.headline)
                Spacer()
                Button("Clear") { queue.removeAll() }
                    .disabled(queue.isConverting)
            }
            ForEach(queue.items) { item in
                queueRow(item)
            }
        }
        .frame(maxWidth: 620)
    }

    private func queueRow(_ item: ConversionQueueItem) -> some View {
        HStack(spacing: 10) {
            statusIcon(for: item.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).lineLimit(1)
                statusDetail(for: item.status)
            }
            Spacer(minLength: 8)
            if case .succeeded(let folder) = item.status {
                Button("Open") { BinOpener.open(folder) }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func statusIcon(for status: ConversionQueueItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .converting:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusDetail(for status: ConversionQueueItem.Status) -> some View {
        switch status {
        case .pending:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .converting:
            Text("Converting…").font(.caption).foregroundStyle(.secondary)
        case .succeeded(let folder):
            Text(folder.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var footer: some View {
        HStack {
            Text("PowerPoint files are rendered through LibreOffice.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if queue.isConverting {
                Button("Stop", role: .destructive) { queue.cancel() }
            }
            Button(convertTitle) { queue.convert() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(queue.pendingCount == 0 || queue.isConverting)
        }
    }

    private var convertTitle: String {
        if queue.isConverting { return "Converting…" }
        let count = queue.pendingCount
        return count == 0 ? "Convert" : "Convert \(count) file\(count == 1 ? "" : "s")"
    }

    // MARK: - Bin

    private var binPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Converted decks", systemImage: "photo.stack").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) { confirmingClear = true }
                    .buttonStyle(.borderless)
                    .disabled(queue.isConverting)
            }
            Picker("Card drag", selection: $queue.dragMode) {
                ForEach(DragMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(binHint).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(queue.groups) { group in
                        deckRow(group)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.06))
    }

    /// One line, naming what a drag does in the current mode.
    private var binHint: String {
        switch queue.dragMode {
        case .presentation:
            return "Drag a deck into ProPresenter to open it as one presentation."
        case .jpegFolder:
            return "Drag a deck to add its slides to a presentation you already have."
        }
    }

    /// A deck is one compact row: grip, name, slide count, status and a chevron
    /// that opens its slides. There are no buttons on the face of the card; the
    /// housekeeping actions live in its right-click menu.
    private func deckRow(_ group: ConversionGroup) -> some View {
        let status = queue.deckStatus(for: group)
        let isOpen = expandedDecks.contains(group.id)
        let payload = queue.dragPayload(for: group)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DragGrip()
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(group.imageURLs.count) \(group.imageURLs.count == 1 ? "slide" : "slides")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                statusChip(status)
                Button {
                    if isOpen { expandedDecks.remove(group.id) } else { expandedDecks.insert(group.id) }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide slides" : "Preview slides")
                .accessibilityLabel(isOpen ? "Hide slides" : "Preview slides")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            if isOpen { deckDetail(group, status: status) }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        // The whole card is the drag source. .contentShape is what makes the
        // padding and empty space around the content draggable too, rather
        // than only the text.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .draggable(on: payload)
        .openHandCursor(when: payload != nil)
        .contextMenu {
            Button("Show in Finder") { reveal(group) }
            Button("Save a copy\u{2026}") { saveTarget = group; showingSaveImporter = true }
                .disabled(queue.dragMode == .presentation && queue.presentation(for: group) == nil)
            Button("Rebuild presentation") { queue.buildPresentation(group) }
        }
    }

    private func statusChip(_ status: DeckStatus) -> some View {
        let color: Color
        switch status {
        case .ready: color = .green
        case .preparing, .missing: color = .gray
        case .failed: color = .red
        }
        return Text(status.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    /// What a deck shows when opened: its slides, or -- when it has no
    /// presentation to drag -- why, with the one button that can fix it.
    @ViewBuilder
    private func deckDetail(_ group: ConversionGroup, status: DeckStatus) -> some View {
        if status == .missing {
            VStack(alignment: .leading, spacing: 8) {
                Text("This deck has no ProPresenter bundle yet. Build one to drag it as a presentation.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Build presentation") { queue.buildPresentation(group) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        } else if case .failed(let reason) = status {
            VStack(alignment: .leading, spacing: 8) {
                Text(reason)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { queue.buildPresentation(group) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], spacing: 6) {
                ForEach(Array(group.imageURLs.enumerated()), id: \.element) { index, imageURL in
                    thumbnail(imageURL, number: index + 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private func thumbnail(_ imageURL: URL, number: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
            Text("\(number)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(3)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        // A single slide can still be dragged out on its own.
        .onDrag { NSItemProvider(object: imageURL as NSURL) }
    }

    /// Reveals what the card drags: the `.probundle` in presentation mode once it
    /// exists, otherwise the deck's folder.
    private func reveal(_ group: ConversionGroup) {
        if queue.dragMode == .presentation, let presentation = queue.presentation(for: group) {
            BinOpener.reveal(presentation)
        } else {
            BinOpener.open(group.folderURL)
        }
    }

    // MARK: - Drop

    /// Accepts every provider in the drop, not just the first. The load
    /// callbacks can fire in any order on any thread, so they are funnelled
    /// through a dispatch group before the batch starts.
    private func acceptDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let direct = item as? URL {
                    url = direct
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            queue.accept(urls)
        }
        return true
    }
}

// MARK: - Drag

/// Attaches a drag only when there is something to drag.
///
/// `onDrag` must return an item provider, so a view cannot simply decline. This
/// lets a deck with nothing to offer be inert and visibly so, rather than
/// quietly handing over a different payload behind the operator's back — which
/// is what `ConversionQueue.dragPayload(for:)` used to permit.
///
/// One file or one folder, never a pile of loose images. A SwiftUI drag can only
/// ever hand over a single `NSItemProvider`, so packing many URLs into one item
/// does not arrive as many files: a receiver takes the first and you get one
/// slide. Finder gets this right by writing one pasteboard item per file, which
/// needs an AppKit drag session.
private extension View {
    @ViewBuilder
    func draggable(on payload: URL?) -> some View {
        if let payload {
            self.onDrag {
                NSItemProvider(contentsOf: payload) ?? NSItemProvider(object: payload as NSURL)
            }
        } else {
            self
        }
    }
}

// MARK: - Drag affordances

/// Six dots on a card's left edge: the visual cue that the card can be picked up.
/// Purely a hint -- the whole card is the drag source, not just this.
private struct DragGrip: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(.secondary.opacity(0.7))
        .accessibilityHidden(true)
    }
}

/// Shows the open-hand cursor while the pointer is over something draggable.
///
/// `NSCursor.push` and `pop` must stay balanced or the cursor sticks, so whether
/// this view has pushed one is remembered and released when the pointer leaves,
/// the card stops being draggable, or the view goes away.
private struct OpenHandCursor: ViewModifier {
    let active: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && active && !pushed {
                    NSCursor.openHand.push()
                    pushed = true
                } else if (!inside || !active) && pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

private extension View {
    func openHandCursor(when active: Bool) -> some View {
        modifier(OpenHandCursor(active: active))
    }
}
