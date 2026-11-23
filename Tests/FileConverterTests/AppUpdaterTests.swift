@testable import FileConverterCore
import XCTest

/// The Update button's logic, against a scripted curl, git and build script:
/// what a check finds, what an update refuses, and that only a finished build
/// of a published release is ever staged. `UpdateInstallerTests` runs the real
/// installer script.
@MainActor
final class AppUpdaterTests: XCTestCase {

    // MARK: - Checking

    func testUpToDateWhenTheInstalledBuildContainsTheRelease() async throws {
        let context = try Context()
        context.fake.releaseContained = true
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .upToDate)
        XCTAssertTrue(updater.isShowingWindow)
        XCTAssertEqual(updater.installedVersion, "1.0.0")
    }

    func testFindsANewerRelease() async throws {
        let context = try Context()
        let updater = context.makeUpdater()

        await updater.check(userInitiated: false)

        guard case .available(let release) = updater.state else { return XCTFail("expected a release, got \(updater.state)") }
        XCTAssertEqual(release.tag, "v1.1.0")
        XCTAssertEqual(release.version, "1.1.0")
        XCTAssertEqual(release.name, "Better bins")
        XCTAssertEqual(release.notes, "What's Changed\n\u{2022} A clearer label")
        XCTAssertEqual(release.date, ISO8601DateFormatter().date(from: "2026-12-03T18:00:00Z"))
        XCTAssertFalse(updater.isShowingWindow, "an automatic check never opens the window")

        let curl = try XCTUnwrap(context.runner.calls.first { $0.first == "curl" })
        XCTAssertEqual(curl.last, UpdateSource.latestReleaseURL)
        let compare = try XCTUnwrap(context.runner.calls.first { $0.contains("merge-base") })
        XCTAssertEqual(Array(compare.suffix(2)), ["ccc", "aaa"], "is the release's commit inside the installed one?")
    }

    func testFetchesTheTagFromTheBuiltInAddressNotTheFoldersSetting() async throws {
        let context = try Context()
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        let fetch = try XCTUnwrap(context.runner.calls.first { $0.contains("fetch") })
        XCTAssertTrue(fetch.contains(UpdateSource.repositoryURL))
        XCTAssertTrue(fetch.contains("+refs/tags/v1.1.0:refs/tags/v1.1.0"))
    }

    func testRefusesAFolderThatDownloadsFromSomewhereElse() async throws {
        let context = try Context()
        context.fake.origin = "https://github.com/someone-else/ProSlide.git"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .problem(.wrongRemote("https://github.com/someone-else/ProSlide.git")))
        XCTAssertFalse(context.runner.calls.contains { $0.contains("fetch") }, "nothing is fetched into an untrusted folder")
    }

    func testNoReleaseYet() async throws {
        let context = try Context()
        context.fake.httpStatus = 404
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        XCTAssertEqual(updater.state, .problem(.noRelease))
    }

    func testOfflineIsReportedOnlyWhenAsked() async throws {
        let context = try Context()
        context.fake.curlFails = true
        let updater = context.makeUpdater()

        await updater.check(userInitiated: false)
        XCTAssertEqual(updater.state, .unknown, "an automatic check fails quietly")
        XCTAssertFalse(updater.isShowingWindow)

        await updater.check(userInitiated: true)
        XCTAssertEqual(updater.state, .problem(.offline))
        XCTAssertTrue(updater.isShowingWindow)
    }

    func testRateLimitingSaysSo() async throws {
        let context = try Context()
        context.fake.httpStatus = 403
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        guard case .problem(.failed(let message)) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertTrue(message.contains("limiting"), message)
    }

    func testATagThatIsntAVersionIsRefused() async throws {
        let context = try Context()
        context.fake.tag = "--upload-pack=evil"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        guard case .problem(.failed) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertFalse(context.runner.calls.contains { $0.contains("fetch") })
    }

    func testAQuietFailureKeepsAReleaseAlreadyFound() async throws {
        let context = try Context()
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)
        guard case .available = updater.state else { return XCTFail("expected a release") }

        context.fake.curlFails = true
        await updater.check(userInitiated: false)

        guard case .available = updater.state else { return XCTFail("the found release was forgotten: \(updater.state)") }
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

    func testAnUnknownInstalledCommitComparesWithTheFoldersHead() async throws {
        let context = try Context()
        context.fake.knownCommits = []
        context.fake.head = "hhh"
        let updater = context.makeUpdater()

        await updater.check(userInitiated: true)

        let compare = try XCTUnwrap(context.runner.calls.first { $0.contains("merge-base") })
        XCTAssertEqual(compare.last, "hhh")
    }

    // MARK: - Updating

    func testAnUpdateChecksOutTheReleaseBuildsTheSameAppAndStagesIt() async throws {
        let context = try Context()
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        updater.update()
        try await waitUntil { updater.state == .ready }

        XCTAssertTrue(updater.isShowingWindow, "a finished update says so")
        let calls = context.runner.calls
        let checkout = try XCTUnwrap(calls.firstIndex { $0.contains("checkout") })
        let build = try XCTUnwrap(calls.firstIndex { $0.first == "bash" })
        let copy = try XCTUnwrap(calls.firstIndex { $0.first == "ditto" })
        XCTAssertTrue(checkout < build && build < copy)
        XCTAssertEqual(Array(calls[checkout].suffix(2)), ["--detach", "refs/tags/v1.1.0"])
        XCTAssertEqual(calls[build], ["bash", context.folder.appendingPathComponent("Scripts/make-app-bundle.sh").path, "--stable"])
        XCTAssertFalse(calls[build].contains("--install"), "the running app is never replaced by the build itself")
        XCTAssertEqual(calls[copy].last, context.staging.appendingPathComponent("ProSlide.app").path)
    }

    func testRefusesToUpdateOverLocalEdits() async throws {
        let context = try Context()
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        context.fake.status = " M README.md"
        updater.update()
        try await waitUntil { updater.state.isProblem }

        XCTAssertEqual(updater.state, .problem(.localChanges(context.folder)))
        XCTAssertFalse(context.runner.calls.contains { $0.contains("checkout") || $0.first == "bash" })
    }

    func testAFailedBuildStagesNothing() async throws {
        let context = try Context()
        context.fake.buildFails = true
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
        let updater = context.makeUpdater()
        await updater.check(userInitiated: false)

        updater.update()
        try await waitUntil { updater.state == .ready }

        let build = try XCTUnwrap(context.runner.calls.first { $0.first == "bash" })
        XCTAssertEqual(build.last, "--beta")
    }

    // MARK: - A missing folder

    func testDownloadAgainClonesIntoTheSameFolderAndBuildsTheRelease() async throws {
        let context = try Context()
        try FileManager.default.removeItem(at: context.folder)
        let updater = context.makeUpdater()
        await updater.check(userInitiated: true)

        updater.downloadAgain()
        try await waitUntil { updater.state == .ready }

        let calls = context.runner.calls
        let clone = try XCTUnwrap(calls.first { $0.contains("clone") })
        XCTAssertEqual(Array(clone.suffix(4)), ["--branch", "main", UpdateSource.repositoryURL, context.folder.path])
        let checkout = try XCTUnwrap(calls.first { $0.contains("checkout") })
        XCTAssertEqual(checkout.last, "refs/tags/v1.1.0", "a fresh download builds the release, not main")
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

    func testOnlyVersionTagsAreReleases() {
        for tag in ["v1", "v1.0", "v1.0.0", "v12.3.45", "v1.0.0.1"] {
            XCTAssertTrue(UpdateSource.isReleaseTag(tag), tag)
        }
        for tag in ["1.0.0", "v1.0.0-beta", "main", "v1..0", "-v1.0.0", "v1.0.0\n", "--upload-pack=x", ""] {
            XCTAssertFalse(UpdateSource.isReleaseTag(tag), tag)
        }
    }

    func testReleaseNotesBecomePlainLines() {
        let markdown = "## What's Changed\r\n* Bin: a clearer label by someone in #31\r\n- Lyrics: faster\r\n\r\n**Full Changelog**: v1.0.0...v1.1.0\r\n"
        XCTAssertEqual(
            UpdateSource.readableNotes(markdown),
            "What's Changed\n\u{2022} Bin: a clearer label by someone in #31\n\u{2022} Lyrics: faster\n\n**Full Changelog**: v1.0.0...v1.1.0"
        )
    }

    func testReadsGitHubsAnswer() throws {
        let release = try UpdateSource.parseLatestRelease(FakeGit.releaseJSON(tag: "v2.0.0", name: "", body: "") + "\n200")
        XCTAssertEqual(release.tag, "v2.0.0")
        XCTAssertNil(release.name, "an empty title is no title")
        XCTAssertEqual(release.notes, "")

        XCTAssertThrowsError(try UpdateSource.parseLatestRelease("{\"message\":\"Not Found\"}\n404")) { error in
            XCTAssertEqual(error as? UpdateProblem, .noRelease)
        }
        XCTAssertThrowsError(try UpdateSource.parseLatestRelease("<html>bad gateway</html>\n502")) { error in
            XCTAssertEqual(error as? UpdateProblem, .offline)
        }
    }

    func testReadsTheBuildStamp() {
        let stamp = BuildStamp(info: [
            "ProSlideSourceFolder": "/Users/me/ProSlide",
            "ProSlideSourceCommit": "abc123",
            "ProSlideSourceDate": "1763800000",
            "CFBundleShortVersionString": "1.2.0",
        ])
        XCTAssertEqual(stamp.sourceFolder?.path, "/Users/me/ProSlide")
        XCTAssertEqual(stamp.commit, "abc123")
        XCTAssertEqual(stamp.commitDate, Date(timeIntervalSince1970: 1_763_800_000))
        XCTAssertEqual(stamp.version, "1.2.0")

        XCTAssertEqual(
            BuildStamp(info: ["ProSlideSourceFolder": "", "ProSlideSourceCommit": "", "CFBundleShortVersionString": "0.0.0"]),
            BuildStamp(),
            "a build outside a git checkout, or before the first release, stamps nothing useful"
        )
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

/// A temporary ProSlide folder, staging folder and defaults, plus scripted tools.
@MainActor
private final class Context {
    let root: URL
    let folder: URL
    let staging: URL
    let defaults: UserDefaults
    let identity: AppIdentity
    let fake: FakeGit
    let runner: ScriptedRunner

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
        self.fake = fake
        runner = ScriptedRunner(fake)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeUpdater(stamp: BuildStamp? = nil) -> AppUpdater {
        AppUpdater(
            stamp: stamp ?? BuildStamp(
                sourceFolder: folder,
                commit: "aaa",
                commitDate: Date(timeIntervalSince1970: 1_763_800_000),
                version: "1.0.0"
            ),
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

/// Answers curl, git, the build script and ditto the way GitHub and a ProSlide
/// folder would. The installed build is "aaa"; the release "v1.1.0" is "ccc".
private final class FakeGit: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    private func value<T>(_ key: String, _ fallback: T) -> T {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? T ?? fallback
    }

    private func store(_ key: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    var origin: String { get { value("origin", UpdateSource.repositoryURL) } set { store("origin", newValue) } }
    var head: String { get { value("head", "aaa") } set { store("head", newValue) } }
    var tag: String { get { value("tag", "v1.1.0") } set { store("tag", newValue) } }
    var httpStatus: Int { get { value("httpStatus", 200) } set { store("httpStatus", newValue) } }
    var curlFails: Bool { get { value("curlFails", false) } set { store("curlFails", newValue) } }
    var releaseContained: Bool { get { value("releaseContained", false) } set { store("releaseContained", newValue) } }
    var status: String { get { value("status", "") } set { store("status", newValue) } }
    var buildFails: Bool { get { value("buildFails", false) } set { store("buildFails", newValue) } }
    var knownCommits: Set<String> { get { value("knownCommits", Set(["aaa"])) } set { store("knownCommits", newValue) } }

    static func releaseJSON(tag: String, name: String, body: String) -> String {
        let payload: [String: Any] = [
            "tag_name": tag,
            "name": name,
            "body": body,
            "published_at": "2026-12-03T18:00:00Z",
            "draft": false,
            "prerelease": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        return String(decoding: data, as: UTF8.self)
    }

    static func makeProSlideFolder(at folder: URL) throws {
        let scripts = folder.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("#!/bin/bash\n".utf8).write(to: scripts.appendingPathComponent("make-app-bundle.sh"))
    }

    func answer(tool: String, arguments: [String]) throws -> CommandResult {
        switch tool {
        case "curl":
            if curlFails { return CommandResult(status: 6, tail: ["curl: (6) Could not resolve host: api.github.com"]) }
            let body = httpStatus == 200
                ? FakeGit.releaseJSON(tag: tag, name: "Better bins", body: "## What's Changed\r\n* A clearer label\r\n")
                : "{\"message\":\"Not Found\"}"
            return CommandResult(status: 0, output: body + "\n\(httpStatus)")
        case "git":
            var args = arguments
            if args.first == "-C" { args.removeFirst(2) }
            switch args.first {
            case "remote": return CommandResult(status: 0, output: origin)
            case "fetch": return CommandResult(status: 0)
            case "rev-parse":
                let name = args.last ?? ""
                return CommandResult(status: 0, output: name.hasPrefix("refs/tags/") ? "ccc" : head)
            case "cat-file":
                let commit = (args.last ?? "").replacingOccurrences(of: "^{commit}", with: "")
                return CommandResult(status: knownCommits.contains(commit) ? 0 : 1)
            case "merge-base": return CommandResult(status: releaseContained ? 0 : 1)
            case "status": return CommandResult(status: 0, output: status)
            case "checkout": return CommandResult(status: 0)
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
    private let fake: FakeGit
    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(_ fake: FakeGit) { self.fake = fake }

    /// Each call as the tool's name followed by its arguments.
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Synchronous, since NSLock can't be taken directly in an async function.
    private func record(_ call: [String]) {
        lock.lock(); recorded.append(call); lock.unlock()
    }

    func run(_ executable: URL, _ arguments: [String], idleTimeout: TimeInterval) async throws -> CommandResult {
        record([executable.lastPathComponent] + arguments)
        return try fake.answer(tool: executable.lastPathComponent, arguments: arguments)
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
