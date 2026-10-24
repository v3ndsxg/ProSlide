import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Turns a converted deck's JPEGs into a ProPresenter bundle: one `.probundle`
/// that imports as a named presentation with every image inside it.
///
/// A bundle is a zip holding `<Name>.pro` and the images under `Media/Assets/`.
/// The manifest names each image relative to the bundle, so the file works on
/// any machine and after the bin is cleared: on import ProPresenter copies the
/// images into its own media store, with media management on or off.
///
/// ProSlide never reads, writes or deletes anything in ProPresenter's own
/// folders. The bundle is the whole hand-over.
///
/// The bundle is written to `destinationDirectory` — the bin's `Pro` folder —
/// not into the deck's own folder. ProPresenter imports a folder containing a
/// presentation as a presentation rather than as a sequence of slides, so a
/// bundle left beside a deck's JPEGs would turn a JPEG-folder drag into a
/// presentation import.
///
/// The cost is space: the bundle holds a second copy of the deck's JPEGs.
public enum ProPresenterPackage {

    /// The extension ProPresenter gives these.
    public static let fileExtension = "probundle"

    /// Appended while a bundle is being written. A bundle is only ever seen
    /// under its real name once it is complete, so one cut short by a crash or
    /// a quit is never offered as finished.
    static let partialExtension = "partial"

    // MARK: - Packaging

    /// Writes the bundle for `group` and returns the file written.
    ///
    /// - Parameters:
    ///   - group: the converted deck to package.
    ///   - destinationDirectory: where to write the bundle. Defaults to the
    ///     `Pro` folder alongside the bin.
    ///   - pixelSize: resolves an image's dimensions. Injectable so the writer
    ///     can be tested without decoding real images.
    @discardableResult
    static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.presentationsDirectory,
        pixelSize: (URL) -> PixelSize?
    ) throws -> URL {
        let images = group.imageURLs
        guard !images.isEmpty else {
            throw ProPackageError.noImages(group.sourceName)
        }

        let slides = try images.map { url -> ProSlide in
            guard let size = pixelSize(url) else {
                throw ProPackageError.unreadableImage(url.lastPathComponent)
            }
            return ProSlide(imageURL: url, pixelSize: size)
        }

        let name = presentationName(for: group)
        let manifest = ProPresenterDocument.encode(name: name, slides: slides)
        var entries = [ZipWriter.Entry(name: name + ".pro", source: .data(manifest))]
        for slide in slides {
            entries.append(ZipWriter.Entry(
                name: ProPresenterDocument.mediaPath(for: slide.imageURL.lastPathComponent),
                source: .file(slide.imageURL)
            ))
        }

        let destination = bundleURL(for: group, in: destinationDirectory)
        let partial = destination.appendingPathExtension(partialExtension)
        do {
            // Clear deletes this folder, so it is made again here rather than
            // assumed. Every bundle written after a Clear once failed for want of it.
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try ZipWriter.write(entries, to: partial)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            switch error {
            case ZipWriter.ZipError.tooLarge: throw ProPackageError.tooLarge
            case ZipWriter.ZipError.unreadable(let file): throw ProPackageError.unreadableImage(file)
            default: throw ProPackageError.writeFailed("The file could not be saved.")
            }
        }

        // A `.pro` from before bundles. It names media ProSlide no longer stages,
        // so leaving it beside the bundle would only offer a broken file.
        try? FileManager.default.removeItem(
            at: destinationDirectory.appendingPathComponent(name).appendingPathExtension("pro")
        )
        return destination
    }

    /// Convenience overload that reads each image's real pixel dimensions.
    @discardableResult
    public static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.presentationsDirectory
    ) throws -> URL {
        try package(group: group, destinationDirectory: destinationDirectory, pixelSize: pixelSize(ofImageAt:))
    }

    /// `group`'s bundle if one has already been written, so a launch can offer it
    /// without building anything. A `.partial` left by an interrupted build has a
    /// different name and is never returned.
    public static func existingBundle(
        for group: ConversionGroup,
        in directory: URL = BinStorage.presentationsDirectory
    ) -> URL? {
        let url = bundleURL(for: group, in: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func bundleURL(for group: ConversionGroup, in directory: URL) -> URL {
        directory
            .appendingPathComponent(presentationName(for: group))
            .appendingPathExtension(fileExtension)
    }

    // MARK: - Naming

    /// The presentation's name, and the filename of the bundle: the converted
    /// document's own name, whatever copy number its folder in the bin carries.
    static func presentationName(for group: ConversionGroup) -> String {
        group.documentName
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
