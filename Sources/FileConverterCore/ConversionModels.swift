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

/// What dragging a document card in the bin hands over to ProPresenter.
public enum DragMode: String, CaseIterable, Identifiable, Sendable {
    /// The deck's `Name JPEGs` folder. ProPresenter imports it as a plain
    /// sequence, which is what you want when pulling slides into a presentation
    /// you already have.
    case jpegFolder

    /// The deck's `.pro`. ProPresenter opens it as one named presentation with
    /// every slide already attached.
    case presentation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jpegFolder: "JPEG Folder"
        case .presentation: ".pro Presentation"
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
    /// ImageIO's ceiling for lossy JPEG. The app always renders at this value,
    /// so there is no quality control in the UI. Note this is still 4:2:0
    /// subsampled, which is "max quality" rather than lossless.
    public static let maximumQuality: Double = 1.0

    public var quality: Double
    public var resolution: ResolutionPreset
    public var destination: URL
    public var fontEmbed: Bool

    public init(
        quality: Double = ConversionOptions.maximumQuality,
        resolution: ResolutionPreset = .fullHD,
        destination: URL = BinStorage.rootURL,
        fontEmbed: Bool = true
    ) {
        self.quality = quality
        self.resolution = resolution
        self.destination = destination
        self.fontEmbed = fontEmbed
    }
}

public struct ConversionQueueItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case converting
        case succeeded(folder: URL)
        case failed(String)
    }

    public let id: UUID
    public let url: URL
    public var status: Status

    public init(id: UUID = UUID(), url: URL, status: Status = .pending) {
        self.id = id
        self.url = url
        self.status = status
    }

    public var fileName: String { url.lastPathComponent }
}

/// A document ProSlide has already converted, shown in the bin.
public struct ConversionGroup: Identifiable, Equatable, Sendable {
    /// The folder path, not a fresh UUID: the bin is rescanned after every
    /// conversion, and a random identifier would silently drop the user's
    /// selection each time it refreshed.
    public var id: String { folderURL.path }

    public let sourceName: String
    public let folderURL: URL
    public let imageURLs: [URL]

    public init(sourceName: String, folderURL: URL) {
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

/// Pixel dimensions of a slide image. Deliberately not `CGSize`: nothing in
/// the ProPresenter writer needs CoreGraphics, which keeps that code testable
/// off macOS.
public struct PixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One rendered page, ready to be described to ProPresenter.
public struct ProSlide: Equatable, Sendable {
    public let imageURL: URL
    public let pixelSize: PixelSize
    /// Shown in ProPresenter's slide list. Defaults to the filename, which is
    /// what ProPresenter itself uses for imported media.
    public let label: String

    public init(imageURL: URL, pixelSize: PixelSize, label: String? = nil) {
        self.imageURL = imageURL
        self.pixelSize = pixelSize
        self.label = label ?? imageURL.lastPathComponent
    }
}

public enum ProPackageError: LocalizedError, Equatable {
    case noImages(String)
    case unreadableImage(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noImages(let name): "\(name) has no JPEGs to package."
        case .unreadableImage(let name): "The size of \(name) could not be read."
        case .writeFailed(let detail): "The presentation could not be written. \(detail)"
        }
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