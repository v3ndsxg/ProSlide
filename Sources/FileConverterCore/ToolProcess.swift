import Foundation

/// What a finished tool left behind.
struct ToolResult: Sendable {
    let status: Int32
    /// Everything the tool printed on stdout, when asked to keep it.
    let stdout: String
    /// The last lines it printed on either stream, for an error message.
    let tail: [String]
}

/// Remembers when a tool last printed anything, so a download that has gone
/// quiet can be stopped without putting a ceiling on how long a big one runs.
private final class ToolActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock(); last = Date(); lock.unlock()
    }

    var idleFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

private struct ReadResult: Sendable {
    var all: [String] = []
    var tail: [String] = []
}

enum ToolProcess {
    /// Runs one tool to completion, handing every line it prints to `onLine`.
    ///
    /// Lines end at a newline or a carriage return, since ffmpeg redraws its
    /// progress with the latter. Cancelling the calling task stops the process;
    /// so does going `idleTimeout` seconds without a line.
    static func run(
        executable: URL,
        arguments: [String],
        keepStdout: Bool = false,
        idleTimeout: TimeInterval,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let activity = ToolActivity()
        // Both streams are drained as the tool runs so a chatty one can never
        // fill a pipe buffer and stall.
        let outTask = Task { await readLines(outPipe.fileHandleForReading, activity: activity, keepAll: keepStdout, onLine: onLine) }
        let errTask = Task { await readLines(errPipe.fileHandleForReading, activity: activity, keepAll: false, onLine: onLine) }

        let guardian = ProcessGuardian(process)
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if activity.idleFor > idleTimeout {
                    guardian.stop(reason: .timedOut)
                    return
                }
            }
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
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let stopped = guardian.reason
        if stopped != nil {
            // A killed child can leave a grandchild holding a pipe open, and
            // the readers would then never see the end.
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        let out = await outTask.value
        let err = await errTask.value

        if let startError { throw startError }
        switch stopped {
        case .cancelled: throw CancellationError()
        case .timedOut: throw DownloadError.timedOut
        case nil: break
        }
        return ToolResult(
            status: process.terminationStatus,
            stdout: out.all.joined(separator: "\n"),
            tail: err.tail + out.tail
        )
    }

    private static func readLines(
        _ handle: FileHandle,
        activity: ToolActivity,
        keepAll: Bool,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> ReadResult {
        var result = ReadResult()
        var buffer: [UInt8] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            activity.touch()
            onLine(line)
            if keepAll { result.all.append(line) }
            result.tail.append(line)
            if result.tail.count > 30 { result.tail.removeFirst() }
        }

        do {
            for try await byte in handle.bytes {
                if byte == 10 || byte == 13 {
                    flush()
                } else {
                    buffer.append(byte)
                    // A very long line, such as the metadata JSON, is still activity.
                    if buffer.count % 8192 == 0 { activity.touch() }
                }
            }
        } catch {}
        flush()
        return result
    }
}
