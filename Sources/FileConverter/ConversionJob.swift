import Foundation

@MainActor
final class ConversionJob: ObservableObject {
    @Published var inputURL: URL?
    @Published var options = ConversionOptions()
    @Published var progress: Double = 0
    @Published var isConverting = false
    @Published var errorMessage: String?
    @Published var outputURL: URL?

    func accept(_ url: URL) {
        guard ["pdf", "pptx"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Only PDF and PowerPoint (.pptx) files are supported."
            return
        }
        inputURL = url
        outputURL = nil
        errorMessage = nil
    }

    func convert() {
        guard let inputURL else { return }
        isConverting = true
        progress = 0
        errorMessage = nil
        outputURL = nil
        let options = options
        Task {
            do {
                let output = try await ConversionEngine().convert(input: inputURL, options: options) { [weak self] value in
                    await MainActor.run { self?.progress = value }
                }
                outputURL = output
            } catch {
                errorMessage = error.localizedDescription
            }
            isConverting = false
        }
    }
}
