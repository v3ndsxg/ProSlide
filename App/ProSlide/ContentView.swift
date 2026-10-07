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

    var body: some View {
        HStack(spacing: 0) {
            mainPane
            if !queue.groups.isEmpty {
                Divider()
                binPanel
            }
        }
        .task { queue.reloadBin() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf, UTType(filenameExtension: "pptx")!],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { queue.accept(urls) }
        }
        .fileImporter(isPresented: $showingSaveImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, let group = saveTarget else { return }
            saveTarget = nil
            do {
                try queue.save(group: group, to: url)
            } catch {
                queue.message = error.localizedDescription
            }
        }
        .confirmationDialog("Clear all converted images from the bin?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Bin", role: .destructive) {
                do {
                    try queue.clearBin()
                } catch {
                    queue.message = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(spacing: 18) {
            Text("ProSlide").font(.largeTitle.weight(.semibold))
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
                     ? "Drop PDF or .pptx files here"
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
                .disabled(queue.items.isEmpty || queue.isConverting)
        }
    }

    private var convertTitle: String {
        if queue.isConverting { return "Converting…" }
        let count = queue.items.count
        return count == 0 ? "Convert" : "Convert \(count) file\(count == 1 ? "" : "s")"
    }

    // MARK: - Bin

    private var binPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Bin", systemImage: "photo.stack").font(.headline)
                Spacer()
                Button("Open Folder") { BinOpener.open(queue.binRootURL) }
                Button("Clear", role: .destructive) { confirmingClear = true }
            }
            Text(binHint).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(queue.groups) { group in
                        binGroup(group)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.06))
    }

    private var binHint: String {
        var hint = "Each card is a .pro presentation written beside its JPEGs. Keep the folder together when you move it: the .pro points at the images next to it."
        if queue.groups.contains { queue.presentation(for: $0) == nil && queue.presentationFailures[$0.id] == nil } {
            hint += " They are written in the background, so a card still being written drags its JPEG folder instead."
        }
        return hint
    }

    /// The payload for dragging a whole document into ProPresenter.
    ///
    /// That is the deck's `.pro` presentation, which ProPresenter imports as one
    /// named presentation with every slide attached. Before it has been written,
    /// the card falls back to the document's `Name JPEGs` folder, which
    /// ProPresenter imports as a plain sequence — a drag is never a no-op.
    ///
    /// The fallback deliberately ignores *why* the presentation is missing. A card
    /// whose write failed would otherwise have nothing to drag at all, and the
    /// folder is always there.
    ///
    /// This carries a single file rather than the individual image URLs. A
    /// SwiftUI drag can only ever hand over a single `NSItemProvider`, so packing
    /// many URLs into one item does not arrive as many files — a receiver takes
    /// the first and you get one slide. Finder gets this right by writing one
    /// pasteboard item per file, which needs an AppKit drag session.
    private func cardDragItem(for group: ConversionGroup) -> NSItemProvider {
        if let presentation = queue.presentation(for: group) {
            return NSItemProvider(contentsOf: presentation) ?? NSItemProvider(object: presentation as NSURL)
        }
        return NSItemProvider(contentsOf: group.folderURL)
            ?? NSItemProvider(object: group.folderURL as NSURL)
    }

    private func binGroup(_ group: ConversionGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.sourceName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(group.imageURLs.count) images").font(.caption).foregroundStyle(.secondary)
                if queue.presentation(for: group) != nil || queue.presentationFailures[group.id] != nil {
                    Button("Rebuild") {
                        queue.buildPresentation(group)
                    }
                }
                Button("Open") { BinOpener.open(group.folderURL) }
                Button("Save…") { saveTarget = group; showingSaveImporter = true }
            }
            HStack(spacing: 5) {
                Image(systemName: cardDragIcon(for: group))
                Text(cardDragCaption(for: group))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(group.imageURLs, id: \.self) { imageURL in
                    VStack(spacing: 4) {
                        if let image = NSImage(contentsOf: imageURL) {
                            Image(nsImage: image)
                                .resizable().scaledToFit()
                                .frame(width: 96, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: "photo").frame(width: 96, height: 54)
                        }
                        Text(imageURL.lastPathComponent).font(.caption2).lineLimit(1)
                    }
                    .onDrag { NSItemProvider(object: imageURL as NSURL) }
                }
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // The whole card is the drag source. .contentShape is what makes the
        // padding and empty space around the content draggable too, rather
        // than only the text and thumbnails.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onDrag { cardDragItem(for: group) }
    }

    private func cardDragIcon(for group: ConversionGroup) -> String {
        guard queue.presentation(for: group) != nil else { return "clock" }
        return "doc.text.fill"
    }

    private func cardDragCaption(for group: ConversionGroup) -> String {
        if let failure = queue.presentationFailures[group.id] {
            return "Could not write the presentation: \(failure)"
        }
        return queue.presentation(for: group) == nil
            ? "Building presentation\u{2026}"
            : "Drag this card to open it as a presentation"
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
