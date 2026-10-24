import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct ConversionEngine {
    /// PowerPoint formats, converted to PDF by LibreOffice first. `.ppt` is the
    /// pre-2007 binary format; LibreOffice reads both.
    public static let powerPointExtensions: Set<String> = ["pptx", "ppt"]

    /// Every extension ProSlide converts.
    public static let supportedExtensions: Set<String> = powerPointExtensions.union(["pdf"])

    /// How long LibreOffice gets to turn one PowerPoint file into a PDF before it
    /// is stopped. A hung `soffice` would otherwise hold the whole batch forever.
    public var libreOfficeTimeout: TimeInterval

    /// A specific `soffice` to run, instead of searching the usual places.
    /// Exists so tests can stand in a fake one.
    private let libreOfficeOverride: URL?

    public init(libreOfficeTimeout: TimeInterval = 300, libreOffice: URL? = nil) {
        self.libreOfficeTimeout = libreOfficeTimeout
        self.libreOfficeOverride = libreOffice
    }

    /// - Parameter progress: called as rendering proceeds, 0 to 1. It is only
    ///   ever called from this function and never stored, so it is deliberately
    ///   non-escaping: that lets `ConversionQueue` hand its own injected
    ///   callback straight through without it becoming an escaping capture.
    public func convert(
        input: URL,
        options: ConversionOptions,
        profileDirectory: URL? = nil,
        progress: @Sendable (Double) async -> Void
    ) async throws -> URL {
        let extensionName = input.pathExtension.lowercased()
        guard ConversionEngine.supportedExtensions.contains(extensionName) else {
            throw ConversionError.unsupportedFile
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileConverter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pdfURL: URL
        if ConversionEngine.powerPointExtensions.contains(extensionName) {
            await progress(0.05)
            pdfURL = try await makePDF(
                from: input,
                options: options,
                temporaryDirectory: temporaryDirectory,
                profileDirectory: profileDirectory
            )
        } else {
            pdfURL = input
        }

        await progress(0.15)
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw ConversionError.unreadablePDF
        }
        let maxPageCount = 300
        guard document.pageCount <= maxPageCount else {
            throw ConversionError.tooManyPages(document.pageCount)
        }

        let outputDirectory = try makeOutputDirectory(for: input, in: options.destination)
        do {
            for index in 0..<document.pageCount {
                // Stop between pages, not only between files, so a long PDF does
                // not have to finish before Stop takes effect.
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let destination = outputDirectory.appendingPathComponent(
                    String(format: "%@-%03d.jpg", safeFilenameStem(input.deletingPathExtension().lastPathComponent), index + 1)
                )
                try render(page: page, to: destination, options: options)
                await progress(0.15 + (0.85 * Double(index + 1) / Double(document.pageCount)))
            }
        } catch {
            // Half a deck must not stay behind. The bin lists any folder holding
            // JPEGs, so a failure on page 17 of 40 would otherwise show up as a
            // finished 16-slide deck and get a presentation built for it.
            try? FileManager.default.removeItem(at: outputDirectory)
            throw error
        }
        return outputDirectory
    }

    /// - Parameter profileDirectory: an existing LibreOffice user profile to
    ///   reuse. Callers converting several PowerPoint files in a row can pass
    ///   one profile for the whole batch instead of paying profile creation on
    ///   every file. Passing nil creates a throwaway profile for this call, so
    ///   single conversions stay fully isolated.
    private func makePDF(
        from source: URL,
        options: ConversionOptions,
        temporaryDirectory: URL,
        profileDirectory: URL?
    ) async throws -> URL {
        let executable = try libreOfficeOverride ?? libreOfficeExecutable()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        let fontEmbedding = options.fontEmbed ? "true" : "false"
        let convertTo = "pdf:writer_pdf_Export:{\"EmbedFonts\":{\"type\":\"boolean\",\"value\":\"\(fontEmbedding)\"}}"
        let profile: URL
        if let profileDirectory {
            profile = profileDirectory
        } else {
            let created = temporaryDirectory.appendingPathComponent("LibreOffice-Profile", isDirectory: true)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            profile = created
        }
        process.arguments = [
            "--headless",
            "-env:UserInstallation=\(profile.absoluteString)",
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

        // Stop and the timeout both end the child rather than waiting it out.
        let guardian = ProcessGuardian(process)
        let timeout = libreOfficeTimeout
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            guardian.stop(reason: .timedOut)
        }

        var startError: Error?
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                    guardian.didStart()
                } catch {
                    startError = error
                    continuation.resume()
                }
            }
        } onCancel: {
            guardian.stop(reason: .cancelled)
        }
        watchdog.cancel()
        // The child has inherited its own copy of the write end; closing ours
        // guarantees the reader sees EOF once the process exits (or never spawned).
        try? errorPipe.fileHandleForWriting.close()

        let stopped = guardian.reason
        if stopped != nil {
            // A killed child can leave a grandchild holding the pipe open, in
            // which case the reader would never see EOF. Close our end too.
            try? errorPipe.fileHandleForReading.close()
        }
        let message = (try? await messageTask.value) ?? ""
        if let startError { throw startError }
        switch stopped {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ConversionError.libreOfficeTimedOut(Int(libreOfficeTimeout))
        case nil: break
        }
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
        guard let found = ConversionEngine.installedLibreOffice() else {
            throw ConversionError.libreOfficeUnavailable
        }
        return found
    }

    /// The `soffice` ProSlide would run, or nil when LibreOffice is not installed:
    /// the usual install locations first, then wherever macOS says LibreOffice
    /// is, then `PATH`.
    ///
    /// `~/Applications` is listed because an app can be installed there, and it
    /// is invisible to a search of `/Applications` alone — which is how an
    /// installed LibreOffice was reported as missing.
    public static func installedLibreOffice() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let knownLocations = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/soffice.bin",
            "\(home)/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/usr/local/bin/soffice",
            "/opt/homebrew/bin/soffice"
        ]
        if let path = knownLocations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Anywhere else Launch Services knows about: another volume, a renamed
        // app, a managed install.
        if let apps = LSCopyApplicationURLsForBundleIdentifier("org.libreoffice.script" as CFString, nil)?
            .takeRetainedValue() as? [URL] {
            for app in apps {
                let candidate = app.appendingPathComponent("Contents/MacOS/soffice")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/soffice"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
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
        var invalid = CharacterSet(charactersIn: "/:\\?%*|\"")
        invalid.formUnion(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "document" : trimmed
    }

    /// The size the page is shown at, in points: its crop box, turned on its side
    /// when the page is rotated a quarter turn.
    ///
    /// Media box is the whole sheet; the crop box is what a viewer displays, and
    /// is smaller wherever a file carries bleed or printer's marks. Rotation is
    /// applied by `PDFPage.draw`, but `bounds(for:)` reports the unrotated box, so
    /// the canvas has to be sized for the rotated page or the render comes out
    /// the wrong shape and clipped.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        let quarterTurn = abs(page.rotation) % 180 == 90
        return quarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    private func render(page: PDFPage, to destination: URL, options: ConversionOptions) throws {
        let bounds = ConversionEngine.displayedSize(of: page)
        let maxPixelDimension = 8192
        guard bounds.width > 0, bounds.height > 0 else { throw ConversionError.imageEncodingFailed }
        let scale = min(
            CGFloat(options.resolution.pixelWidth) / bounds.width,
            CGFloat(maxPixelDimension) / max(bounds.width, bounds.height)
        )
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
        page.draw(with: .cropBox, to: context)

        guard let cgImage = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                  destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { throw ConversionError.imageEncodingFailed }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: NSNumber(value: options.quality)] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.imageEncodingFailed }
    }
}

/// Ends a child process on request, safely from any thread.
///
/// `Process.terminate()` raises an Objective-C exception if the process has not
/// been launched, and Stop or the watchdog can fire before, during or after the
/// launch. This remembers a stop that arrives early and applies it as soon as
/// the process exists, and never touches one that has already finished.
final class ProcessGuardian: @unchecked Sendable {
    enum Reason { case cancelled, timedOut }

    private let process: Process
    private let lock = NSLock()
    private var started = false
    private var requested: Reason?

    init(_ process: Process) { self.process = process }

    /// Why the process was stopped, or nil if it ran to completion.
    var reason: Reason? {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func didStart() {
        lock.lock()
        started = true
        let pending = requested
        lock.unlock()
        if pending != nil { terminate() }
    }

    func stop(reason: Reason) {
        lock.lock()
        if requested == nil { requested = reason }
        let running = started
        lock.unlock()
        if running { terminate() }
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }
}
