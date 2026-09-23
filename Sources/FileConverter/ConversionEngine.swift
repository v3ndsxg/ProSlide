import AppKit
import Foundation
import PDFKit

struct ConversionEngine {
    func convert(
        input: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let extensionName = input.pathExtension.lowercased()
        guard extensionName == "pdf" || extensionName == "pptx" else {
            throw ConversionError.unsupportedFile
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileConverter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pdfURL: URL
        if extensionName == "pptx" {
            await progress(0.05)
            pdfURL = try await makePDF(from: input, temporaryDirectory: temporaryDirectory)
        } else {
            pdfURL = input
        }

        await progress(0.15)
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw ConversionError.unreadablePDF
        }

        let outputDirectory = try makeOutputDirectory(for: input, in: options.destination)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let destination = outputDirectory.appendingPathComponent(
                String(format: "%@-%03d.jpg", safeFilenameStem(input.deletingPathExtension().lastPathComponent), index + 1)
            )
            try render(page: page, to: destination, options: options)
            await progress(0.15 + (0.85 * Double(index + 1) / Double(document.pageCount)))
        }
        return outputDirectory
    }

    private func makePDF(from source: URL, temporaryDirectory: URL) async throws -> URL {
        let executable = try libreOfficeExecutable()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--headless", "--convert-to", "pdf", "--outdir", temporaryDirectory.path, source.path]
        process.standardError = errorPipe
        process.standardOutput = errorPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw ConversionError.libreOfficeFailed(message) }

        let expected = temporaryDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        guard let produced = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
            throw ConversionError.noPDFProduced
        }
        return produced
    }

    private func libreOfficeExecutable() throws -> URL {
        let knownLocations = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/soffice.bin",
            "/usr/local/bin/soffice",
            "/opt/homebrew/bin/soffice"
        ]
        if let path = knownLocations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/soffice"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        throw ConversionError.libreOfficeUnavailable
    }

    private func makeOutputDirectory(for input: URL, in destination: URL) throws -> URL {
        let base = safeFilenameStem(input.deletingPathExtension().lastPathComponent) + " JPEGs"
        var candidate = destination.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private func safeFilenameStem(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    private func render(page: PDFPage, to destination: URL, options: ConversionOptions) throws {
        let bounds = page.bounds(for: .mediaBox)
        let scale = options.resolution.pixelWidth.map { CGFloat($0) / bounds.width } ?? 2
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw ConversionError.imageEncodingFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        context.cgContext.saveGState()
        context.cgContext.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: bounds)
        context.cgContext.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: options.quality]) else {
            throw ConversionError.imageEncodingFailed
        }
        try data.write(to: destination, options: .atomic)
    }
}
