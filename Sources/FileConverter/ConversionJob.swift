import Foundation

@MainActor
final class ConversionJob: ObservableObject {
    @Published var inputURL: URL?
    @Published var options = ConversionOptions()
    @Published var progress: Double = 0
    @Published var isConverting = false
    @Published var errorMessage: String?
    @Published var outputURL: URL?

    struct ConversionOptions {
    var quality: Double = 0.92
    var resolution: ResolutionPreset = .fullHD
    var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    var fontEmbed: Bool = true
    
    enum ResolutionPreset {
        case hd, fullHD, fourK
        var pixelWidth: Int {
            switch self {
            case .hd: return 1280
            case .fullHD: return 1920
            case .fourK: return 3840
            }
        }
    }
}


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
    
        // Add logging for debugging font issues
        print("Starting conversion with options: \(options)")
    
        Task {
            do {
                let output = try await ConversionEngine().convert(input: inputURL, options: options) { [weak self] value in
                    await MainActor.run { self?.progress = value }
                }
                outputURL = output
            
                // Log success with font info if available
                print("✓ Conversion completed successfully")
            } catch {
                errorMessage = error.localizedDescription
            
                // Add specific error messages for common issues
                if error.localizedDescription.contains("font") || 
                    error.localizedDescription.contains("substitution") {
                    errorMessage += " - Font rendering may have been substituted"
                }
            
                print("✗ Conversion failed: \(error)")
            }
        
            isConverting = false
        }
    }

