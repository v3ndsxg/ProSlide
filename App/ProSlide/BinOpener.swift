import AppKit

/// The only AppKit the app target needs: showing things in Finder.
/// Everything else ProSlide does is filesystem work and lives in
/// FileConverterCore, where it is covered by tests.
enum BinOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Selects `url` in a Finder window rather than opening it.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
