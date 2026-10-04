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

/// How a converted deck is packaged for ProPresenter.
///
/// Both forms describe the same slides. The difference is where ProPresenter
/// looks for the images.
public enum ProPackageFormat: String, CaseIterable, Identifiable, Sendable {
    /// A `.probundle`: a ZIP holding the `.pro` manifest alongside the JPEGs,
    /// which the manifest points at with ProPresenter's `ROOT_SHOW` relative
    /// root. Self-contained, so it can be moved, mailed or dragged anywhere.
    case probundle

    /// A bare `.pro` manifest pointing at the JPEGs where they already are.
    /// Smaller, but the links break if the deck folder moves off this machine.
    case proFile

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .probundle: "probundle"
        case .proFile: "pro"
        }
    }
}

public enum ProPackageError: LocalizedError, Equatable {
    case noImages(String)
    case unreadableImage(String)
    case outsideHomeDirectory(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noImages(let name): "\(name) has no JPEGs to package."
        case .unreadableImage(let name): "The size of \(name) could not be read."
        case .outsideHomeDirectory(let name):
            "\(name) is not inside your home folder, so a .pro file cannot reference it."
        case .writeFailed(let detail): "The ProPresenter package could not be written. \(detail)"
        }
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
    /// Where ProPresenter should find `imageURL`. This is the only thing that
    /// differs between a bundled and an unbundled deck.
    public let reference: MediaReference
    /// Shown in ProPresenter's slide list. Defaults to the filename, which is
    /// what ProPresenter itself uses for imported media.
    public let label: String

    public init(imageURL: URL, pixelSize: PixelSize, reference: MediaReference, label: String? = nil) {
        self.imageURL = imageURL
        self.pixelSize = pixelSize
        self.reference = reference
        self.label = label ?? imageURL.lastPathComponent
    }
}

/// Where ProPresenter should look for one slide's image.
public struct MediaReference: Equatable, Sendable {
    /// The `file://` URL ProPresenter shows when the media cannot be resolved.
    public let absoluteString: String
    /// `URL.LocalRelativePath.Root`, as an integer straight from the schema.
    public let root: UInt64
    /// Path relative to `root`.
    public let path: String

    public init(absoluteString: String, root: UInt64, path: String) {
        self.absoluteString = absoluteString
        self.root = root
        self.path = path
    }

    /// Inside a `.probundle`, the images sit beside the manifest under
    /// `Media/Assets`, which is what `ROOT_SHOW` points at.
    public static func bundleAsset(named name: String) -> MediaReference {
        MediaReference(
            absoluteString: "file:///Library/Application%20Support/ProPresenter/Media/Assets/"
                + ProPresenterDocument.percentEncoded(name),
            root: MediaReference.showRoot,
            path: "Media/Assets/\(name)"
        )
    }

    /// A path under the user's home folder, expressed relative to it so the
    /// deck survives the account's home moving or the folder being synced.
    public static func userHome(_ url: URL, home: URL) -> MediaReference? {
        let rootPath = home.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        return MediaReference(
            absoluteString: url.absoluteString,
            root: MediaReference.userHomeRoot,
            path: relative
        )
    }

    static let userHomeRoot: UInt64 = 2
    static let showRoot: UInt64 = 10
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