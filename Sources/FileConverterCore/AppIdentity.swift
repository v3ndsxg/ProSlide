import Foundation

/// Which build of ProSlide is running: the production app or the beta.
///
/// The packaging script writes these values into Info.plist, so the same Swift
/// code serves both builds and a merge between branches never has to touch it.
/// Anything not stamped, such as `swift test` or a raw `swift run`, is the
/// production app.
public struct AppIdentity: Sendable {
    public static let productionDataFolder = "ProSlide"

    /// The name shown in the window, taken from `CFBundleDisplayName`.
    public let displayName: String
    /// The folder under Documents that holds this build's bin and presentations.
    public let dataFolderName: String
    public let isBeta: Bool

    /// Only the production app may adopt decks from the old Application Support
    /// location. A beta doing it would take them out of the production bin.
    public var ownsLegacyBin: Bool { !isBeta }

    public static let current = AppIdentity(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        displayName = info["CFBundleDisplayName"] as? String ?? "ProSlide"
        dataFolderName = info["ProSlideDataFolder"] as? String ?? AppIdentity.productionDataFolder
        isBeta = info["ProSlideIsBeta"] as? Bool ?? false
    }
}
