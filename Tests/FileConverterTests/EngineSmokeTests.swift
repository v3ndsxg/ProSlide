import AppKit
import FileConverterCore
import XCTest

final class EngineSmokeTests: XCTestCase {

    /// sample.pdf is 800x600 with a solid black square in the visual
    /// top-left corner (PDF y-up space) and a gray square bottom-right.
    /// After rendering, the black square must appear at the image's
    /// top-left; any flip/mirror in the render transform moves it and
    /// the assertions below fail.
    func testPDFConversionProducesUprightJPEGs() async throws {
        try await withTempDirectory { directory in
            var options = ConversionOptions()
            options.resolution = .hd
            options.destination = directory

            let output = try await ConversionEngine().convert(
                input: fixture(named: "sample.pdf"),
                options: options
            ) { _ in }

            let images = jpegURLs(in: output)
            XCTAssertEqual(images.count, 1, "expected a single JPEG page")
            let jpegURL = try XCTUnwrap(images.first)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: jpegURL)))
            XCTAssertEqual(rep.pixelsWide, 1280)
            XCTAssertEqual(rep.pixelsHigh, 960)
            exportArtifacts(from: output, label: "pdf-\(images.first?.lastPathComponent ?? "page")")

            let topLeft = brightness(rep.colorAt(x: 10, y: rep.pixelsHigh - 15))
            let bottomLeft = brightness(rep.colorAt(x: 10, y: 10))
            let topRight = brightness(rep.colorAt(x: rep.pixelsWide - 15, y: rep.pixelsHigh - 15))
            XCTAssertLessThan(topLeft, 0.4, "black marker should be at the visual top-left; got \(topLeft)")
            XCTAssertGreaterThan(bottomLeft, 0.8, "visual bottom-left should be white; got \(bottomLeft)")
            XCTAssertGreaterThan(topRight, 0.8, "visual top-right should be white; got \(topRight)")
        }
    }

    /// sample.pptx is a single blank slide with a black rectangle in its
    /// top-left. The full chain — LibreOffice -> PDF -> JPEG — must keep
    /// that rectangle at the JPEG's top-left.
    func testPPTXConversionProducesUprightJPEGs() async throws {
        try XCTSkipUnless(hasLibreOffice(), "LibreOffice is not installed; skipping PPTX path")

        try await withTempDirectory { directory in
            var options = ConversionOptions()
            options.resolution = .hd
            options.destination = directory

            let output = try await ConversionEngine().convert(
                input: fixture(named: "sample.pptx"),
                options: options
            ) { _ in }

            let images = jpegURLs(in: output)
            XCTAssertEqual(images.count, 1, "expected a single JPEG slide")
            let jpegURL = try XCTUnwrap(images.first)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: jpegURL)))
            XCTAssertEqual(rep.pixelsWide, 1280)
            exportArtifacts(from: output, label: "pptx-\(images.first?.lastPathComponent ?? "slide")")

            let topLeft = brightness(rep.colorAt(x: 10, y: rep.pixelsHigh - 15))
            let bottomLeft = brightness(rep.colorAt(x: 10, y: 10))
            XCTAssertLessThan(topLeft, 0.4, "black slide shape should be at the visual top-left; got \(topLeft)")
            XCTAssertGreaterThan(bottomLeft, 0.8, "visual bottom-left should be white; got \(bottomLeft)")
        }
    }

    @MainActor
    func testBadExtensionThrowsUnsupportedFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/sample.exe")
        do {
            _ = try await ConversionEngine().convert(input: url, options: ConversionOptions()) { _ in }
            XCTFail("expected unsupportedFile to be thrown")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .unsupportedFile)
        }
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

    private func brightness(_ color: NSColor?) -> CGFloat {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return -1 }
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
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