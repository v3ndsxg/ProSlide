import Foundation

enum ResolutionPreset: String, CaseIterable, Identifiable, Sendable {
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

enum BinStorage {
    static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FileConverter", isDirectory: true)
        let bin = base.appendingPathComponent("Bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return bin
    }
}

struct ConversionOptions: Sendable {
    var quality: Double = 0.92
    var resolution: ResolutionPreset = .fullHD
    var destination: URL = BinStorage.rootURL
    var fontEmbed: Bool = true
}

struct ConversionGroup: Identifiable, Equatable {
    let id: UUID
    let sourceName: String
    let folderURL: URL
    let imageURLs: [URL]

    init(sourceName: String, folderURL: URL) {
        self.id = UUID()
        self.sourceName = sourceName
        self.folderURL = folderURL
        self.imageURLs = ConversionGroup.exportedImages(in: folderURL)
    }

    static func exportedImages(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
    }
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
