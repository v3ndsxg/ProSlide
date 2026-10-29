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

/// Notes when a tool first prints anything: how long it took to start up,
/// which the log records so a slow start can be told apart from a slow site.
private final class FirstOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    /// Seconds since `start` the first time it is called, then nil.
    func mark(since start: Date) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard !seen else { return nil }
        seen = true
        return Date().timeIntervalSince(start)
    }
}

private struct ReadResult: Sendable {
    var all: [String] = []
    var tail: [String] = []
}

/// Reads one of a tool's output streams on its own thread, in chunks.
///
/// This used to read one byte at a time through `FileHandle.bytes`. That
/// stalled on a long line: a yt-dlp lookup prints about a megabyte of JSON on a
/// single line, and on a macOS runner even 100 KB of it went quiet for two
/// minutes, so no lookup ever finished.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let keepAll: Bool
    private var result = ReadResult()
    private var done = false

    init(keepAll: Bool) { self.keepAll = keepAll }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    var snapshot: ReadResult {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func start(_ handle: FileHandle, activity: ToolActivity, onLine: @escaping @Sendable (String) -> Void) {
        Thread.detachNewThread { [self] in
            var buffer: [UInt8] = []

            func flush() {
                guard !buffer.isEmpty else { return }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                lock.lock()
                if keepAll { result.all.append(line) }
                result.tail.append(line)
                if result.tail.count > 40 { result.tail.removeFirst() }
                lock.unlock()
                onLine(line)
            }

            // Lines end at a newline or a carriage return, since ffmpeg redraws
            // its progress with the latter.
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                activity.touch()
                for byte in chunk {
                    if byte == 10 || byte == 13 { flush() } else { buffer.append(byte) }
                }
            }
            flush()
            lock.lock(); done = true; lock.unlock()
        }
    }
}

enum ToolProcess {
    /// Runs one tool to completion, handing every line it prints to `onLine`.
    ///
    /// Cancelling the calling task stops the process and its helpers; so does
    /// going `idleTimeout` seconds without a line.
    static func run(
        executable: URL,
        arguments: [String],
        keepStdout: Bool = false,
        idleTimeout: TimeInterval,
        log: DownloadLog? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        let name = executable.lastPathComponent
        log?.note("RUN \(name) \(arguments.joined(separator: " "))")
        let started = Date()

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let activity = ToolActivity()
        let firstOutput = FirstOutput()
        let record: @Sendable (String) -> Void = { line in
            if let seconds = firstOutput.mark(since: started) {
                log?.note("\(name) first output after \(String(format: "%.1f", seconds))s")
            }
            log?.note("\(name)> \(line)")
            onLine(line)
        }
        let outReader = LineReader(keepAll: keepStdout)
        let errReader = LineReader(keepAll: false)
        outReader.start(outPipe.fileHandleForReading, activity: activity, onLine: record)
        errReader.start(errPipe.fileHandleForReading, activity: activity, onLine: record)

        let guardian = ProcessGuardian(process, escalateAfter: 2)
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

        // The readers finish when the tool closes its end. Don't wait forever:
        // a helper left holding the pipe would otherwise hang this call.
        let stopped = guardian.reason
        let deadline = Date().addingTimeInterval(stopped == nil ? 5 : 2)
        while (!outReader.isFinished || !errReader.isFinished) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !outReader.isFinished || !errReader.isFinished {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if let startError {
            log?.note("FAILED TO START \(name): \(startError)")
            throw startError
        }
        switch stopped {
        case .cancelled:
            log?.note("STOPPED \(name) after \(seconds)s (cancelled)")
            throw CancellationError()
        case .timedOut:
            log?.note("STOPPED \(name) after \(seconds)s (no output for \(Int(idleTimeout))s)")
            throw DownloadError.timedOut
        case nil:
            break
        }
        log?.note("EXIT \(name) status=\(process.terminationStatus) after \(seconds)s")
        return ToolResult(
            status: process.terminationStatus,
            stdout: outReader.snapshot.all.joined(separator: "\n"),
            tail: errReader.snapshot.tail + outReader.snapshot.tail
        )
    }
}
