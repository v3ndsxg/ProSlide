import AppKit

/// The only AppKit the app target needs: revealing a folder in Finder.
/// Everything else ProSlide does is filesystem work and lives in
/// FileConverterCore, where it is covered by tests.
enum BinOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
