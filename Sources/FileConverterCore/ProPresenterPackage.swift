import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Turns a converted deck's JPEGs into something ProPresenter can open
/// directly, instead of a folder the user has to drag in slide by slide.
///
/// Two shapes are produced, both driven by `ProPackageFormat`:
///
/// - A `.probundle` is a ZIP holding the `.pro` manifest and a copy of every
///   JPEG under `Media/Assets`. The manifest points at them with ProPresenter's
///   `ROOT_SHOW` relative root, so the bundle works wherever it is moved to.
/// - A bare `.pro` is the same manifest pointing at the JPEGs where they
///   already are, relative to the user's home folder.
///
/// Both are written into the deck's own folder, so clearing the bin takes them
/// with it and rescanning the bin ignores them (it only looks at `.jpg`).
public enum ProPresenterPackage {

    /// Where ProPresenter expects assets to live inside a bundle.
    public static let bundleAssetDirectory = "Media/Assets"

    /// The suffix `ConversionEngine` gives a deck's folder.
    private static let jpegFolderSuffix = " JPEGs"

    // MARK: - Packaging

    /// Packages `group` into its own folder and returns the file written.
    ///
    /// - Parameters:
    ///   - group: the converted deck to package.
    ///   - format: which of the two shapes to produce.
    ///   - pixelSize: resolves an image's dimensions. Injectable so the writer
    ///     can be tested without decoding real images.
    public static func package(
        group: ConversionGroup,
        format: ProPackageFormat,
        pixelSize: (URL) -> PixelSize?
    ) throws -> URL {
        let images = group.imageURLs
        guard !images.isEmpty else {
            throw ProPackageError.noImages(group.sourceName)
        }

        let name = presentationName(for: group)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let slides = try images.map { url -> ProSlide in
            guard let size = pixelSize(url) else {
                throw ProPackageError.unreadableImage(url.lastPathComponent)
            }
            let reference: MediaReference
            switch format {
            case .probundle:
                reference = .bundleAsset(named: url.lastPathComponent)
            case .proFile:
                guard let relative = MediaReference.userHome(url, home: home) else {
                    throw ProPackageError.outsideHomeDirectory(url.lastPathComponent)
                }
                reference = relative
            }
            return ProSlide(imageURL: url, pixelSize: size, reference: reference)
        }

        let manifest = ProPresenterDocument.encode(name: name, slides: slides)
        let destination = group.folderURL
            .appendingPathComponent(name)
            .appendingPathExtension(format.fileExtension)

        switch format {
        case .probundle:
            try writeBundle(manifest: manifest, name: name, slides: slides, to: destination)
        case .proFile:
            try write(manifest, to: destination)
        }
        return destination
    }

    /// Convenience overload that reads each image's real pixel dimensions.
    public static func package(
        group: ConversionGroup,
        format: ProPackageFormat
    ) throws -> URL {
        try package(group: group, format: format, pixelSize: pixelSize(ofImageAt:))
    }

    // MARK: - Naming

    /// ProPresenter shows this name, and it is also the manifest's filename
    /// inside the bundle. The deck's folder is called `Name JPEGs`, so strip
    /// that suffix to get back to the document's own name.
    static func presentationName(for group: ConversionGroup) -> String {
        let folder = group.sourceName
        guard folder.hasSuffix(jpegFolderSuffix) else { return folder }
        let trimmed = String(folder.dropLast(jpegFolderSuffix.count))
        return trimmed.isEmpty ? folder : trimmed
    }

    // MARK: - Writing

    private static func writeBundle(
        manifest: Data,
        name: String,
        slides: [ProSlide],
        to destination: URL
    ) throws {
        do {
            let archive = try ZipArchiveWriter(to: destination)
            try archive.addEntry(path: "\(name).pro", data: manifest)
            for slide in slides {
                try archive.addFile(
                    at: slide.imageURL,
                    path: "\(bundleAssetDirectory)/\(slide.imageURL.lastPathComponent)"
                )
            }
            try archive.close()
        } catch let failure as ZipArchiveWriter.Failure {
            throw ProPackageError.writeFailed(failure.errorDescription ?? "")
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProPackageError.writeFailed("The file could not be saved.")
        }
    }

    // MARK: - Image dimensions

    /// Reads an image's pixel dimensions from its header, without decoding the
    /// pixels.
    public static func pixelSize(ofImageAt url: URL) -> PixelSize? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return PixelSize(width: width, height: height)
        #else
        return nil
        #endif
    }
}