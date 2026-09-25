import Foundation

public enum ResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case hd = "HD (1280 px wide)"
    case fullHD = "Full HD (1920 px wide)"
    case fourK = "4K (3840 px wide)"

    public var id: String { rawValue }
    public var pixelWidth: Int {
        switch self {
        case .hd: 1280
        case .fullHD: 1920
        case .fourK: 3840
        }
    }
}

public enum BinStorage {
    public static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FileConverter", isDirectory: true)
        let bin = base.appendingPathComponent("Bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return bin
    }
}

public struct ConversionOptions: Sendable {
    public var quality: Double
    public var resolution: ResolutionPreset
    public var destination: URL
    public var fontEmbed: Bool

    public init() {
        quality = 0.92
        resolution = .fullHD
        destination = BinStorage.rootURL
        fontEmbed = true
    }
}

public struct ConversionGroup: Identifiable, Equatable {
    public let id: UUID
    public let sourceName: String
    public let folderURL: URL
    public let imageURLs: [URL]

    public init(sourceName: String, folderURL: URL) {
        self.id = UUID()
        self.sourceName = sourceName
        self.folderURL = folderURL
        self.imageURLs = ConversionGroup.exportedImages(in: folderURL)
    }

    public static func exportedImages(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
    }
}

public enum ConversionError: LocalizedError, Equatable {
    case unsupportedFile
    case libreOfficeUnavailable
    case libreOfficeFailed(String)
    case noPDFProduced
    case unreadablePDF
    case tooManyPages(Int)
    case imageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a PDF or PowerPoint (.pptx) file."
        case .libreOfficeUnavailable: "LibreOffice was not found. Install LibreOffice or choose a PDF."
        case .libreOfficeFailed(let detail): "LibreOffice could not convert this PowerPoint file. \(detail)"
        case .noPDFProduced: "LibreOffice finished without producing a PDF."
        case .unreadablePDF: "The PDF could not be opened."
        case .tooManyPages(let count): "This PDF has \(count) pages, which exceeds the 300-page limit."
        case .imageEncodingFailed: "A page could not be encoded as a JPEG."
        }
    }
}