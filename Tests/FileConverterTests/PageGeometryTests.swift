import CoreGraphics
import FileConverterCore
import ImageIO
import PDFKit
import XCTest

/// Pages that are not simply their media box: rotated pages and pages with a
/// crop box. Both used to render wrong — a rotated page came out the wrong shape
/// with its content clipped away, and a cropped page showed everything outside
/// the crop, bleed and printer's marks included.
///
/// Every page is 800x450 with a red square in its top-left and a blue one in its
/// bottom-left (PDF space is y-up), so where each colour lands says exactly what
/// transform was applied.
final class PageGeometryTests: XCTestCase {

    private enum Colour: Equatable { case red, blue, white, other }

    func testAnUnmodifiedPageKeepsItsCorners() async throws {
        let image = try await render { _ in }
        XCTAssertEqual(image.size, [1920, 1080])
        XCTAssertEqual(image.topLeft, .red)
        XCTAssertEqual(image.bottomLeft, .blue)
        XCTAssertEqual(image.topRight, .white)
    }

    /// A clockwise quarter turn makes the page portrait: the top-left square
    /// moves to the top-right and the bottom-left square to the top-left.
    func testAPageRotated90IsPortraitAndUpright() async throws {
        let image = try await render { $0.rotation = 90 }
        XCTAssertEqual(image.size, [1920, 3413], "portrait, scaled to the preset width")
        XCTAssertEqual(image.topLeft, .blue)
        XCTAssertEqual(image.topRight, .red)
        XCTAssertEqual(image.bottomLeft, .white)
    }

    func testAPageRotated270IsPortraitAndUpright() async throws {
        let image = try await render { $0.rotation = 270 }
        XCTAssertEqual(image.size, [1920, 3413])
        XCTAssertEqual(image.topLeft, .white)
        XCTAssertEqual(image.bottomLeft, .red)
        XCTAssertEqual(image.bottomRight, .blue)
    }

    func testAPageRotated180IsTurnedOver() async throws {
        let image = try await render { $0.rotation = 180 }
        XCTAssertEqual(image.size, [1920, 1080])
        XCTAssertEqual(image.topRight, .blue)
        XCTAssertEqual(image.bottomRight, .red)
        XCTAssertEqual(image.topLeft, .white)
    }

    /// Only the crop box is shown. This one keeps the bottom-left 600x250, which
    /// holds the blue square and leaves the red one outside.
    func testAPageIsCroppedToItsCropBox() async throws {
        let image = try await render {
            $0.setBounds(CGRect(x: 0, y: 0, width: 600, height: 250), for: .cropBox)
        }
        XCTAssertEqual(image.size, [1920, 800])
        XCTAssertEqual(image.bottomLeft, .blue)
        XCTAssertEqual(image.topLeft, .white, "the red square is outside the crop box")
    }

    /// A crop box that does not start at the origin: the red square sits in its
    /// top-left, and the blue one is below it and outside.
    func testACropBoxThatDoesNotStartAtTheOriginIsHonoured() async throws {
        let image = try await render {
            $0.setBounds(CGRect(x: 0, y: 200, width: 600, height: 250), for: .cropBox)
        }
        XCTAssertEqual(image.size, [1920, 800])
        XCTAssertEqual(image.topLeft, .red)
        XCTAssertEqual(image.bottomLeft, .white, "the blue square is outside the crop box")
    }

    func testACroppedAndRotatedPageIsBoth() async throws {
        let image = try await render {
            $0.setBounds(CGRect(x: 0, y: 200, width: 600, height: 250), for: .cropBox)
            $0.rotation = 90
        }
        XCTAssertEqual(image.size, [1920, 4608], "250x600 turned portrait")
        XCTAssertEqual(image.topRight, .red)
        XCTAssertEqual(image.topLeft, .white)
    }

    // MARK: - Harness

    private struct Rendered {
        let size: [Int]
        let topLeft: Colour
        let topRight: Colour
        let bottomLeft: Colour
        let bottomRight: Colour
    }

    private func render(_ adjust: (PDFPage) -> Void) async throws -> Rendered {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageGeometryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.pdf")
        try writeSourcePDF(to: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        adjust(try XCTUnwrap(document.page(at: 0)))
        let adjusted = directory.appendingPathComponent("page.pdf")
        XCTAssertTrue(document.write(to: adjusted))

        var options = ConversionOptions()
        options.destination = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        let output = try await ConversionEngine().convert(input: adjusted, options: options) { _ in }
        let jpeg = try XCTUnwrap(ConversionGroup.exportedImages(in: output).first)
        return try sample(jpeg)
    }

    private func writeSourcePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 800, height: 450)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 400, width: 50, height: 50))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
    }

    private func sample(_ url: URL) throws -> Rendered {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Row 0 is the visual top. Sample a little inside each corner, where the
        // squares (50pt, scaled up) are, clear of JPEG ringing at their edges.
        func colour(_ x: Int, _ y: Int) -> Colour {
            let offset = (y * width + x) * 4
            let (r, g, b) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            if r > 200, g > 200, b > 200 { return .white }
            if r > 200, g < 80, b < 80 { return .red }
            if b > 200, r < 80, g < 80 { return .blue }
            return .other
        }
        return Rendered(
            size: [width, height],
            topLeft: colour(10, 10),
            topRight: colour(width - 11, 10),
            bottomLeft: colour(10, height - 11),
            bottomRight: colour(width - 11, height - 11)
        )
    }
}
