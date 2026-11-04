import Foundation

/// The programs a download runs: `yt-dlp` to fetch, `ffmpeg` to merge and
/// convert, and Deno, which `yt-dlp` needs to solve YouTube's challenges.
/// They are packaged inside the app; nothing is looked up on `PATH`.
public struct DownloadTools: Equatable, Sendable {
    public let ytDlp: URL
    public let ffmpeg: URL
    public let deno: URL

    /// Names of the executables inside the tools folder.
    static let names = (ytDlp: "yt-dlp", ffmpeg: "ffmpeg", deno: "deno")

    /// Environment variable that points at a folder of tools, for development
    /// builds that have none packaged.
    public static let overrideVariable = "PROSLIDE_TOOLS_DIR"

    /// Finds the tools in `Contents/Resources/Tools` of the running app, or in
    /// the folder named by `PROSLIDE_TOOLS_DIR`. Nil if any is missing.
    public static func locate(
        resources: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DownloadTools? {
        let folder: URL
        if let path = environment[overrideVariable], !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else if let resources {
            folder = resources.appendingPathComponent("Tools", isDirectory: true)
        } else {
            return nil
        }
        let tools = DownloadTools(
            ytDlp: folder.appendingPathComponent(names.ytDlp),
            ffmpeg: folder.appendingPathComponent(names.ffmpeg),
            deno: folder.appendingPathComponent(names.deno)
        )
        let all = [tools.ytDlp, tools.ffmpeg, tools.deno]
        return all.allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) } ? tools : nil
    }
}

/// Whether this Mac can download, and if not, why.
public enum DownloadAvailability: Equatable, Sendable {
    case available(DownloadTools)
    case unsupportedHardware
    case toolsMissing

    /// Checked at run time, from the hardware rather than from how the app was
    /// built. The packaged tools are for Apple Silicon only.
    public static func current(
        isAppleSilicon: Bool = hardwareIsAppleSilicon,
        tools: DownloadTools? = DownloadTools.locate()
    ) -> DownloadAvailability {
        guard isAppleSilicon else { return .unsupportedHardware }
        guard let tools else { return .toolsMissing }
        return .available(tools)
    }

    public var error: DownloadError? {
        switch self {
        case .available: nil
        case .unsupportedHardware: .unsupportedHardware
        case .toolsMissing: .toolsMissing
        }
    }

    public static var hardwareIsAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
