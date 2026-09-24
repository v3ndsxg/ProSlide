import AppKit
import Foundation

@MainActor
final class ConversionJob: ObservableObject {
    @Published var inputURL: URL?
    @Published var options = ConversionOptions()
    @Published var progress: Double = 0
    @Published var isConverting = false
    @Published var errorMessage: String?
    @Published private(set) var groups: [ConversionGroup] = []

    private let fileManager = FileManager.default

    init() {
        reloadBin()
    }

    func accept(_ url: URL) {
        guard ["pdf", "pptx"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Only PDF and PowerPoint (.pptx) files are supported."
            return
        }
        inputURL = url
        errorMessage = nil
    }

    func convert() {
        guard let inputURL else { return }
        isConverting = true
        progress = 0
        errorMessage = nil

        let scoped = inputURL.startAccessingSecurityScopedResource()
        let job = self
        // Detached so page rendering and JPEG encoding never block the main thread.
        Task.detached(priority: .userInitiated) { [options, inputURL, job] in
            defer {
                if scoped { inputURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let output = try await ConversionEngine().convert(input: inputURL, options: options) { value in
                    await MainActor.run { job.progress = value }
                }
                print("✓ Conversion completed successfully: \(output)")
                await MainActor.run {
                    job.reloadBin()
                    job.isConverting = false
                }
            } catch {
                print("✗ Conversion failed: \(error)")
                await MainActor.run {
                    job.errorMessage = error.localizedDescription
                    job.isConverting = false
                }
            }
        }
    }

    func save(group: ConversionGroup, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for image in group.imageURLs {
            let target = destination.appendingPathComponent(image.lastPathComponent)
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: image, to: target)
        }
    }

    func clearBin() throws {
        for folder in groups.map(\.folderURL) {
            try fileManager.removeItem(at: folder)
        }
        reloadBin()
    }

    func openGroup(_ group: ConversionGroup) {
        NSWorkspace.shared.open(group.folderURL)
    }

    func openBin() {
        NSWorkspace.shared.open(BinStorage.rootURL)
    }

    private func reloadBin() {
        let folders = (try? fileManager.contentsOfDirectory(at: BinStorage.rootURL, includingPropertiesForKeys: nil))?
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending } ?? []
        groups = folders.compactMap { folder in
            guard !ConversionGroup.exportedImages(in: folder).isEmpty else { return nil }
            return ConversionGroup(sourceName: folder.lastPathComponent, folderURL: folder)
        }
    }
}