import Foundation

// MARK: - What the build stamped

/// Where the running app was built from, as `Scripts/make-app-bundle.sh` stamped
/// it into Info.plist: the folder to rebuild, the commit installed, and the
/// release version it was built from.
///
/// Every field is optional. A build from a folder that isn't a git checkout, or
/// an app from before the Update button, has none of them.
public struct BuildStamp: Equatable, Sendable {
    public var sourceFolder: URL?
    public var commit: String?
    public var commitDate: Date?
    /// The newest release behind the build, such as "1.2.0". Nil before the first release.
    public var version: String?

    public static let current = BuildStamp(bundle: .main)

    public init(sourceFolder: URL? = nil, commit: String? = nil, commitDate: Date? = nil, version: String? = nil) {
        self.sourceFolder = sourceFolder
        self.commit = commit
        self.commitDate = commitDate
        self.version = version
    }

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        func text(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        sourceFolder = text("ProSlideSourceFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        commit = text("ProSlideSourceCommit")
        commitDate = text("ProSlideSourceDate").flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        version = text("CFBundleShortVersionString").flatMap { $0 == "0.0.0" ? nil : $0 }
    }
}

// MARK: - Fixed facts

/// The constants the updater trusts. The addresses are built in rather than
/// read from the folder, so changing a setting in the folder can't redirect
/// updates somewhere else.
public enum UpdateSource {
    public static let repositoryURL = "https://github.com/v3ndsxg/ProSlide.git"
    /// GitHub's newest published release: never a draft or a pre-release.
    public static let latestReleaseURL = "https://api.github.com/repos/v3ndsxg/ProSlide/releases/latest"
    public static let mainBranch = "main"
    /// The automatic check runs at launch and then this often while the app stays open.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    static let chosenFolderKey = "updateSourceFolder"
    /// The stamped folder the choice replaced. A choice only counts while the app
    /// still carries that stamp, so a later build from another folder wins.
    static let chosenFolderReplacesKey = "updateSourceFolderReplaces"

    /// `~/Documents/<app folder>/Logs/update.log`, beside the download log.
    public static var defaultLogURL: URL {
        DownloadLog.defaultURL.deletingLastPathComponent().appendingPathComponent("update.log")
    }

    /// Where a built update waits until the app quits.
    public static var defaultStagingFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.v3ndsxg.proslide", isDirectory: true)
            .appendingPathComponent("Update", isDirectory: true)
    }

    /// Whether two git addresses name the same repository: case, a trailing slash
    /// and a trailing `.git` don't matter. Any other scheme (`git@github.com:…`)
    /// doesn't match the HTTPS address.
    public static func sameRepository(_ first: String, _ second: String) -> Bool {
        normalized(first) == normalized(second)
    }

    private static func normalized(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text
    }

    /// Release tags look like `v1.2.0`. Anything else is refused, so a tag name
    /// can never be read as a git option or an odd ref.
    public static func isReleaseTag(_ tag: String) -> Bool {
        tag.range(of: #"^v[0-9]+(\.[0-9]+){0,3}\z"#, options: .regularExpression) != nil
    }

    /// Reads curl's output: GitHub's JSON, then the HTTP status on the last line.
    static func parseLatestRelease(_ output: String) throws -> UpdateRelease {
        var lines = output.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let status = Int(lines.popLast()?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        switch status {
        case 200: break
        case 404: throw UpdateProblem.noRelease
        case 403, 429: throw UpdateProblem.failed("GitHub is limiting requests right now. Try again in an hour.")
        default: throw UpdateProblem.offline
        }
        struct Payload: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let published_at: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(lines.joined(separator: "\n").utf8)) else {
            throw UpdateProblem.failed("GitHub\u{2019}s answer about the latest release couldn\u{2019}t be read.")
        }
        guard isReleaseTag(payload.tag_name) else {
            throw UpdateProblem.failed("The latest release\u{2019}s tag, \u{201C}\(payload.tag_name)\u{201D}, doesn\u{2019}t look like a version (v1.2.0), so ProSlide won\u{2019}t install it.")
        }
        let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UpdateRelease(
            tag: payload.tag_name,
            name: name.isEmpty ? nil : name,
            notes: readableNotes(payload.body ?? ""),
            date: payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    /// Release notes as plain lines: Markdown headings lose their `#`s and list
    /// items get a bullet, since the window shows text, not rendered Markdown.
    static func readableNotes(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                var text = line
                if let heading = text.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                    text.removeSubrange(heading)
                } else if let item = text.range(of: #"^\s*[*-]\s+"#, options: .regularExpression) {
                    text.replaceSubrange(item, with: "\u{2022} ")
                }
                return text
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - State

/// A published release on GitHub.
public struct UpdateRelease: Equatable, Sendable {
    /// Such as "v1.2.0".
    public let tag: String
    /// The release's title, when it has one besides the tag.
    public let name: String?
    public let notes: String
    public let date: Date?

    /// "1.2.0"
    public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
}

public enum UpdateStep: Equatable, Sendable {
    case downloading
    case building
    case preparing

    public var description: String {
        switch self {
        case .downloading: "Downloading the update\u{2026}"
        case .building: "Building the new version\u{2026} This takes a few minutes."
        case .preparing: "Getting the new version ready\u{2026}"
        }
    }
}

public enum UpdateProblem: Error, Equatable, Sendable {
    /// GitHub couldn't be reached.
    case offline
    /// Nothing has been released yet.
    case noRelease
    /// The folder the app was built from is gone. Nil when the app never knew it.
    case folderMissing(URL?)
    /// The folder exists but isn't a ProSlide download.
    case notProSlideFolder(URL)
    /// The folder downloads from somewhere other than the built-in address.
    case wrongRemote(String)
    /// The folder has edits that aren't on GitHub.
    case localChanges(URL)
    /// A step failed; the message says which. The installed app is untouched.
    case failed(String)
}

public enum UpdateState: Equatable, Sendable {
    /// Not checked yet, or the last automatic check failed quietly.
    case unknown
    case checking
    case upToDate
    case available(UpdateRelease)
    case updating(UpdateStep)
    /// Built and waiting: installs on restart, or when the app next quits.
    case ready
    case problem(UpdateProblem)
}

// MARK: - Running commands

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    /// The last lines printed on either stream, for the log and error messages.
    public let tail: [String]

    public init(status: Int32, output: String = "", tail: [String] = []) {
        self.status = status
        self.output = output
        self.tail = tail
    }
}

/// Runs curl, git, the build script and ditto. Tests replace it with a script.
public protocol UpdateCommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String], idleTimeout: TimeInterval) async throws -> CommandResult
}

/// The real runner: every command and everything it prints goes to the update log.
struct LoggedCommandRunner: UpdateCommandRunner {
    let log: DownloadLog

    func run(_ executable: URL, _ arguments: [String], idleTimeout: TimeInterval) async throws -> CommandResult {
        let result = try await ToolProcess.run(
            executable: executable,
            arguments: arguments,
            keepStdout: true,
            idleTimeout: idleTimeout,
            log: log,
            onLine: { _ in }
        )
        return CommandResult(status: result.status, output: result.stdout, tail: result.tail)
    }
}

// MARK: - The updater

/// Keeps ProSlide on the newest GitHub release: checks for one, checks the
/// folder it was built from out at the release's tag, rebuilds with the
/// packaging script, and swaps the new app in once this one has quit.
///
/// Only published releases count, never drafts, pre-releases or work merged
/// into main. Nothing is installed without the operator pressing Update. A
/// failed step leaves the installed app as it was; only a finished build is
/// ever swapped in.
@MainActor
public final class AppUpdater: ObservableObject {
    @Published public private(set) var state: UpdateState = .unknown
    /// Whether the update window is open.
    @Published public var isShowingWindow = false
    /// The operator chose to restart once the running conversion or download ends.
    @Published public var restartWhenIdle = false

    public let log: DownloadLog
    let stamp: BuildStamp
    let repositoryURL: String
    let latestReleaseURL: String
    let runner: UpdateCommandRunner
    let defaults: UserDefaults
    let stagingFolder: URL
    let installedApp: URL
    /// The build script's output is `build/<appName>.app`.
    let appName: String
    /// Rebuilds the same app that is running.
    let variantFlag: String

    let curlTool = URL(fileURLWithPath: "/usr/bin/curl")
    let gitTool = URL(fileURLWithPath: "/usr/bin/git")
    let bashTool = URL(fileURLWithPath: "/bin/bash")
    let dittoTool = URL(fileURLWithPath: "/usr/bin/ditto")

    private var timer: Timer?
    private var installerLaunched = false
    private let fileManager = FileManager.default

    public init(
        stamp: BuildStamp = .current,
        identity: AppIdentity = .current,
        repositoryURL: String = UpdateSource.repositoryURL,
        latestReleaseURL: String = UpdateSource.latestReleaseURL,
        runner: UpdateCommandRunner? = nil,
        log: DownloadLog = DownloadLog(fileURL: UpdateSource.defaultLogURL),
        defaults: UserDefaults = .standard,
        stagingFolder: URL = UpdateSource.defaultStagingFolder,
        installedApp: URL = Bundle.main.bundleURL
    ) {
        self.stamp = stamp
        self.repositoryURL = repositoryURL
        self.latestReleaseURL = latestReleaseURL
        self.runner = runner ?? LoggedCommandRunner(log: log)
        self.log = log
        self.defaults = defaults
        self.stagingFolder = stagingFolder
        self.installedApp = installedApp
        appName = identity.displayName
        variantFlag = identity.isBeta ? "--beta" : "--stable"
        restoreStagedUpdate()
    }

    /// The installed release, such as "1.2.0". Nil before the first release.
    public var installedVersion: String? { stamp.version }
    /// When the installed version's last change was made.
    public var installedDate: Date? { stamp.commitDate }

    var stagedApp: URL { stagingFolder.appendingPathComponent("\(appName).app", isDirectory: true) }
    /// Written by the installer when it couldn't swap the app in.
    var failureMarker: URL { stagingFolder.appendingPathComponent("install-failed.txt") }

    /// The folder updates are built in: the one the operator chose after the
    /// stamped one went missing, or the stamped one.
    public var sourceFolder: URL? {
        if let chosen = defaults.string(forKey: UpdateSource.chosenFolderKey),
           defaults.string(forKey: UpdateSource.chosenFolderReplacesKey) == (stamp.sourceFolder?.path ?? "") {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        return stamp.sourceFolder
    }

    // MARK: Checking

    /// Checks now, then once a day while the app is open. Quiet: nothing shows
    /// unless a release is found, and nothing is installed.
    public func startAutomaticChecks() {
        guard timer == nil else { return }
        Task { await check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: UpdateSource.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    /// What the Update button and the menu item do: check, or show what's going on.
    public func showOrCheck() {
        switch state {
        case .unknown, .upToDate, .problem:
            Task { await check(userInitiated: true) }
        case .checking, .available, .updating, .ready:
            isShowingWindow = true
        }
    }

    /// Asks GitHub for its newest release. A check the operator started opens
    /// the window and reports problems; an automatic one fails silently.
    public func check(userInitiated: Bool) async {
        switch state {
        case .checking, .updating, .ready:
            if userInitiated { isShowingWindow = true }
            return
        case .unknown, .upToDate, .available, .problem:
            break
        }
        let previous = state
        state = .checking
        if userInitiated { isShowingWindow = true }
        log.note("CHECK (\(userInitiated ? "asked" : "automatic"))")
        do {
            state = try await findUpdate()
        } catch {
            let problem = Self.problem(from: error)
            log.note("CHECK FAILED: \(problem)")
            if userInitiated {
                state = .problem(problem)
            } else if case .problem = previous {
                state = .unknown
            } else {
                state = previous
            }
        }
    }

    private func findUpdate() async throws -> UpdateState {
        let folder = try await preparedFolder()
        let release = try await latestRelease()
        let releaseCommit = try await fetchRelease(release, into: folder, failure: .offline)
        let installed = try await installedCommit(folder)
        // Up to date when the installed build already contains the release,
        // which also covers a build made from newer work by hand.
        let contained = try await git(folder, ["merge-base", "--is-ancestor", releaseCommit, installed])
        switch contained.status {
        case 0: return .upToDate
        case 1: return .available(release)
        default: throw UpdateProblem.failed("Couldn\u{2019}t compare the installed version with the release.")
        }
    }

    // MARK: Updating

    /// Checks the folder out at the release and rebuilds in the background; the
    /// app keeps working meanwhile.
    public func update() {
        guard case .available(let release) = state else { return }
        state = .updating(.downloading)
        Task {
            do {
                let folder = try await preparedFolder()
                try await refuseLocalChanges(folder)
                _ = try await fetchRelease(release, into: folder, failure: .failed(
                    "Couldn\u{2019}t download the update. Check your internet connection and try again."
                ))
                try await checkOut(release, in: folder)
                try await buildAndStage(folder)
            } catch {
                fail(error)
            }
        }
    }

    /// Downloads ProSlide again into the folder it was built from, then builds
    /// the newest release.
    public func downloadAgain() {
        guard case .problem(.folderMissing(let folder?)) = state else { return }
        cloneAndBuild(into: folder)
    }

    /// The operator picked a new place for the ProSlide folder. A ProSlide
    /// folder already there is used as it is; otherwise ProSlide is downloaded
    /// into a new `ProSlide` folder inside it.
    public func useLocation(_ chosen: URL) {
        let target: URL
        if inspect(chosen) == .proSlide {
            target = chosen
        } else {
            target = chosen.appendingPathComponent("ProSlide", isDirectory: true)
        }
        switch inspect(target) {
        case .proSlide:
            remember(target)
            state = .unknown
            Task { await check(userInitiated: true) }
        case .missing, .empty:
            cloneAndBuild(into: target)
        case .other:
            state = .problem(.notProSlideFolder(target))
            isShowingWindow = true
        }
    }

    private func cloneAndBuild(into target: URL) {
        state = .updating(.downloading)
        isShowingWindow = true
        Task {
            do {
                let release = try await latestRelease()
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let clone = try await runner.run(
                    gitTool,
                    ["clone", "--quiet", "--branch", UpdateSource.mainBranch, repositoryURL, target.path],
                    idleTimeout: 180
                )
                guard clone.status == 0 else {
                    throw UpdateProblem.failed("Couldn\u{2019}t download ProSlide from GitHub. Check your internet connection and try again.")
                }
                remember(target)
                _ = try await fetchRelease(release, into: target, failure: .failed(
                    "Couldn\u{2019}t download ProSlide \(release.version) from GitHub. Check your internet connection and try again."
                ))
                try await checkOut(release, in: target)
                try await buildAndStage(target)
            } catch {
                fail(error)
            }
        }
    }

    private func buildAndStage(_ folder: URL) async throws {
        state = .updating(.building)
        let script = folder.appendingPathComponent("Scripts/make-app-bundle.sh")
        // A release build can be quiet for minutes while it optimises.
        let build = try await runner.run(bashTool, [script.path, variantFlag], idleTimeout: 20 * 60)
        let built = folder.appendingPathComponent("build/\(appName).app", isDirectory: true)
        guard build.status == 0, fileManager.fileExists(atPath: built.path) else {
            throw UpdateProblem.failed("The new version didn\u{2019}t build. The ProSlide you\u{2019}re using hasn\u{2019}t changed.")
        }

        state = .updating(.preparing)
        try? fileManager.removeItem(at: stagingFolder)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        let copy = try await runner.run(dittoTool, [built.path, stagedApp.path], idleTimeout: 120)
        guard copy.status == 0 else {
            throw UpdateProblem.failed("Couldn\u{2019}t get the new version ready to install.")
        }
        log.note("UPDATE READY: \(stagedApp.path)")
        state = .ready
        isShowingWindow = true
    }

    // MARK: Installing

    /// Starts the installer, which waits for this app to quit, swaps the new app
    /// in, and opens it again when `relaunch` is set. The caller then quits.
    /// Returns false when there is nothing to install or it already started.
    @discardableResult
    public func launchInstaller(relaunch: Bool) -> Bool {
        guard case .ready = state, !installerLaunched, fileManager.fileExists(atPath: stagedApp.path) else { return false }
        log.ensureExists()
        let process = Process()
        process.executableURL = bashTool
        process.arguments = UpdateInstaller.arguments(
            processID: ProcessInfo.processInfo.processIdentifier,
            stagedApp: stagedApp,
            installedApp: installedApp,
            relaunch: relaunch,
            log: log.fileURL,
            failureMarker: failureMarker
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            installerLaunched = true
            log.note("INSTALLER STARTED (relaunch: \(relaunch)) for \(installedApp.path)")
            return true
        } catch {
            fail(UpdateProblem.failed("Couldn\u{2019}t start the installer: \(error.localizedDescription)"))
            return false
        }
    }

    /// Closes the window. A problem is forgotten, so the button goes back to normal.
    public func dismiss() {
        isShowingWindow = false
        if case .problem = state { state = .unknown }
    }

    // MARK: Helpers

    /// On launch: an update built earlier and not yet installed (the app
    /// crashed, or was force-quit) is offered again, and an install that failed
    /// is reported.
    private func restoreStagedUpdate() {
        if let message = try? String(contentsOf: failureMarker, encoding: .utf8) {
            try? fileManager.removeItem(at: stagingFolder)
            state = .problem(.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
            isShowingWindow = true
            return
        }
        let plist = stagedApp.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let staged = BuildStamp(info: info).commit,
           staged != stamp.commit {
            state = .ready
            return
        }
        try? fileManager.removeItem(at: stagingFolder)
    }

    enum FolderKind { case missing, empty, proSlide, other }

    func inspect(_ folder: URL) -> FolderKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .other }
        let hasGit = fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path)
        let hasScript = fileManager.fileExists(atPath: folder.appendingPathComponent("Scripts/make-app-bundle.sh").path)
        if hasGit && hasScript { return .proSlide }
        let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.filter { $0 != ".DS_Store" }.isEmpty ? .empty : .other
    }

    private func remember(_ folder: URL) {
        if folder.standardizedFileURL.path == stamp.sourceFolder?.standardizedFileURL.path {
            defaults.removeObject(forKey: UpdateSource.chosenFolderKey)
            defaults.removeObject(forKey: UpdateSource.chosenFolderReplacesKey)
        } else {
            defaults.set(folder.path, forKey: UpdateSource.chosenFolderKey)
            defaults.set(stamp.sourceFolder?.path ?? "", forKey: UpdateSource.chosenFolderReplacesKey)
        }
    }

    /// The folder, once it's known to be a ProSlide download from the built-in address.
    private func preparedFolder() async throws -> URL {
        guard let folder = sourceFolder else { throw UpdateProblem.folderMissing(nil) }
        switch inspect(folder) {
        case .missing: throw UpdateProblem.folderMissing(folder)
        case .empty, .other: throw UpdateProblem.notProSlideFolder(folder)
        case .proSlide: break
        }
        let remote = try await git(folder, ["remote", "get-url", "origin"])
        let address = remote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.status == 0, UpdateSource.sameRepository(address, repositoryURL) else {
            throw UpdateProblem.wrongRemote(address)
        }
        return folder
    }

    /// GitHub's newest published release.
    private func latestRelease() async throws -> UpdateRelease {
        let result: CommandResult
        do {
            result = try await runner.run(curlTool, [
                "--silent", "--show-error", "--location",
                "--proto", "=https", "--max-time", "30",
                "--header", "Accept: application/vnd.github+json",
                "--write-out", "\n%{http_code}",
                latestReleaseURL,
            ], idleTimeout: 45)
        } catch {
            throw UpdateProblem.offline
        }
        guard result.status == 0 else { throw UpdateProblem.offline }
        return try UpdateSource.parseLatestRelease(result.output)
    }

    /// Fetches the release's tag from the built-in address, never from the
    /// folder's own setting, and returns the commit it names.
    private func fetchRelease(_ release: UpdateRelease, into folder: URL, failure: UpdateProblem) async throws -> String {
        let refspec = "+refs/tags/\(release.tag):refs/tags/\(release.tag)"
        let result: CommandResult
        do {
            result = try await git(folder, ["fetch", "--quiet", "--no-tags", repositoryURL, refspec], timeout: 90)
        } catch {
            throw failure
        }
        guard result.status == 0 else { throw failure }
        return try await revParse(folder, "refs/tags/\(release.tag)^{commit}")
    }

    /// Puts the folder exactly at the release, so the build is the release and
    /// nothing else. Local branches, and anything on them, are left alone.
    private func checkOut(_ release: UpdateRelease, in folder: URL) async throws {
        let checkout = try await git(folder, ["checkout", "--quiet", "--detach", "refs/tags/\(release.tag)"])
        guard checkout.status == 0 else {
            throw UpdateProblem.failed("Couldn\u{2019}t switch the ProSlide folder to version \(release.version).")
        }
    }

    private func refuseLocalChanges(_ folder: URL) async throws {
        let status = try await git(folder, ["status", "--porcelain", "--untracked-files=no"])
        guard status.status == 0 else {
            throw UpdateProblem.failed("Couldn\u{2019}t check the ProSlide folder for changes.")
        }
        if !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw UpdateProblem.localChanges(folder)
        }
    }

    /// The installed build's commit when the folder has it, else the folder's own.
    private func installedCommit(_ folder: URL) async throws -> String {
        if let commit = stamp.commit {
            let known = try? await git(folder, ["cat-file", "-e", "\(commit)^{commit}"])
            if known?.status == 0 { return commit }
        }
        return try await revParse(folder, "HEAD")
    }

    private func revParse(_ folder: URL, _ name: String) async throws -> String {
        let result = try await git(folder, ["rev-parse", "--verify", "--quiet", name])
        let commit = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !commit.isEmpty else {
            throw UpdateProblem.failed("Couldn\u{2019}t read the ProSlide folder\u{2019}s version.")
        }
        return commit
    }

    private func git(_ folder: URL, _ arguments: [String], timeout: TimeInterval = 60) async throws -> CommandResult {
        try await runner.run(gitTool, ["-C", folder.path] + arguments, idleTimeout: timeout)
    }

    private func fail(_ error: Error) {
        let problem = Self.problem(from: error)
        log.note("UPDATE FAILED: \(problem)")
        state = .problem(problem)
        isShowingWindow = true
    }

    private static func problem(from error: Error) -> UpdateProblem {
        if let problem = error as? UpdateProblem { return problem }
        if error is DownloadError { return .failed("A step of the update stopped responding. The ProSlide you\u{2019}re using hasn\u{2019}t changed.") }
        return .failed(error.localizedDescription)
    }
}

// MARK: - The installer

/// The shell script that installs a built update. It runs on its own after the
/// app quits, since an app can't replace itself while it runs.
///
/// The old app is moved aside, not deleted, until the new one is in place, so a
/// failed copy puts it back and ProSlide is never left missing.
enum UpdateInstaller {
    static let script = #"""
    pid="$1"; staged="$2"; dest="$3"; relaunch="$4"; log="$5"; failed="$6"
    exec >>"$log" 2>&1
    say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) installer: $*"; }
    say "waiting for ProSlide (pid $pid) to quit"
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 600 ]; then
            say "ProSlide didn't quit within two minutes; the update will be offered again"
            exit 1
        fi
        sleep 0.2
    done
    new="$dest.new"; old="$dest.old"
    rm -rf "$new" "$old"
    if /usr/bin/ditto "$staged" "$new" && mv "$dest" "$old" && mv "$new" "$dest"; then
        rm -rf "$old" "$(dirname "$staged")"
        say "installed $dest"
    else
        say "could not replace $dest"
        if [ -d "$old" ] && [ ! -d "$dest" ]; then mv "$old" "$dest"; fi
        rm -rf "$new"
        echo "Couldn't replace $dest with the new version, so the old one is still installed. The update log has the details." >"$failed"
    fi
    if [ "$relaunch" = 1 ]; then /usr/bin/open "$dest"; fi
    """#

    static func arguments(processID: Int32, stagedApp: URL, installedApp: URL, relaunch: Bool, log: URL, failureMarker: URL) -> [String] {
        ["-c", script, "proslide-installer", String(processID), stagedApp.path, installedApp.path, relaunch ? "1" : "0", log.path, failureMarker.path]
    }
}
