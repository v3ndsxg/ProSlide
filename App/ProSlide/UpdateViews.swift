import AppKit
import FileConverterCore
import SwiftUI

extension AppUpdater {
    /// The app's one updater, shared by the window, the menu and the app delegate.
    @MainActor static let shared = AppUpdater()
}

/// Adds the Update button to the title bar, the update window, the daily check,
/// and the "restart once the work is done" wait.
struct UpdateSupport: ViewModifier {
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var queue: ConversionQueue
    @EnvironmentObject private var downloads: DownloadQueue

    /// What a restart would interrupt, or nil when nothing is running.
    private var busyReason: String? {
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
            .onChange(of: busyReason == nil) { idle in
                if idle && updater.restartWhenIdle { restartNow() }
            }
            .task { updater.startAutomaticChecks() }
    }

    private func restartNow() {
        if updater.launchInstaller(relaunch: true) {
            NSApp.terminate(nil)
        }
    }
}

/// The title-bar button. A plain icon until there's something to do.
struct UpdateButton: View {
    @EnvironmentObject private var updater: AppUpdater

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
        case .updating:
            Button { updater.showOrCheck() } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating\u{2026}")
                }
            }
            .help("ProSlide is updating. You can keep working.")
        case .ready:
            Button { updater.showOrCheck() } label: {
                Label("Restart to Update", systemImage: "arrow.clockwise.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .help("The new version is ready. Restart ProSlide to use it.")
        case .unknown, .checking, .upToDate, .problem:
            Button { updater.showOrCheck() } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("Check for Updates")
        }
    }
}

/// The update window: what's new, progress, the restart prompt, or what went wrong.
struct UpdateWindow: View {
    @ObservedObject var updater: AppUpdater
    let busyReason: String?
    let restartNow: () -> Void
    @State private var confirmingRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .confirmationDialog(
            "\(busyReason ?? "ProSlide is busy.") Restart anyway?",
            isPresented: $confirmingRestart,
            titleVisibility: .visible
        ) {
            Button("Wait") {
                updater.restartWhenIdle = true
                updater.dismiss()
            }
            Button("Restart Anyway", role: .destructive) { restartNow() }
        } message: {
            Text("Wait restarts ProSlide on its own as soon as it finishes.")
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

        case .upToDate(let installed):
            Text("ProSlide is up to date").font(.title2.weight(.semibold))
            if let installed {
                Text("You have the version from \(day(installed)).").foregroundStyle(.secondary)
            }
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .available(let offer):
            Text("A new version of ProSlide is available").font(.title2.weight(.semibold))
            Text(versions(offer)).foregroundStyle(.secondary)
            if offer.isOffMain {
                Label(
                    "This ProSlide folder follows the \u{201C}\(offer.branch)\u{201D} branch, not main, so the update comes from that branch.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
            changeList(offer.changes)
            Text("You can keep using ProSlide while it updates.").font(.callout).foregroundStyle(.secondary)
            buttons {
                Button("Cancel") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update") { updater.update() }.keyboardShortcut(.defaultAction)
            }

        case .updating(let step):
            Text("Updating ProSlide").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(step.description)
            }
            Text("You can close this window and keep working. ProSlide will tell you when it\u{2019}s done.")
                .font(.callout).foregroundStyle(.secondary)
            buttons { Button("Close") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

        case .ready:
            Text("ProSlide has been updated").font(.title2.weight(.semibold))
            if updater.restartWhenIdle {
                Text("ProSlide will restart as soon as it finishes what it\u{2019}s doing.").foregroundStyle(.secondary)
            } else {
                Text("Restart ProSlide to start using the new version. If you choose Later, it installs the next time you quit ProSlide.")
                    .foregroundStyle(.secondary)
            }
            buttons {
                Button("Later") { updater.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restart Now") {
                    if busyReason == nil { restartNow() } else { confirmingRestart = true }
                }
                .keyboardShortcut(.defaultAction)
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
            Text("Someone changed files in \(folder.path) that aren\u{2019}t on GitHub. ProSlide won\u{2019}t update over them. Remove the changes, or publish them to GitHub, and try again.")
                .foregroundStyle(.secondary)
            buttons {
                Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction)
            }

        case .notOnBranch(let folder):
            heading("ProSlide can\u{2019}t update from this folder")
            Text("\(folder.path) isn\u{2019}t following a branch, so there\u{2019}s nothing to update from. Switch it back to main and try again.")
                .foregroundStyle(.secondary)
            buttons { Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction) }

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

    private func changeList(_ changes: [UpdateChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What\u{2019}s new").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changes) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\u{2022}")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.title)
                                Text(day(change.date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func versions(_ offer: UpdateOffer) -> String {
        let new = "The new version is from \(day(offer.newDate))."
        guard let installed = offer.installedDate else { return new }
        return "You have the version from \(day(installed)). \(new)"
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
