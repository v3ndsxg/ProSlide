import AppKit
import FileConverterCore
import SwiftUI

extension AppUpdater {
    /// The app's one updater, shared by the window, the menu and the app delegate.
    @MainActor static let shared = AppUpdater()
}

/// Adds the Update button to the title bar, the update window and the daily
/// check, and restarts ProSlide as soon as an update is built.
struct UpdateSupport: ViewModifier {
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var queue: ConversionQueue
    @EnvironmentObject private var downloads: DownloadQueue

    /// What a restart would interrupt, or nil when nothing is running.
    private var busyReason: String? {
        UpdateSupport.busyReason(queue: queue, downloads: downloads)
    }

    static func busyReason(queue: ConversionQueue, downloads: DownloadQueue) -> String? {
        if queue.isConverting { return "A conversion is still running." }
        if downloads.isDownloading { return "A download is still running." }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) { UpdateButton() }
            }
            .sheet(isPresented: $updater.isShowingWindow, onDismiss: { updater.dismiss() }) {
                UpdateWindow(updater: updater, busyReason: busyReason, restartNow: restartNow)
            }
            // The operator agreed to the restart when they pressed Update, so a
            // finished build restarts straight away, or once the running
            // conversion or download is done.
            .onChange(of: updater.state == .ready) { ready in
                if ready && busyReason == nil { restartNow() }
            }
            .onChange(of: busyReason == nil) { idle in
                if idle && updater.state == .ready { restartNow() }
            }
            .task {
                updater.startAutomaticChecks()
                // An update built before a crash or a force quit installs now.
                if updater.state == .ready && busyReason == nil { restartNow() }
            }
    }

    /// Starts the installer, then quits so it can swap the new app in and
    /// reopen it. The update window is closed first, since AppKit can decline
    /// to quit while a sheet is attached, and if ProSlide is still running two
    /// seconds later it exits anyway: the installer is already waiting for it.
    private func restartNow() {
        guard updater.launchInstaller(relaunch: true) else { return }
        updater.isShowingWindow = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            exit(0)
        }
    }
}

/// The title-bar button. A plain icon until there's something to do.
struct UpdateButton: View {
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var queue: ConversionQueue
    @EnvironmentObject private var downloads: DownloadQueue

    var body: some View {
        switch updater.state {
        case .available:
            Button { updater.showOrCheck() } label: {
                Label("Update Available", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .help("A new version of ProSlide is available")
        case .updating, .ready:
            Button { updater.showOrCheck() } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progressLabel)
                }
            }
            .help("ProSlide is updating and will restart on its own when it\u{2019}s done.")
        case .unknown, .checking, .upToDate, .problem:
            Button { updater.showOrCheck() } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("Check for Updates")
        }
    }

    private var progressLabel: String {
        guard updater.state == .ready else { return "Updating\u{2026}" }
        let busy = UpdateSupport.busyReason(queue: queue, downloads: downloads) != nil
        return busy ? "Restarting when done\u{2026}" : "Restarting\u{2026}"
    }
}

/// The update window: what's new, the restart warning, progress, or what went wrong.
struct UpdateWindow: View {
    @ObservedObject var updater: AppUpdater
    let busyReason: String?
    let restartNow: () -> Void
    @State private var confirmingUpdate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .alert("ProSlide will restart to finish updating", isPresented: $confirmingUpdate) {
            Button("Cancel", role: .cancel) {}
            Button("Update and Restart") { updater.update() }
        } message: {
            Text("The update builds in the background, which takes a few minutes, and you can keep working. When it\u{2019}s done, ProSlide closes and opens again on its own. A conversion or download that\u{2019}s still running finishes first.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .unknown, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for updates\u{2026}")
            }
            buttons { Button("Close") { updater.dismiss() }.keyboardShortcut(.cancelAction) }

        case .upToDate:
            Text("ProSlide is up to date").font(.title2.weight(.semibold))
            if let installed = installedDescription {
                Text("You have \(installed).").foregroundStyle(.secondary)
            }
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .available(let release):
            Text("ProSlide \(release.version) is available").font(.title2.weight(.semibold))
            Text(versions(release)).foregroundStyle(.secondary)
            releaseNotes(release)
            Text("ProSlide restarts on its own when the update is installed.").font(.callout).foregroundStyle(.secondary)
            buttons {
                Button("Cancel") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update") { confirmingUpdate = true }.keyboardShortcut(.defaultAction)
            }

        case .updating(let step):
            Text("Updating ProSlide").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(step.description)
            }
            Text("You can close this window and keep working. ProSlide restarts on its own when the update is ready.")
                .font(.callout).foregroundStyle(.secondary)
            buttons { Button("Close") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .ready:
            Text("Restarting ProSlide").font(.title2.weight(.semibold))
            if let busyReason {
                Text("The update is ready. \(busyReason) ProSlide restarts as soon as it finishes.")
                    .foregroundStyle(.secondary)
                buttons {
                    Button("Close") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Restart Now", role: .destructive) { restartNow() }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("ProSlide closes and opens again in a moment.")
                }
            }

        case .problem(let problem):
            problemView(problem)
        }
    }

    @ViewBuilder
    private func problemView(_ problem: UpdateProblem) -> some View {
        switch problem {
        case .offline:
            heading("Couldn\u{2019}t reach GitHub")
            Text("Check your internet connection and try again.").foregroundStyle(.secondary)
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .noRelease:
            heading("No release yet")
            Text("ProSlide updates come from releases published on GitHub, and none has been published yet.")
                .foregroundStyle(.secondary)
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .folderMissing(let folder):
            heading("The ProSlide folder is missing")
            if let folder {
                Text("ProSlide updates itself from the folder it was installed from, \(folder.path), and that folder isn\u{2019}t there any more. Download it again from GitHub to keep getting updates.")
                    .foregroundStyle(.secondary)
            } else {
                Text("This copy of ProSlide doesn\u{2019}t know which folder it was installed from. Choose where to download ProSlide from GitHub, and it will update from there.")
                    .foregroundStyle(.secondary)
            }
            buttons {
                Button("Cancel") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Another Location\u{2026}") { chooseLocation() }
                if folder != nil {
                    Button("Download Again") { updater.downloadAgain() }.keyboardShortcut(.defaultAction)
                }
            }

        case .notProSlideFolder(let folder):
            heading("That isn\u{2019}t a ProSlide folder")
            Text("\(folder.path) already exists and isn\u{2019}t a ProSlide download, so ProSlide won\u{2019}t use it. Choose another location.")
                .foregroundStyle(.secondary)
            buttons {
                Button("Cancel") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Another Location\u{2026}") { chooseLocation() }.keyboardShortcut(.defaultAction)
            }

        case .wrongRemote(let address):
            heading("ProSlide can\u{2019}t update from this folder")
            Text("The ProSlide folder downloads from \(address.isEmpty ? "an unknown address" : address) instead of \(UpdateSource.repositoryURL), so ProSlide won\u{2019}t update from it.")
                .foregroundStyle(.secondary)
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .localChanges(let folder):
            heading("The ProSlide folder has changes")
            Text("Someone changed files in \(folder.path). ProSlide won\u{2019}t update over them. Remove the changes, or publish them to GitHub, and try again.")
                .foregroundStyle(.secondary)
            buttons {
                Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction)
            }

        case .failed(let message):
            heading("The update didn\u{2019}t finish")
            Text(message).foregroundStyle(.secondary)
            buttons {
                Button("Show Log") {
                    updater.log.ensureExists()
                    NSWorkspace.shared.activateFileViewerSelecting([updater.log.fileURL])
                }
                Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.title2.weight(.semibold))
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 6)
    }

    private func releaseNotes(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(release.name ?? "What\u{2019}s new").font(.headline)
            ScrollView {
                Text(release.notes.isEmpty ? "No notes for this release." : release.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
    }

    /// "version 1.0.0, from November 22, 2026", or as much of it as is known.
    private var installedDescription: String? {
        switch (updater.installedVersion, updater.installedDate) {
        case let (version?, date?): return "version \(version), from \(day(date))"
        case let (version?, nil): return "version \(version)"
        case let (nil, date?): return "the version from \(day(date))"
        case (nil, nil): return nil
        }
    }

    private func versions(_ release: UpdateRelease) -> String {
        let new = release.date.map { "Version \(release.version) was released on \(day($0))." }
            ?? "Version \(release.version) is the newest release."
        guard let installed = installedDescription else { return new }
        return "You have \(installed). \(new)"
    }

    private func day(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Location"
        panel.message = "Choose where to keep ProSlide\u{2019}s files. ProSlide downloads into a folder named ProSlide here, or uses a ProSlide folder you pick."
        if panel.runModal() == .OK, let url = panel.url {
            updater.useLocation(url)
        }
    }
}
