import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var job: ConversionJob
    @State private var showingImporter = false
    @State private var showingSaveImporter = false
    @State private var saveTarget: ConversionGroup?
    @State private var confirmingClear = false
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            mainPane
            if !job.groups.isEmpty {
                Divider()
                binPanel
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, UTType(filenameExtension: "pptx")!]) { result in
            if case .success(let url) = result { job.accept(url) }
        }
        .fileImporter(isPresented: $showingSaveImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, let group = saveTarget else { return }
            saveTarget = nil
            do {
                try job.save(group: group, to: url)
            } catch {
                job.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Clear all converted images from the bin?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Bin", role: .destructive) {
                do {
                    try job.clearBin()
                } catch {
                    job.errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var mainPane: some View {
        VStack(spacing: 18) {
            Text("File Converter").font(.largeTitle.weight(.semibold))
            Text("Turn PDFs and PowerPoint slides into dependable JPEG images.")
                .foregroundStyle(.secondary)

            dropZone
            options
            if job.isConverting {
                ProgressView(value: job.progress) { Text("Converting…") }
                    .frame(maxWidth: 510)
            }
            if let error = job.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
            HStack {
                Text("PowerPoint files are rendered through LibreOffice.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Convert") { job.convert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.inputURL == nil || job.isConverting)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var dropZone: some View {
        Button { showingImporter = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").font(.system(size: 34))
                Text(job.inputURL?.lastPathComponent ?? "Drop a PDF or .pptx here")
                Text("or click to choose a file").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(isTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { job.accept(url) }
            }
            return !providers.isEmpty
        }
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow { Text("Resolution"); Picker("Resolution", selection: $job.options.resolution) { ForEach(ResolutionPreset.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }
            GridRow { Text("JPEG quality"); HStack { Slider(value: $job.options.quality, in: 0.5...1, step: 0.01); Text("\(Int(job.options.quality * 100))% ").monospacedDigit().frame(width: 42) } }
            GridRow {
                Text("Font Rendering")
                Picker("Embed Fonts", selection: $job.options.fontEmbed) {
                    Text("Yes (Recommended)").tag(true)
                    Text("No").tag(false)
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var binPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Bin", systemImage: "photo.stack").font(.headline)
                Spacer()
                Button("Open Folder") { job.openBin() }
                Button("Clear", role: .destructive) { confirmingClear = true }
            }
            Text("Drag a document's JPEGs straight into ProPresenter, or open its folder to drag the whole set in.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(job.groups) { group in
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

    private func binGroup(_ group: ConversionGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.sourceName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(group.imageURLs.count) images").font(.caption).foregroundStyle(.secondary)
                Button("Open") { job.openGroup(group) }
                Button("Save…") { saveTarget = group; showingSaveImporter = true }
            }
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
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}