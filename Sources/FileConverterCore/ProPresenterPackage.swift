import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Turns a converted deck's JPEGs into a ProPresenter bundle: one `.probundle`
/// file that opens as a named presentation with every image already attached.
///
/// A `.probundle` is a ZIP holding the `.pro` manifest plus the images it refers
/// to, with the manifest pointing at them *relative to the bundle*. That
/// self-containment is the whole point: the bundle can be moved, mailed, put on
/// a stick, or dragged anywhere, and the images still resolve.
///
/// A bare `.pro` manifest is deliberately not produced. The format has no field
/// for image data anywhere in its media path, so a `.pro` can only ever point at
/// images already sitting at a fixed path on the machine that made it — useless
/// to anyone it is sent to. Bundles are the only form worth writing.
///
/// Bundles are written to `BinStorage.packagesDirectory`, not into the deck's
/// own folder, so `scanBin` cannot mistake one for a deck and clearing the bin
/// has a single obvious meaning.
public enum ProPresenterPackage {

    /// The extension ProPresenter gives these.
    public static let fileExtension = "probundle"

    // MARK: - Packaging

    /// Packages `group` and returns the bundle written.
    ///
    /// - Parameters:
    ///   - group: the converted deck to package.
    ///   - destinationDirectory: where to write the bundle. Defaults to the
    ///     bin's `Packages` folder.
    ///   - pixelSize: resolves an image's dimensions. Injectable so the writer
    ///     can be tested without decoding real images.
    @discardableResult
    public static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.packagesDirectory,
        pixelSize: (URL) -> PixelSize?
    ) throws -> URL {
        let images = group.imageURLs
        guard !images.isEmpty else {
            throw ProPackageError.noImages(group.sourceName)
        }

        let name = presentationName(for: group)
        let slides = try images.map { url -> ProSlide in
            guard let size = pixelSize(url) else {
                throw ProPackageError.unreadableImage(url.lastPathComponent)
            }
            return ProSlide(imageURL: url, pixelSize: size)
        }

        let destination = destinationDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension)

        do {
            let archive = try ZipArchiveWriter(to: destination)
            try archive.addEntry(path: "\(name).pro", data: manifest(for: slides, name: name))
            // Flat filenames at the ZIP root, which is what the manifest's
            // ROOT_CURRENT_RESOURCE paths refer to. A nested `Media/Assets/`
            // folder imports with nothing visible.
            for slide in slides {
                try archive.addFile(at: slide.imageURL, path: slide.imageURL.lastPathComponent)
            }
            try archive.close()
        } catch let failure as ZipArchiveWriter.Failure {
            throw ProPackageError.writeFailed(failure.errorDescription ?? "")
        }
        return destination
    }

    /// Convenience overload that reads each image's real pixel dimensions.
    @discardableResult
    public static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.packagesDirectory
    ) throws -> URL {
        try package(group: group, destinationDirectory: destinationDirectory, pixelSize: pixelSize(ofImageAt:))
    }

    // MARK: - Naming

    /// The presentation's name, and the filename of the manifest inside the
    /// bundle. A deck's folder is called `Name JPEGs`, so strip that suffix to
    /// get back to the document's own name.
    static func presentationName(for group: ConversionGroup) -> String {
        let folder = group.sourceName
        let suffix = " JPEGs"
        guard folder.hasSuffix(suffix) else { return folder }
        let trimmed = String(folder.dropLast(suffix.count))
        return trimmed.isEmpty ? folder : trimmed
    }

    // MARK: - Manifest

    private static func manifest(for slides: [ProSlide], name: String) -> Data {
        ProPresenterDocument.encode(name: name, slides: slides)
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