@testable import FileConverterCore
import XCTest

/// Temporary timing investigation. Not for merging.
final class TempSpeedTests: XCTestCase {

    private func script(_ body: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tool")
        try ("#!/bin/bash\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// A yt-dlp lookup prints about 1 MB of JSON on one line.
    func testLargeSingleLineOutput() async throws {
        for size in [100_000, 900_000, 3_000_000] {
            let tool = try script("head -c \(size) /dev/zero | tr '\\0' 'a'; echo")
            let start = Date()
            let result = try await ToolProcess.run(executable: tool, arguments: [], keepStdout: true, idleTimeout: 120, onLine: { _ in })
            let seconds = Date().timeIntervalSince(start)
            print("SPEED toolprocess-bytes size=\(size) read=\(result.stdout.utf8.count) seconds=\(String(format: "%.2f", seconds))")
        }
    }

    /// The same output read in chunks, for comparison.
    func testSameOutputReadInChunks() throws {
        for size in [100_000, 900_000, 3_000_000] {
            let tool = try script("head -c \(size) /dev/zero | tr '\\0' 'a'; echo")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = tool
            process.standardOutput = pipe
            let start = Date()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            print("SPEED chunked size=\(size) read=\(data.count) seconds=\(String(format: "%.3f", Date().timeIntervalSince(start)))")
        }
    }

    /// Start-up cost of the packaged yt-dlp on macOS, with no network involved.
    func testYtDlpStartup() async throws {
        guard let tools = DownloadTools.locate(resources: nil) else { throw XCTSkip("no tools") }
        for run in 1...4 {
            let start = Date()
            let result = try await ToolProcess.run(executable: tools.ytDlp, arguments: ["--version"], idleTimeout: 120, onLine: { _ in })
            print("SPEED ytdlp-version run=\(run) status=\(result.status) seconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
        }
        for run in 1...2 {
            let start = Date()
            _ = try await ToolProcess.run(executable: tools.deno, arguments: ["eval", "console.log(1)"], idleTimeout: 120, onLine: { _ in })
            print("SPEED deno-eval run=\(run) seconds=\(String(format: "%.2f", Date().timeIntervalSince(start)))")
        }
    }
}
