import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var job: ConversionJob
    @State private var showingImporter = false
    @State private var showingDestinationPicker = false
    @State private var isTargeted = false

    var body: some View {
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
            outputShelf
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
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, UTType(filenameExtension: "pptx")!]) { result in
            if case .success(let url) = result { job.accept(url) }
        }
        .fileImporter(isPresented: $showingDestinationPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { job.options.destination = url }
        }
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
                    .font(.headline)
    
                Picker("Embed Fonts", selection: $job.options.fontEmbed) { 
                    Text("Yes (Recommended)").tag(true) 
                    Text("No").tag(false)
                }
            }
            GridRow { Text("Export folder"); HStack { Text(job.options.destination.path).lineLimit(1).truncationMode(.middle); Button("Choose…") { showingDestinationPicker = true } } }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    @ViewBuilder private var outputShelf: some View {
        if let output = job.outputURL {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export ready — drag images directly into ProPresenter").font(.headline)
                HStack {
                    Image(systemName: "photo.stack").foregroundStyle(.accent)
                    Text(output.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Open Folder") { NSWorkspace.shared.open(output) }
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 10) {
                        ForEach(exportedImages(in: output), id: \.self) { imageURL in
                            VStack(spacing: 4) {
                                if let image = NSImage(contentsOf: imageURL) {
                                    Image(nsImage: image)
                                        .resizable().scaledToFit()
                                        .frame(width: 96, height: 54)
                                } else {
                                    Image(systemName: "photo").frame(width: 96, height: 54)
                                }
                                Text(imageURL.lastPathComponent).font(.caption2).lineLimit(1)
                            }
                            .frame(width: 104)
                            .onDrag { NSItemProvider(object: imageURL as NSURL) }
                        }
                    }.padding(.vertical, 2)
                }
                Text("Drag JPEGs from this Finder folder directly into ProPresenter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func exportedImages(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
    }
}
