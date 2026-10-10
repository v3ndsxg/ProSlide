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
/// beside a deck's JPEGs turns a JPEG-folder drag into a presentation import.
///
/// The images are *linked* into ProPresenter's own media tree first, at
/// `Media/Imported/…` under its document root, which is exactly where
/// `Fixtures/real.pro` records its own media living. A link is a second name for
/// the same bytes, so the deck's JPEGs are still written once, in the bin, and
/// ProPresenter's tree only adds a directory entry — a 300-page deck costs one
/// set of files rather than two. Where the volume forbids a link (a ProPresenter
/// library on another disk, say) it falls back to copying, which costs the bytes
/// but keeps the presentation readable.
///
/// The trade-off is that a `.pro` is tied to the machine whose ProPresenter
/// library holds it. Moving it elsewhere, or clearing the bin, leaves it naming
/// media that is no longer staged; the JPEG Folder drag is the portable option.
public enum ProPresenterPackage {

    /// The extension ProPresenter gives these.
    public static let fileExtension = "pro"

    /// Places one image at its staged path. Defaults to a hard link, which adds
    /// a directory entry and no bytes; tests inject one that fails, to reach the
    /// copy fallback.
    typealias MediaLinker = (URL, URL) throws -> Void

    // MARK: - Packaging

    /// Writes the presentation for `group` and returns the file written.
    ///
    /// - Parameters:
    ///   - group: the converted deck to package.
    ///   - destinationDirectory: where to write the `.pro`. Defaults to the
    ///     `Pro` folder alongside the bin.
    ///   - showRoot: ProPresenter's document root. Each slide is linked into its
    ///     `Media/Imported` tree and named from there.
    ///   - pixelSize: resolves an image's dimensions. Injectable so the writer
    ///     can be tested without decoding real images.
    ///   - linkMedia: places one staged image. Injectable so the copy fallback
    ///     can be tested.
    @discardableResult
    static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.presentationsDirectory,
        showRoot: URL = ProPresenterInstallation.defaultDocumentRoot,
        pixelSize: (URL) -> PixelSize?,
        linkMedia: MediaLinker = ProPresenterPackage.link
    ) throws -> URL {
        let images = group.imageURLs
        guard !images.isEmpty else {
            throw ProPackageError.noImages(group.sourceName)
        }

        // Read the dimensions before anything is staged, so a deck that cannot
        // be measured is reported as such rather than as a ProPresenter
        // problem, and nothing is linked on its behalf.
        let slides = try images.map { url -> ProSlide in
            guard let size = pixelSize(url) else {
                throw ProPackageError.unreadableImage(url.lastPathComponent)
            }
            return ProSlide(imageURL: url, pixelSize: size)
        }

        guard ProPresenterInstallation.isUsable(root: showRoot) else {
            throw ProPackageError.showRootUnavailable(showRoot.path)
        }

        let staged = try stage(slides: slides, group: group, in: showRoot, linkMedia: linkMedia)
        let name = presentationName(for: group)
        let manifest = ProPresenterDocument.encode(name: name, slides: staged, showRoot: showRoot)

        let destination = destinationDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension)
        do {
            try manifest.write(to: destination, options: .atomic)
        } catch {
            throw ProPackageError.writeFailed("The file could not be saved.")
        }
        return destination
    }

    /// Convenience overload that reads each image's real pixel dimensions, and
    /// resolves ProPresenter's own document root.
    ///
    /// `showRoot` is exposed so tests can name a definite root; production wants
    /// the real one.
    @discardableResult
    public static func package(
        group: ConversionGroup,
        destinationDirectory: URL = BinStorage.presentationsDirectory,
        showRoot: URL = ProPresenterInstallation.defaultDocumentRoot
    ) throws -> URL {
        try package(
            group: group,
            destinationDirectory: destinationDirectory,
            showRoot: showRoot,
            pixelSize: pixelSize(ofImageAt:)
        )
    }

    // MARK: - Staging

    /// Links every slide into `showRoot`'s media tree and returns the slides
    /// renamed to their staged locations, in the same order.
    ///
    /// The deck's folder is replaced rather than reused. A deck whose JPEGs
    /// changed since the last build must not leave earlier links behind, and
    /// ProPresenter would otherwise be offered media the presentation no longer
    /// names. Replacing it also keeps the number of names ProPresenter sees
    /// equal to the number of slides, whatever has been rebuilt.
    private static func stage(
        slides: [ProSlide],
        group: ConversionGroup,
        in showRoot: URL,
        linkMedia: MediaLinker
    ) throws -> [ProSlide] {
        let deck = stagedMediaDirectory(for: group, in: showRoot)
        do {
            // Only exists on a rebuild, so its absence is not a failure.
            if FileManager.default.fileExists(atPath: deck.path) {
                try FileManager.default.removeItem(at: deck)
            }
            let item = deck.appendingPathComponent(newMediaItemIdentifier(), isDirectory: true)
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            return try slides.map { slide in
                let staged = item.appendingPathComponent(slide.imageURL.lastPathComponent)
                try place(slide.imageURL, at: staged, linkMedia: linkMedia)
                return ProSlide(imageURL: staged, pixelSize: slide.pixelSize, label: slide.label)
            }
        } catch {
            // Half a staged deck is worse than none: ProPresenter would read
            // some slides and not others. Leave the tree as it was found.
            try? FileManager.default.removeItem(at: deck)
            throw (error as? ProPackageError) ?? ProPackageError.stageFailed(error.localizedDescription)
        }
    }

    /// Links `image` to `staged`, falling back to a copy where the two cannot
    /// share an inode.
    private static func place(_ image: URL, at staged: URL, link: MediaLinker) throws {
        do {
            try link(image, staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            do {
                try FileManager.default.copyItem(at: image, to: staged)
            } catch {
                throw ProPackageError.stageFailed(image.lastPathComponent)
            }
        }
    }

    /// A hard link: a second directory entry naming the same inode. The bytes
    /// live in the bin; ProPresenter's media folder only records where else to
    /// find them.
    private static func link(from: URL, to: URL) throws {
        try FileManager.default.linkItem(at: from, to: to)
    }

    /// `<showRoot>/Media/Imported/<deckID>`: where a deck's staged media lives.
    ///
    /// Reachable without state, so both `Rebuild` (which replaces it) and
    /// `Clear` (which removes it) find the same folder.
    static func stagedMediaDirectory(
        for group: ConversionGroup,
        in showRoot: URL = ProPresenterInstallation.defaultDocumentRoot
    ) -> URL {
        showRoot
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(mediaDeckIdentifier(for: group), isDirectory: true)
    }

    /// A stable identifier for a deck's folder in ProPresenter's media tree,
    /// derived from the deck's own path.
    ///
    /// Deterministic so a rebuild lands in the same place and clearing the bin
    /// can find the folder again without having remembered where it wrote. It is
    /// shaped like a UUID only because that is the shape ProPresenter gives its
    /// own media folders; it is a hash, not an identity anyone needs to read.
    static func mediaDeckIdentifier(for group: ConversionGroup) -> String {
        let path = group.folderURL.standardizedFileURL.path
        let high = stableHash(path, salt: 0)
        let low = stableHash(path + "/media", salt: 0x9e3779b97f4a7c15)
        let digits = hexadecimal(high, digits: 16) + hexadecimal(low, digits: 16)
        var parts: [Substring] = []
        var start = digits.startIndex
        for length in [8, 4, 4, 4, 12] {
            let end = digits.index(start, offsetBy: length)
            parts.append(digits[start..<end])
            start = end
        }
        return parts.map(String.init).joined(separator: "-")
    }

    /// FNV-1a over the string's UTF-8 bytes. Chosen for being two lines and
    /// having no dependency to match: the value only has to be stable for a
    /// given path, and different between different paths.
    private static func stableHash(_ string: String, salt: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325 &+ salt
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash
    }

    private static func hexadecimal(_ value: UInt64, digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    private static func newMediaItemIdentifier() -> String {
        UUID().uuidString.uppercased()
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
