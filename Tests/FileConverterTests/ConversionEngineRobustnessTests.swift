import CoreGraphics
import FileConverterCore
import XCTest

/// How the engine behaves when things go wrong: a LibreOffice that hangs or
/// fails, a run that is stopped, and a conversion that dies part-way. None of
/// these needs a real LibreOffice, which is the point — a stand-in `soffice` is a
/// shell script.
final class ConversionEngineRobustnessTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineRobustness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - LibreOffice

    func testAHungLibreOfficeIsStoppedAtTheTimeout() async throws {
        let engine = ConversionEngine(libreOfficeTimeout: 1, libreOffice: try fakeSoffice("exec sleep 60"))
        let started = Date()
        do {
            _ = try await engine.convert(input: try deck(), options: options()) { _ in }
            XCTFail("a hung LibreOffice must not be waited for")
        } catch {
            XCTAssertEqual(error as? ConversionError, .libreOfficeTimedOut(1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "it was stopped, not waited out")
    }

    func testStopEndsALibreOfficeThatIsStillRunning() async throws {
        let engine = ConversionEngine(libreOfficeTimeout: 60, libreOffice: try fakeSoffice("exec sleep 60"))
        let input = try deck()
        let conversionOptions = options()
        let task = Task { try await engine.convert(input: input, options: conversionOptions) { _ in } }

        try await Task.sleep(nanoseconds: 500_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled conversion must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Stop must not wait for LibreOffice to finish")
    }

    func testALibreOfficeFailureCarriesItsOutput() async throws {
        let engine = ConversionEngine(libreOffice: try fakeSoffice("echo 'could not open the file'; exit 3"))
        do {
            _ = try await engine.convert(input: try deck(), options: options()) { _ in }
            XCTFail("a non-zero exit is a failure")
        } catch let error as ConversionError {
            guard case .libreOfficeFailed(let detail) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(detail.contains("could not open the file"), detail)
        }
    }

    // MARK: - Partial output

    /// Stop lands between pages, and what was written so far goes with it. The
    /// bin lists any folder that holds JPEGs, so leaving them would present a
    /// partial deck as a finished one.
    func testAStoppedConversionLeavesNoPartialFolderBehind() async throws {
        let pdf = directory.appendingPathComponent("many.pdf")
        try writePDF(pages: 60, to: pdf)
        let conversionOptions = options()

        let task = Task { try await ConversionEngine().convert(input: pdf, options: conversionOptions) { _ in } }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled conversion must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: conversionOptions.destination, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(leftovers, [], "the output folder is removed when the conversion does not finish")
    }

    // MARK: - Helpers

    private func options() -> ConversionOptions {
        var options = ConversionOptions()
        let out = directory.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        options.destination = out
        return options
    }

    /// A stand-in `.pptx`; the fake `soffice` never reads it.
    private func deck() throws -> URL {
        let url = directory.appendingPathComponent("deck.pptx")
        try Data("not really a deck".utf8).write(to: url)
        return url
    }

    private func fakeSoffice(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("soffice-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writePDF(pages: Int, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 800, height: 450)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
