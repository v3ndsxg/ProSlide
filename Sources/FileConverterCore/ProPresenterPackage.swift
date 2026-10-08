import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Turns a converted deck's JPEGs into a ProPresenter presentation: one `.pro`
/// file that opens as a named presentation with every image already attached.
///
/// The `.pro` is written to `destinationDirectory` — the bin's `Pro` folder — not
/// into the deck's own folder. ProPresenter imports a folder containing a `.pro`
/// as a presentation rather than as a sequence of slides, so a `.pro` left
/// beside a deck's JPEGs turns a JPEG-folder drag into a presentation import. The
/// two locations need not agree: media paths in a `.pro` are relative to the home
/// folder, not to the file itself.
///
/// The trade-off is that a `.pro` is not self-contained and not portable. It
/// resolves only on this machine, for this account, and stops working if the
/// images move. The format has nowhere to put image data, so there is no
/// single-file alternative; **Save…** puts the images somewhere durable.
public enum ProPresenterPackage {

    /// The extension ProPresenter gives these.
    public static let fileExtension = "pro"

    // MARK: - Packaging

    /// Writes the presentation for `group` and returns the file written.
    ///
    /// - Parameters:
    ///   - group: the converted deck to package.
    ///   - destinationDirectory: where to write the `.pro`. Defaults to the
    ///     `Pro` folder alongside the bin.
    ///   - pixelSize: resolves an image's dimensions. Injectable so the writer
    ///     can be tested without decoding real images.
    @discardableResult
    public static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.presentationsDirectory,
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

        let manifest = ProPresenterDocument.encode(name: name, slides: slides)
        do {
            try manifest.write(to: destination, options: .atomic)
        } catch {
            throw ProPackageError.writeFailed("The file could not be saved.")
        }
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

    // MARK: - Naming

    /// The presentation's name, and the filename of the `.pro`.
    /// A deck's folder is called `Name JPEGs`, so strip that suffix to
    /// get back to the document's own name.
    static func presentationName(for group: ConversionGroup) -> String {
        let folder = group.sourceName
        let suffix = " JPEGs"
        guard folder.hasSuffix(suffix) else { return folder }
        let trimmed = String(folder.dropLast(suffix.count))
        return trimmed.isEmpty ? folder : trimmed
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