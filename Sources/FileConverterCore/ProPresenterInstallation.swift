import Foundation

/// Where ProPresenter keeps its documents, media and configuration.
///
/// Media inside a `.pro` is named by a path relative to this root, using
/// `ROOT_SHOW`, and ProSlide *links* its decks into this root's `Media` tree so
/// the names resolve. ProPresenter's default is `~/Documents/ProPresenter`, but
/// it is configurable in the app, so the location is discovered rather than
/// assumed.
public enum ProPresenterInstallation {
    /// ProPresenter's document root: the folder holding `Libraries`, `Media`
    /// and `Configuration`.
    ///
    /// Discovery order:
    ///
    /// 1. `PathSettings.proPaths`, which records `Base=<path>` and is what
    ///    ProPresenter itself reads on Windows. Cheap to check, and authoritative
    ///    when the user has moved their installation.
    /// 2. `~/Documents/ProPresenter`, the macOS default.
    ///
    /// Nothing is created and nothing is written: a missing installation simply
    /// yields the default, which is where a fresh install puts it.
    public static var defaultDocumentRoot: URL {
        if let configured = configuredDocumentRoot() { return configured }
        return fallbackDocumentRoot
    }

    /// `~/Documents/ProPresenter`, ProPresenter's stock macOS location.
    public static var fallbackDocumentRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ProPresenter", isDirectory: true)
    }

    /// Whether ProPresenter appears to be installed at all.
    ///
    /// Unused for now: a deck's presentation is attempted either way, and a
    /// missing library is reported when the staging has somewhere to write to —
    /// which is the only point it can be judged. The JPEG Folder drag works
    /// regardless.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: fallbackDocumentRoot.path)
            || configuredDocumentRoot() != nil
    }

    /// Whether ProSlide may stage a deck's media into `root`: it exists, it is a
    /// folder, and it accepts new files.
    ///
    /// ProSlide never creates this folder. A `Media/Imported` tree anywhere else
    /// is media nobody will read, so a root that is not already there is
    /// reported rather than quietly built — the alternative is a presentation
    /// full of placeholders with no explanation attached.
    public static func isUsable(root: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder),
              isFolder.boolValue
        else { return false }
        return FileManager.default.isWritableFile(atPath: root.path)
    }

    private static func configuredDocumentRoot() -> URL? {
        // The settings file sits in the application-support area on macOS and in
        // AppData on Windows; check the macOS location and let the default cover
        // the rest.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProPresenter/PathSettings.proPaths", isDirectory: false)
        guard let support, let text = try? String(contentsOf: support, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Base=") }) else {
            return nil
        }
        let path = line.dropFirst("Base=".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}