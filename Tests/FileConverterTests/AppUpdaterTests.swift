@testable import FileConverterCore
import XCTest

/// The Update button's logic, against a scripted git and build script: what a
/// check finds, what an update refuses, and that only a finished build is ever
/// staged. `UpdateInstallerTests` runs the real installer script.
@MainActor
final class AppUpdaterTests: XCTestCase {

    // MARK: - Checking

    func testUpToDateWhenTheInstalledCommitIsGitHubsTip() async throws {
        let context = try Context()
        context.git.tip = "aaa"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .upToDate(installedDate: context.installedDate))
        XCTAssertTrue(updater.isShowingWindow)
    }

    func testFindsAnUpdateAndListsWhatChanged() async throws {
        let context = try Context()
        context.git.history = [
            "ccc\u{1F}1764000000\u{1F}Merge pull request #30 from v3ndsxg/thing",
            "bbb\u{1F}1763990000\u{1F}Bin: a clearer label",
        ].joined(separator: "\n")
        let updater = context.makeUpdater()

        await updater.check(userInitiated: false)

        guard case .available(let offer) = updater.state else { return XCTFail("expected an update, got \(updater.state)") }
        XCTAssertEqual(offer.branch, "main")
        XCTAssertFalse(offer.isOffMain)
        XCTAssertEqual(offer.installedDate, context.installedDate)
        XCTAssertEqual(offer.newDate, Date(timeIntervalSince1970: 1_764_000_000), "the new version's date is the tip's, merge or not")
        XCTAssertEqual(offer.changes.map(\.title), ["Bin: a clearer label"], "GitHub's merge commits aren't listed")
        XCTAssertFalse(updater.isShowingWindow, "an automatic check never opens the window")

        let log = try XCTUnwrap(context.runner.calls.first { $0.contains("log") })
        XCTAssertTrue(log.contains("aaa..ccc"), "changes are counted from the installed version: \(log)")
    }

    func testFetchesFromTheBuiltInAddressNotTheFoldersSetting() async throws {
        let context = try Context()
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        let fetch = try XCTUnwrap(context.runner.calls.first { $0.contains("fetch") })
        XCTAssertTrue(fetch.contains(UpdateSource.repositoryURL))
        XCTAssertTrue(fetch.contains("+refs/heads/main:refs/remotes/origin/main"))
    }

    func testAFolderOnAnotherBranchSaysSo() async throws {
        let context = try Context()
        context.git.branch = "app-updater"
        context.git.history = "ccc\u{1F}1764000000\u{1F}Test change"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        guard case .available(let offer) = updater.state else { return XCTFail("expected an update, got \(updater.state)") }
        XCTAssertTrue(offer.isOffMain)
        XCTAssertEqual(offer.branch, "app-updater")
    }

    func testRefusesAFolderThatDownloadsFromSomewhereElse() async throws {
        let context = try Context()
        context.git.origin = "https://github.com/someone-else/ProSlide.git"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .problem(.wrongRemote("https://github.com/someone-else/ProSlide.git")))
        XCTAssertFalse(context.runner.calls.contains { $0.contains("fetch") }, "nothing is fetched from an untrusted folder")
    }

    func testRefusesAFolderThatIsntOnABranch() async throws {
        let context = try Context()
        context.git.branch = nil
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .problem(.notOnBranch(context.folder)))
    }

    func testOfflineIsReportedOnlyWhenAsked() async throws {
        let context = try Context()
        context.git.fetchFails = true
        let updater = context.makeUpdater()

        await updater.check(userInitiated: false)
        XCTAssertEqual(updater.state, .unknown, "an automatic check fails quietly")
        XCTAssertFalse(updater.isShowingWindow)

        await updater.check(userInitiated: true)
        XCTAssertEqual(updater.state, .problem(.offline))
        XCTAssertTrue(updater.isShowingWindow)
    }

    func testAQuietFailureKeepsAnUpdateAlreadyFound() async throws {
        let context = try Context()
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)
        guard case .available = updater.state else { return XCTFail("expected an update") }

        context.git.fetchFails = true
        await updater.check(userInitiated: false)

        guard case .available = updater.state else { return XCTFail("the found update was forgotten: \(updater.state)") }
    }

    func testAMissingFolderIsReported() async throws {
        let context = try Context()
        try FileManager.default.removeItem(at: context.folder)
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .problem(.folderMissing(context.folder)))
    }

    func testAnAppThatNeverKnewItsFolderSaysSo() async throws {
        let context = try Context()
        let updater = context.makeUpdater(stamp: BuildStamp())

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .problem(.folderMissing(nil)))
    }

    func testAnUnknownInstalledCommitCountsFromTheFoldersHead() async throws {
        let context = try Context()
        context.git.knownCommits = []
        context.git.head = "hhh"
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        let log = try XCTUnwrap(context.runner.calls.first { $0.contains("log") })
        XCTAssertTrue(log.contains("hhh..ccc"), "\(log)")
    }

    // MARK: - Updating

    func testAnUpdatePullsBuildsTheSameAppAndStagesIt() async throws {
        let context = try Context()
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        updater.update()
        try await waitUntil { updater.state == .ready }

        XCTAssertTrue(updater.isShowingWindow, "a finished update says so")
        let calls = context.runner.calls
        let merge = try XCTUnwrap(calls.firstIndex { $0.contains("merge") })
        let build = try XCTUnwrap(calls.firstIndex { $0.first == "bash" })
        let copy = try XCTUnwrap(calls.firstIndex { $0.first == "ditto" })
        XCTAssertTrue(merge < build && build < copy)
        XCTAssertTrue(calls[merge].contains("--ff-only"))
        XCTAssertEqual(calls[build], ["bash", context.folder.appendingPathComponent("Scripts/make-app-bundle.sh").path, "--stable"])
        XCTAssertFalse(calls[build].contains("--install"), "the running app is never replaced by the build itself")
        XCTAssertEqual(calls[copy].last, context.staging.appendingPathComponent("ProSlide.app").path)
    }

    func testRefusesToUpdateOverLocalEdits() async throws {
        let context = try Context()
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        context.git.status = " M README.md"
        updater.update()
        try await waitUntil { updater.state.isProblem }

        XCTAssertEqual(updater.state, .problem(.localChanges(context.folder)))
        XCTAssertFalse(context.runner.calls.contains { $0.contains("merge") || $0.first == "bash" })
    }

    func testRefusesToUpdateOverUnpublishedCommits() async throws {
        let context = try Context()
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        context.git.ahead = "2"
        updater.update()
        try await waitUntil { updater.state.isProblem }

        XCTAssertEqual(updater.state, .problem(.localChanges(context.folder)))
    }

    func testAFailedBuildStagesNothing() async throws {
        let context = try Context()
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        context.git.buildFails = true
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        updater.update()
        try await waitUntil { updater.state.isProblem }

        guard case .problem(.failed(let message)) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertTrue(message.contains("didn\u{2019}t build"), message)
        XCTAssertFalse(context.runner.calls.contains { $0.first == "ditto" })
        XCTAssertFalse(updater.launchInstaller(relaunch: false), "there's nothing to install")
    }

    func testTheBetaRebuildsTheBeta() async throws {
        let context = try Context(appName: "ProSlide Beta", isBeta: true)
        context.git.history = "ccc\u{1F}1764000000\u{1F}Something new"
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        updater.update()
        try await waitUntil { updater.state == .ready }

        let build = try XCTUnwrap(context.runner.calls.first { $0.first == "bash" })
        XCTAssertEqual(build.last, "--beta")
    }

    // MARK: - A missing folder

    func testDownloadAgainClonesMainIntoTheSameFolderAndBuilds() async throws {
        let context = try Context()
        try FileManager.default.removeItem(at: context.folder)
        let updater = context.makeUpdater()
        await updater.check(userInitiated: true)

        updater.downloadAgain()
        try await waitUntil { updater.state == .ready }

        let clone = try XCTUnwrap(context.runner.calls.first { $0.contains("clone") })
        XCTAssertEqual(Array(clone.suffix(4)), ["--branch", "main", UpdateSource.repositoryURL, context.folder.path])
        XCTAssertEqual(updater.sourceFolder, context.folder)
    }

    func testAnotherLocationIsRememberedForThisBuildOnly() async throws {
        let context = try Context()
        try FileManager.default.removeItem(at: context.folder)
        let elsewhere = context.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let updater = context.makeUpdater()
        await updater.check(userInitiated: true)

        updater.useLocation(elsewhere)
        try await waitUntil { updater.state == .ready }

        let target = elsewhere.appendingPathComponent("ProSlide", isDirectory: true)
        XCTAssertEqual(updater.sourceFolder?.path, target.path)
        XCTAssertEqual(context.makeUpdater().sourceFolder?.path, target.path, "the choice survives a relaunch")

        let rebuilt = context.makeUpdater(stamp: BuildStamp(sourceFolder: target, commit: "ccc"))
        XCTAssertEqual(rebuilt.sourceFolder?.path, target.path, "an app built from the new folder knows it anyway")
        let other = context.root.appendingPathComponent("Other", isDirectory: true)
        let manual = context.makeUpdater(stamp: BuildStamp(sourceFolder: other, commit: "ccc"))
        XCTAssertEqual(manual.sourceFolder, other, "a later build from another folder isn't overridden")
    }

    func testPickingAnExistingProSlideFolderUsesIt() async throws {
        let context = try Context()
        let moved = context.root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: context.folder, to: moved)
        let updater = context.makeUpdater()
        await updater.check(userInitiated: true)

        updater.useLocation(moved)
        try await waitUntil { updater.state.hasChecked }

        XCTAssertEqual(updater.sourceFolder?.path, moved.path)
        XCTAssertFalse(context.runner.calls.contains { $0.contains("clone") })
    }

    func testWontDownloadOverAnUnrelatedFolder() async throws {
        let context = try Context()
        try FileManager.default.removeItem(at: context.folder)
        let elsewhere = context.root.appendingPathComponent("Elsewhere", isDirectory: true)
        let taken = elsewhere.appendingPathComponent("ProSlide", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: taken.appendingPathComponent("notes.txt"))
        let updater = context.makeUpdater()

        updater.useLocation(elsewhere)

        XCTAssertEqual(updater.state, .problem(.notProSlideFolder(taken)))
        XCTAssertFalse(context.runner.calls.contains { $0.contains("clone") })
    }

    // MARK: - Launch

    func testAnUpdateBuiltEarlierIsOfferedAgainAtLaunch() throws {
        let context = try Context()
        try context.stageApp(commit: "ccc")

        XCTAssertEqual(context.makeUpdater().state, .ready)
    }

    func testAStagedCopyOfTheRunningVersionIsThrownAway() throws {
        let context = try Context()
        try context.stageApp(commit: "aaa")

        XCTAssertEqual(context.makeUpdater().state, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.staging.path))
    }

    func testAFailedInstallIsReportedAtLaunch() throws {
        let context = try Context()
        try context.stageApp(commit: "ccc")
        try Data("Couldn't replace it.".utf8).write(to: context.staging.appendingPathComponent("install-failed.txt"))

        let updater = context.makeUpdater()

        XCTAssertEqual(updater.state, .problem(.failed("Couldn't replace it.")))
        XCTAssertTrue(updater.isShowingWindow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.staging.path), "the failed update isn't offered forever")
    }

    // MARK: - Pieces

    func testRepositoryAddressesMatchLoosely() {
        let address = UpdateSource.repositoryURL
        XCTAssertTrue(UpdateSource.sameRepository(address, "https://github.com/v3ndsxg/ProSlide"))
        XCTAssertTrue(UpdateSource.sameRepository(address, "https://GitHub.com/v3ndsxg/proslide.git/\n"))
        XCTAssertFalse(UpdateSource.sameRepository(address, "git@github.com:v3ndsxg/ProSlide.git"))
        XCTAssertFalse(UpdateSource.sameRepository(address, "https://github.com/v3ndsxg/ProSlide-fork.git"))
        XCTAssertFalse(UpdateSource.sameRepository(address, ""))
    }

    func testReadsTheBuildStamp() {
        let stamp = BuildStamp(info: [
            "ProSlideSourceFolder": "/Users/me/ProSlide",
            "ProSlideSourceCommit": "abc123",
            "ProSlideSourceDate": "1763800000",
            "ProSlideSourceBranch": "main",
        ])
        XCTAssertEqual(stamp.sourceFolder?.path, "/Users/me/ProSlide")
        XCTAssertEqual(stamp.commit, "abc123")
        XCTAssertEqual(stamp.commitDate, Date(timeIntervalSince1970: 1_763_800_000))
        XCTAssertEqual(stamp.branch, "main")

        XCTAssertEqual(BuildStamp(info: ["ProSlideSourceFolder": "", "ProSlideSourceCommit": ""]), BuildStamp(),
                       "a build outside a git checkout stamps empty strings")
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting", file: file, line: line)
    }
}

private extension UpdateState {
    var isProblem: Bool {
        if case .problem = self { return true }
        return false
    }

    /// A check finished and found the folder fine.
    var hasChecked: Bool {
        switch self {
        case .upToDate, .available: return true
        default: return false
        }
    }
}

/// A temporary ProSlide folder, staging folder and defaults, plus a scripted git.
@MainActor
private final class Context {
    let root: URL
    let folder: URL
    let staging: URL
    let defaults: UserDefaults
    let identity: AppIdentity
    let git: FakeGit
    let runner: ScriptedRunner
    let installedDate = Date(timeIntervalSince1970: 1_763_800_000)

    init(appName: String = "ProSlide", isBeta: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("ProSlide", isDirectory: true)
        try FakeGit.makeProSlideFolder(at: folder)
        self.root = root
        self.folder = folder
        staging = root.appendingPathComponent("Staging", isDirectory: true)
        defaults = UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        identity = AppIdentity(info: [
            "CFBundleDisplayName": appName,
            "ProSlideDataFolder": appName,
            "ProSlideIsBeta": isBeta,
        ])
        let fake = FakeGit()
        git = fake
        runner = ScriptedRunner(fake)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeUpdater(stamp: BuildStamp? = nil) -> AppUpdater {
        AppUpdater(
            stamp: stamp ?? BuildStamp(sourceFolder: folder, commit: "aaa", commitDate: installedDate, branch: "main"),
            identity: identity,
            runner: runner,
            log: DownloadLog(fileURL: root.appendingPathComponent("update.log")),
            defaults: defaults,
            stagingFolder: staging,
            installedApp: root.appendingPathComponent("Applications/\(identity.displayName).app", isDirectory: true)
        )
    }

    func stageApp(commit: String) throws {
        let contents = staging.appendingPathComponent("\(identity.displayName).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["ProSlideSourceCommit": commit], format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

/// Answers git, the build script and ditto the way a ProSlide folder would.
private final class FakeGit: @unchecked Sendable {
    private let lock = NSLock()
    private var _origin = UpdateSource.repositoryURL
    private var _branch: String? = "main"
    private var _head = "aaa"
    private var _tip = "ccc"
    private var _history = ""
    private var _status = ""
    private var _ahead = "0"
    private var _fetchFails = false
    private var _buildFails = false
    private var _knownCommits: Set<String> = ["aaa"]

    var origin: String { get { locked { _origin } } set { locked { _origin = newValue } } }
    var branch: String? { get { locked { _branch } } set { locked { _branch = newValue } } }
    var head: String { get { locked { _head } } set { locked { _head = newValue } } }
    var tip: String { get { locked { _tip } } set { locked { _tip = newValue } } }
    var history: String { get { locked { _history } } set { locked { _history = newValue } } }
    var status: String { get { locked { _status } } set { locked { _status = newValue } } }
    var ahead: String { get { locked { _ahead } } set { locked { _ahead = newValue } } }
    var fetchFails: Bool { get { locked { _fetchFails } } set { locked { _fetchFails = newValue } } }
    var buildFails: Bool { get { locked { _buildFails } } set { locked { _buildFails = newValue } } }
    var knownCommits: Set<String> { get { locked { _knownCommits } } set { locked { _knownCommits = newValue } } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    static func makeProSlideFolder(at folder: URL) throws {
        let scripts = folder.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("#!/bin/bash\n".utf8).write(to: scripts.appendingPathComponent("make-app-bundle.sh"))
    }

    func answer(tool: String, arguments: [String]) throws -> CommandResult {
        switch tool {
        case "git":
            var args = arguments
            if args.first == "-C" { args.removeFirst(2) }
            switch args.first {
            case "remote": return CommandResult(status: 0, output: origin)
            case "symbolic-ref": return branch.map { CommandResult(status: 0, output: $0) } ?? CommandResult(status: 1)
            case "fetch":
                return fetchFails ? CommandResult(status: 128, tail: ["fatal: unable to access the repository"]) : CommandResult(status: 0)
            case "rev-parse": return CommandResult(status: 0, output: args.last == "HEAD" ? head : tip)
            case "cat-file":
                let commit = (args.last ?? "").replacingOccurrences(of: "^{commit}", with: "")
                return CommandResult(status: knownCommits.contains(commit) ? 0 : 1)
            case "log": return CommandResult(status: 0, output: history)
            case "status": return CommandResult(status: 0, output: status)
            case "rev-list": return CommandResult(status: 0, output: ahead)
            case "merge": return CommandResult(status: 0)
            case "clone":
                try FakeGit.makeProSlideFolder(at: URL(fileURLWithPath: args.last ?? "", isDirectory: true))
                return CommandResult(status: 0)
            default: return CommandResult(status: 1)
            }
        case "bash":
            if buildFails { return CommandResult(status: 1, tail: ["error: build failed"]) }
            // The script is <folder>/Scripts/make-app-bundle.sh; it builds <folder>/build/<App>.app.
            let folder = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
            let name = arguments.last == "--beta" ? "ProSlide Beta" : "ProSlide"
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("build/\(name).app"), withIntermediateDirectories: true)
            return CommandResult(status: 0)
        case "ditto":
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: arguments[1]), withIntermediateDirectories: true)
            return CommandResult(status: 0)
        default:
            return CommandResult(status: 127)
        }
    }
}

private final class ScriptedRunner: UpdateCommandRunner, @unchecked Sendable {
    private let git: FakeGit
    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(_ git: FakeGit) { self.git = git }

    /// Each call as the tool's name followed by its arguments.
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: URL, _ arguments: [String], idleTimeout: TimeInterval) async throws -> CommandResult {
        lock.lock(); recorded.append([executable.lastPathComponent] + arguments); lock.unlock()
        return try git.answer(tool: executable.lastPathComponent, arguments: arguments)
    }
}

/// The real installer script, with the real `ditto`, on throwaway folders. It
/// is told to wait for a process that has already exited, and not to relaunch.
final class UpdateInstallerTests: XCTestCase {

    func testSwapsTheNewAppInAndCleansUp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try makeApp(root.appendingPathComponent("Applications/ProSlide.app"), marker: "old")
        let staged = try makeApp(root.appendingPathComponent("Update/ProSlide.app"), marker: "new")
        let failure = root.appendingPathComponent("Update/install-failed.txt")

        try runInstaller(staged: staged, installed: installed, root: root, failure: failure)

        XCTAssertEqual(try marker(installed), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path + ".old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path + ".new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path),
                       "the staging folder goes once the update is in")
    }

    func testAFailedCopyLeavesTheOldAppAndSaysSo() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try makeApp(root.appendingPathComponent("Applications/ProSlide.app"), marker: "old")
        let update = root.appendingPathComponent("Update", isDirectory: true)
        try FileManager.default.createDirectory(at: update, withIntermediateDirectories: true)
        let failure = update.appendingPathComponent("install-failed.txt")

        try runInstaller(staged: update.appendingPathComponent("Missing.app"), installed: installed, root: root, failure: failure)

        XCTAssertEqual(try marker(installed), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.path))
    }

    private func runInstaller(staged: URL, installed: URL, root: URL, failure: URL) throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = UpdateInstaller.arguments(
            processID: finished.processIdentifier,
            stagedApp: staged,
            installedApp: installed,
            relaunch: false,
            log: root.appendingPathComponent("update.log"),
            failureMarker: failure
        )
        try installer.run()
        installer.waitUntilExit()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeApp(_ app: URL, marker: String) throws -> URL {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        return app
    }

    private func marker(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }
}
