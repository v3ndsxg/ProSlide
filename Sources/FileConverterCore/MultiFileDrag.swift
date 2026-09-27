import Foundation
import UniformTypeIdentifiers

/// Builds the single drag item that carries a whole set of files.
///
/// `NSItemProvider(contentsOf:)` accepts one `URL`, but a multi-file drag has to
/// arrive as a single item, so a list is written into a `public.file-url`
/// representation as a property-list array — the shape a Finder multi-selection
/// drag puts on the pasteboard. A single URL keeps the plain file
/// representation instead.
///
/// This lives in the library rather than in ContentView for the same reason
/// ConversionQueue does: the payload round trip is then assertable by
/// `swift test` and CI, with no window. What those tests cannot prove is that a
/// receiving application imports every URL rather than just the first.
public enum MultiFileDrag {
    /// One item provider for `urls`, which must not be empty for the result to
    /// be useful. Returns an empty provider when it is.
    public static func itemProvider(for urls: [URL]) -> NSItemProvider {
        guard let first = urls.first else { return NSItemProvider() }
        if urls.count == 1 {
            return NSItemProvider(contentsOf: first) ?? singleURLFallback(for: first)
        }

        // NSItemProvider honours only the first representation registered for a
        // given type identifier, so this has to start from an empty provider
        // rather than one that already carries a public.file-url
        // representation -- a second registration for the same type is ignored.
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName(for: first)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion -> Progress? in
            // The explicit return type is load-bearing: the SDK overloads this
            // method, and only the Progress-returning variant takes a handler
            // of this shape.
            do {
                // Written as plain strings rather than URL values: a plist
                // round-trip hands back NSString, so a receiver reading
                // public.file-url gets file-URL strings it can parse directly
                // instead of depending on NSURL-in-plist bridging.
                let data = try PropertyListSerialization.data(
                    fromPropertyList: urls.map(\.absoluteString),
                    format: .binary,
                    options: 0
                )
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        return provider
    }

    private static func singleURLFallback(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = suggestedName(for: url)
        return provider
    }

    private static func suggestedName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
