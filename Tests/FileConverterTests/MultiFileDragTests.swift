@testable import FileConverterCore
import UniformTypeIdentifiers
import XCTest

/// The drag payload is built in FileConverterCore so it can be checked here
/// instead of only ever being exercised by a real drag into another app.
///
/// The limitation is deliberate and worth stating: these tests prove the
/// provider advertises `public.file-url` and that the bytes handed to a
/// receiver round-trip back to the same URLs in order. They cannot prove that
/// the receiving application (ProPresenter) imports every URL rather than the
/// first. That still needs a manual drag.
final class MultiFileDragTests: XCTestCase {

    func testMultipleURLsBecomeASingleItemCarryingEveryURL() throws {
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map(fileURL)
        let provider = MultiFileDrag.itemProvider(for: urls)

        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.fileURL.identifier],
                       "the array payload must be the only representation, or the first-registered wins")

        let box = DataBox()
        let loaded = expectation(description: "payload loaded")
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
        ) { data, error in
            box.value = data
            box.error = error
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)

        XCTAssertNil(box.error)
        let payload = try XCTUnwrap(box.value, "a registered representation must produce data")
        let paths = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String]
        )
        XCTAssertEqual(paths, urls.map(\.absoluteString), "every URL must survive, in order")
    }

    func testSingleURLKeepsAFileURLRepresentation() {
        let provider = MultiFileDrag.itemProvider(for: [fileURL("only.jpg")])

        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
            "a lone file must still be draggable; got \(provider.registeredTypeIdentifiers)"
        )
    }

    func testNoURLsProducesAnEmptyProviderRatherThanACrash() {
        XCTAssertTrue(MultiFileDrag.itemProvider(for: []).registeredTypeIdentifiers.isEmpty)
    }

    func testSuggestedNameOmitsTheFileExtension() {
        let provider = MultiFileDrag.itemProvider(for: [fileURL("deck.pdf"), fileURL("two.jpg")])
        XCTAssertEqual(provider.suggestedName, "deck")
    }

    private func fileURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }
}

/// The load callback is `@Sendable`, so the result is parked in a reference type
/// rather than a captured `var`.
private final class DataBox: @unchecked Sendable {
    var value: Data?
    var error: Error?
}
