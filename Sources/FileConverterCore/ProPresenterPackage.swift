import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Turns a converted deck's JPEGs into a ProPresenter presentation: one `.pro`
/// file that opens as a named presentation with every image already attached.
///
/// The `.pro` is written into the deck's own folder, beside the JPEGs, and points
/// at them by bare filename. That is what makes a single drag into ProPresenter
/// bring in the whole deck, and it is also what keeps the manifest's media URLs
/// resolvable: the deck folder is the resource the `.pro` is in.
///
/// The trade-off is that this is not self-contained. Moving the `.pro` away from
/// its JPEGs, or mailing it on its own, leaves ProPresenter pointing at images
/// that are no longer there. Copy the whole folder, or use **Save…** to put the
/// images somewhere durable.
///
/// Presentations are written into each deck's folder rather than a shared one, so
/// clearing the bin takes them with it and rescanning the bin ignores them (it
/// only looks at `.jpg`).
public enum ProPresenterPackage {

    /// The extension ProPresenter gives these.
    public static let fileExtension = "pro"

    // MARK: - Packaging

    /// Writes the presentation for `group` and returns the file written.
    ///
    /// - Parameters:
    ///   - group: the converted deck to package.
    ///   - pixelSize: resolves an image's dimensions. Injectable so the writer
    ///     can be tested without decoding real images.
    @discardableResult
    public static func package(
        group: ConversionGroup,
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

        let destination = group.folderURL
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
    public static func package(group: ConversionGroup) throws -> URL {
        try package(group: group, pixelSize: pixelSize(ofImageAt:))
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