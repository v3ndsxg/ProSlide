import CoreGraphics
import FileConverterCore
import ImageIO
import XCTest

final class EngineSmokeTests: XCTestCase {

    /// sample.pdf is a 1280x720 (16:9) page with a solid black square in
    /// the visual top-left corner (PDF y-up space) and a gray square
    /// bottom-right. After rendering, the black square must appear at the
    /// image's top-left; any flip/mirror in the render transform moves it
    /// and the corner assertions below fail.
    func testPDFConversionProducesUprightJPEGs() async throws {
        for preset in ResolutionPreset.allCases {
            try await assertConversionOf(
                kind: "pdf", file: "sample.pdf", preset: preset,
                canvasWidth: 1280, canvasHeight: 720
            )
        }
    }

    /// sample.pptx is a single blank 16:9 slide (13.33x7.5 in) with a
    /// black rectangle in its top-left. The full chain — LibreOffice ->
    /// PDF -> JPEG — must keep that rectangle at the JPEG's top-left.
    func testPPTXConversionProducesUprightJPEGs() async throws {
        try XCTSkipUnless(hasLibreOffice(), "LibreOffice is not installed; skipping PPTX path")
        for preset in ResolutionPreset.allCases {
            try await assertConversionOf(
                kind: "pptx", file: "sample.pptx", preset: preset,
                canvasWidth: 960, canvasHeight: 540
            )
        }
    }

    @MainActor
    func testBadExtensionThrowsUnsupportedFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/sample.exe")
        do {
            _ = try await ConversionEngine().convert(input: url, options: ConversionOptions()) { _ in }
            XCTFail("expected unsupportedFile to be thrown")
        } catch {
            XCTAssertEqual(error as? ConversionError, .unsupportedFile)
        }
    }

    /// A hostile PDF declaring a pathological page aspect ratio (tiny width,
    /// enormous height) must not scale up into a multi-gigabyte bitmap.
    /// render() clamps both output sides to at most 8192 px.
    func testPathologicalPDFDimensionsAreClamped() async throws {
        let pdf = try makePathologicalPDF(pageWidth: 200, pageHeight: 100_000)
        defer { try? FileManager.default.removeItem(at: pdf) }

        try await withTempDirectory { directory in
            var options = ConversionOptions()
            options.resolution = .fullHD
            options.destination = directory

            let output = try await ConversionEngine().convert(input: pdf, options: options) { _ in }
            let probe = try probeCorners(of: try XCTUnwrap(jpegURLs(in: output).first))

            XCTAssertGreaterThan(probe.width, 0)
            XCTAssertGreaterThan(probe.height, 0)
            XCTAssertLessThanOrEqual(probe.width, 8192, "width must be clamped to 8192")
            XCTAssertLessThanOrEqual(probe.height, 8192, "height must be clamped to 8192")
        }
    }

    private func assertConversionOf(
        kind: String, file: String, preset: ResolutionPreset,
        canvasWidth: Int, canvasHeight: Int
    ) async throws {
        try await withTempDirectory { directory in
            var options = ConversionOptions()
            options.resolution = preset
            options.destination = directory

            let output = try await ConversionEngine().convert(
                input: fixture(named: file),
                options: options
            ) { _ in }

            let images = jpegURLs(in: output)
            XCTAssertEqual(images.count, 1, "[\(preset.rawValue)] expected a single JPEG")
            let probe = try probeCorners(of: try XCTUnwrap(images.first))

            let expectedWidth = preset.pixelWidth
            let expectedHeight = Int((Double(canvasHeight) * Double(preset.pixelWidth) / Double(canvasWidth)).rounded())
            XCTAssertEqual(probe.width, expectedWidth, "[\(preset.rawValue)] JPEG width")
            XCTAssertEqual(probe.height, expectedHeight, "[\(preset.rawValue)] JPEG height")

            exportArtifacts(from: output, label: "\(kind)-\(preset)")

            XCTAssertLessThan(probe.topLeft, 0.4,
                              "[\(preset.rawValue)] black marker should be at the visual top-left; got \(probe.topLeft)")
            XCTAssertGreaterThan(probe.bottomLeft, 0.8,
                                 "[\(preset.rawValue)] visual bottom-left should be white; got \(probe.bottomLeft)")
            XCTAssertGreaterThan(probe.topRight, 0.8,
                                 "[\(preset.rawValue)] visual top-right should be white; got \(probe.topRight)")
        }
    }

    private struct CornerProbe {
        let width: Int
        let height: Int
        let topLeft: Double
        let bottomLeft: Double
        let topRight: Double
    }

    /// Decode the JPEG via ImageIO, draw it into a fresh RGBA bitmap
    /// context, and read the raw bytes where row 0 is always the visual
    /// top of the image (the standard CGImage roundtrip is orientation
    /// preserving). This avoids NSBitmapImageRep coordinate quirks, so the
    /// assertions describe exactly what a viewer/ProPresenter will show.
    private func probeCorners(of url: URL) throws -> CornerProbe {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        var drew = false
        var topLeft = 0.0
        var bottomLeft = 0.0
        var topRight = 0.0
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drew = true
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            func brightness(x: Int, y: Int) -> Double {
                let offset = y * bytesPerRow + x * 4
                return (Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / 765.0
            }
            topLeft = brightness(x: 10, y: 5)
            bottomLeft = brightness(x: 10, y: height - 5)
            topRight = brightness(x: width - 15, y: 5)
        }
        XCTAssertTrue(drew, "could not create the bitmap context for the corner probe")
        return CornerProbe(
            width: width,
            height: height,
            topLeft: topLeft,
            bottomLeft: bottomLeft,
            topRight: topRight
        )
    }

    private func fixture(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func jpegURLs(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private func makePathologicalPDF(pageWidth: CGFloat, pageHeight: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pathological-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("could not create a PDF context for the pathological fixture")
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// If FILE_CONVERTER_ARTIFACTS is set (CI), copy the produced JPEGs
    /// there so the golden pixels can be inspected after the run.
    private func exportArtifacts(from directory: URL, label: String) {
        guard let target = ProcessInfo.processInfo.environment["FILE_CONVERTER_ARTIFACTS"] else { return }
        let destination = URL(fileURLWithPath: target, isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for url in jpegURLs(in: directory) {
            let out = destination.appendingPathComponent("\(label)-\(url.lastPathComponent)")
            try? FileManager.default.copyItem(at: url, to: out)
        }
    }

    private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func hasLibreOffice() -> Bool {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/soffice.bin",
            "/usr/local/bin/soffice",
            "/opt/homebrew/bin/soffice"
        ]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .contains(where: { FileManager.default.isExecutableFile(atPath: String($0) + "/soffice") }) ?? false
    }
}