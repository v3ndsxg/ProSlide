import Foundation

// MARK: - What the build stamped

/// Where the running app was built from, as `Scripts/make-app-bundle.sh` stamped
/// it into Info.plist: the folder to pull and rebuild, and the version installed.
///
/// Every field is optional. A build from a folder that isn't a git checkout, or
/// an app from before the Update button, has none of them.
public struct BuildStamp: Equatable, Sendable {
    public var sourceFolder: URL?
    public var commit: String?
    public var commitDate: Date?
    public var branch: String?

    public static let current = BuildStamp(bundle: .main)

    public init(sourceFolder: URL? = nil, commit: String? = nil, commitDate: Date? = nil, branch: String? = nil) {
        self.sourceFolder = sourceFolder
        self.commit = commit
        self.commitDate = commitDate
        self.branch = branch
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
        branch = text("ProSlideSourceBranch")
    }
}

// MARK: - Fixed facts

/// The constants the updater trusts. The repository address is built in rather
/// than read from the folder, so changing a setting in the folder can't redirect
/// updates somewhere else.
public enum UpdateSource {
    public static let repositoryURL = "https://github.com/v3ndsxg/ProSlide.git"
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

    /// Reads `git log --format=%H%x1f%ct%x1f%s`, newest first.
    static func parseChanges(_ output: String) -> [UpdateChange] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let seconds = TimeInterval(fields[1]) else { return nil }
            return UpdateChange(commit: String(fields[0]), date: Date(timeIntervalSince1970: seconds), title: String(fields[2]))
        }
    }

    /// The changes worth listing: GitHub's "Merge pull request …" commits say
    /// nothing the commits they merge don't. Kept if they are all there is.
    static func listedChanges(_ changes: [UpdateChange]) -> [UpdateChange] {
        let real = changes.filter { !$0.title.hasPrefix("Merge pull request ") && !$0.title.hasPrefix("Merge branch ") }
        return real.isEmpty ? changes : real
    }
}

// MARK: - State

public struct UpdateChange: Equatable, Sendable, Identifiable {
    public let commit: String
    public let date: Date
    public let title: String
    public var id: String { commit }
}

/// An update that is waiting on GitHub.
public struct UpdateOffer: Equatable, Sendable {
    public let branch: String
    public let installedDate: Date?
    public let newDate: Date
    /// Newest first.
    public let changes: [UpdateChange]

    /// The folder follows a branch other than main, as when testing the updater.
    public var isOffMain: Bool { branch != UpdateSource.mainBranch }
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
    /// The folder the app was built from is gone. Nil when the app never knew it.
    case folderMissing(URL?)
    /// The folder exists but isn't a ProSlide download.
    case notProSlideFolder(URL)
    /// The folder downloads from somewhere other than the built-in address.
    case wrongRemote(String)
    /// The folder has edits or commits that aren't on GitHub.
    case localChanges(URL)
    /// The folder isn't on a branch, so there is nothing to follow.
    case notOnBranch(URL)
    /// A step failed; the message says which. The installed app is untouched.
    case failed(String)
}

public enum UpdateState: Equatable, Sendable {
    /// Not checked yet, or the last automatic check failed quietly.
    case unknown
    case checking
    case upToDate(installedDate: Date?)
    case available(UpdateOffer)
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

/// Runs git, the build script and ditto. Tests replace it with a script.
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

/// Keeps ProSlide up to date from the folder it was built from: checks GitHub,
/// pulls, rebuilds with the packaging script, and swaps the new app in once this
/// one has quit.
///
/// Nothing is installed without the operator pressing Update. A failed step
/// leaves the installed app as it was; only a finished build is ever swapped in.
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
    let runner: UpdateCommandRunner
    let defaults: UserDefaults
    let stagingFolder: URL
    let installedApp: URL
    /// The build script's output is `build/<appName>.app`.
    let appName: String
    /// Rebuilds the same app that is running.
    let variantFlag: String

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
        runner: UpdateCommandRunner? = nil,
        log: DownloadLog = DownloadLog(fileURL: UpdateSource.defaultLogURL),
        defaults: UserDefaults = .standard,
        stagingFolder: URL = UpdateSource.defaultStagingFolder,
        installedApp: URL = Bundle.main.bundleURL
    ) {
        self.stamp = stamp
        self.repositoryURL = repositoryURL
        self.runner = runner ?? LoggedCommandRunner(log: log)
        self.log = log
        self.defaults = defaults
        self.stagingFolder = stagingFolder
        self.installedApp = installedApp
        appName = identity.displayName
        variantFlag = identity.isBeta ? "--beta" : "--stable"
        restoreStagedUpdate()
    }

    var stagedApp: URL { stagingFolder.appendingPathComponent("\(appName).app", isDirectory: true) }
    /// Written by the installer when it couldn't swap the app in.
    var failureMarker: URL { stagingFolder.appendingPathComponent("install-failed.txt") }

    /// The folder updates come from: the one the operator chose after the
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
    /// unless an update is found, and nothing is installed.
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

    /// Asks GitHub whether there's anything new. A check the operator started
    /// opens the window and reports problems; an automatic one fails silently.
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
        let (folder, branch) = try await preparedFolder()
        try await fetch(folder, branch: branch, failure: .offline)
        let tip = try await revParse(folder, "refs/remotes/origin/\(branch)")
        let base = try await installedBase(folder)
        guard base != tip else { return .upToDate(installedDate: stamp.commitDate) }
        let history = try await git(folder, ["log", "--format=%H%x1f%ct%x1f%s", "\(base)..\(tip)"])
        guard history.status == 0 else { throw UpdateProblem.failed("Couldn\u{2019}t read what changed in the ProSlide folder.") }
        let changes = UpdateSource.parseChanges(history.output)
        guard let newest = changes.first else { return .upToDate(installedDate: stamp.commitDate) }
        return .available(UpdateOffer(
            branch: branch,
            installedDate: stamp.commitDate,
            newDate: newest.date,
            changes: UpdateSource.listedChanges(changes)
        ))
    }

    // MARK: Updating

    /// Pulls and rebuilds in the background; the app keeps working meanwhile.
    public func update() {
        guard case .available = state else { return }
        state = .updating(.downloading)
        Task {
            do {
                let (folder, branch) = try await preparedFolder()
                try await fetch(folder, branch: branch, failure: .failed(
                    "Couldn\u{2019}t download the update. Check your internet connection and try again."
                ))
                try await refuseLocalChanges(folder, branch: branch)
                let merge = try await git(folder, ["merge", "--ff-only", "--quiet", "refs/remotes/origin/\(branch)"])
                guard merge.status == 0 else {
                    throw UpdateProblem.failed("Couldn\u{2019}t apply the update to the ProSlide folder.")
                }
                try await buildAndStage(folder)
            } catch {
                fail(error)
            }
        }
    }

    /// Downloads ProSlide again into the folder it was built from, then builds it.
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

    /// The folder and its branch, once it's known to be a clean ProSlide
    /// download from the built-in address.
    private func preparedFolder() async throws -> (URL, String) {
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
        let head = try await git(folder, ["symbolic-ref", "--short", "-q", "HEAD"])
        let branch = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, !branch.isEmpty else { throw UpdateProblem.notOnBranch(folder) }
        return (folder, branch)
    }

    /// Fetches the branch from the built-in address, never from the folder's own setting.
    private func fetch(_ folder: URL, branch: String, failure: UpdateProblem) async throws {
        let refspec = "+refs/heads/\(branch):refs/remotes/origin/\(branch)"
        let result: CommandResult
        do {
            result = try await git(folder, ["fetch", "--quiet", "--no-tags", repositoryURL, refspec], timeout: 90)
        } catch {
            throw failure
        }
        guard result.status == 0 else {
            if result.tail.contains(where: { $0.contains("couldn't find remote ref") }) {
                throw UpdateProblem.failed("The \u{201C}\(branch)\u{201D} branch the ProSlide folder follows isn\u{2019}t on GitHub any more.")
            }
            throw failure
        }
    }

    private func refuseLocalChanges(_ folder: URL, branch: String) async throws {
        let status = try await git(folder, ["status", "--porcelain", "--untracked-files=no"])
        let ahead = try await git(folder, ["rev-list", "--count", "refs/remotes/origin/\(branch)..HEAD"])
        guard status.status == 0, ahead.status == 0 else {
            throw UpdateProblem.failed("Couldn\u{2019}t check the ProSlide folder for changes.")
        }
        let edited = !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let unpublished = ahead.output.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
        if edited || unpublished { throw UpdateProblem.localChanges(folder) }
    }

    /// The installed version's commit when the folder has it, else the folder's own.
    private func installedBase(_ folder: URL) async throws -> String {
        if let commit = stamp.commit {
            let known = try? await git(folder, ["cat-file", "-e", "\(commit)^{commit}"])
            if known?.status == 0 { return commit }
        }
        return try await revParse(folder, "HEAD")
    }

    private func revParse(_ folder: URL, _ name: String) async throws -> String {
        let result = try await git(folder, ["rev-parse", name])
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
