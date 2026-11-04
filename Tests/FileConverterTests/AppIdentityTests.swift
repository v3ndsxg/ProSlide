@testable import FileConverterCore
import XCTest

/// The beta is a separate app because the packaging script stamps its identity
/// into Info.plist. These tests pin the two halves of that contract: an
/// unstamped process is the production app, and a stamped one is the beta.
final class AppIdentityTests: XCTestCase {

    /// `swift test` runs inside xctest, which carries none of the stamped keys.
    /// If this ever reported the beta, the suite would read and write the
    /// beta's Documents folder.
    func testUnstampedProcessIsTheProductionApp() {
        let identity = AppIdentity.current
        XCTAssertFalse(identity.isBeta)
        XCTAssertEqual(identity.dataFolderName, AppIdentity.productionDataFolder)
        XCTAssertTrue(identity.ownsLegacyBin)
    }

    func testStampedBundleIsTheBeta() throws {
        let identity = AppIdentity(bundle: try makeBundle([
            "CFBundleDisplayName": "ProSlide Beta",
            "ProSlideDataFolder": "ProSlide Beta",
            "ProSlideIsBeta": true,
        ]))
        XCTAssertTrue(identity.isBeta)
        XCTAssertEqual(identity.displayName, "ProSlide Beta")
        XCTAssertEqual(identity.dataFolderName, "ProSlide Beta")
        XCTAssertFalse(identity.ownsLegacyBin, "the beta must not adopt the production app's old decks")
    }

    func testStampedProductionBundleKeepsTheOriginalFolder() throws {
        let identity = AppIdentity(bundle: try makeBundle([
            "CFBundleDisplayName": "ProSlide",
            "ProSlideDataFolder": "ProSlide",
            "ProSlideIsBeta": false,
        ]))
        XCTAssertFalse(identity.isBeta)
        XCTAssertEqual(identity.dataFolderName, "ProSlide")
        XCTAssertTrue(identity.ownsLegacyBin)
    }

    private func makeBundle(_ info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIdentityTests-\(UUID().uuidString).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }
}
