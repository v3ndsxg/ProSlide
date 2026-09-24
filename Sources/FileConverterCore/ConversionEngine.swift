import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct ConversionEngine {
    public init() {}

    public func convert(
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
            pdfURL = try await makePDF(from: input, options: options, temporaryDirectory: temporaryDirectory)
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

    private func makePDF(from source: URL, options: ConversionOptions, temporaryDirectory: URL) async throws -> URL {
        let executable = try libreOfficeExecutable()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        let fontEmbedding = options.fontEmbed ? "true" : "false"
        let convertTo = "pdf:writer_pdf_Export:{\"EmbedFonts\":{\"type\":\"boolean\",\"value\":\"\(fontEmbedding)\"}}"
        let profileDirectory = temporaryDirectory.appendingPathComponent("LibreOffice-Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        process.arguments = [
            "--headless",
            "-env:UserInstallation=\(profileDirectory.absoluteString)",
            "--convert-to", convertTo,
            "--outdir", temporaryDirectory.path,
            source.path
        ]
        process.standardError = errorPipe
        process.standardOutput = errorPipe

        // Drain stdout/stderr concurrently so a chatty soffice run can never
        // fill the pipe buffer and deadlock the child while it is still running.
        let messageTask = Task {
            var bytes: [UInt8] = []
            for try await byte in errorPipe.fileHandleForReading.bytes {
                bytes.append(byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        var startError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                startError = error
                continuation.resume()
            }
        }
        // The child has inherited its own copy of the write end; closing ours
        // guarantees the reader sees EOF once the process exits (or never spawned).
        try? errorPipe.fileHandleForWriting.close()

        let message = try await messageTask.value
        if let startError { throw startError }
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
        let scale = CGFloat(options.resolution.pixelWidth) / bounds.width
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.imageEncodingFailed }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                  destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { throw ConversionError.imageEncodingFailed }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: NSNumber(value: options.quality)] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.imageEncodingFailed }
    }
}
