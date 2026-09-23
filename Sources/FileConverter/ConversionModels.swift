import Foundation

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case hd = "HD (1280 px wide)"
    case fullHD = "Full HD (1920 px wide)"
    case fourK = "4K (3840 px wide)"

    var id: String { rawValue }
    var pixelWidth: Int {
        switch self {
        case .hd: 1280
        case .fullHD: 1920
        case .fourK: 3840
        }
    }
}

struct ConversionOptions {
    var quality: Double = 0.92
    var resolution: ResolutionPreset = .fullHD
    var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    var fontEmbed: Bool = true
}

enum ConversionError: LocalizedError {
    case unsupportedFile
    case libreOfficeUnavailable
    case libreOfficeFailed(String)
    case noPDFProduced
    case unreadablePDF
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a PDF or PowerPoint (.pptx) file."
        case .libreOfficeUnavailable: "LibreOffice was not found. Install LibreOffice or choose a PDF."
        case .libreOfficeFailed(let detail): "LibreOffice could not convert this PowerPoint file. \(detail)"
        case .noPDFProduced: "LibreOffice finished without producing a PDF."
        case .unreadablePDF: "The PDF could not be opened."
        case .imageEncodingFailed: "A page could not be encoded as a JPEG."
        }
    }
}
