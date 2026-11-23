import AppKit
import FileConverterCore
import SwiftUI

/// ProSlide ships as a real .app bundle, so AppKit already gives it a regular
/// activation policy. Claiming it explicitly and bringing the app forward is
/// cheap insurance for the cases where the window still fails to surface:
/// a debugger attach to the raw binary, or another app holding focus at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// An update that is built but waiting for a conversion or download to
    /// finish still installs if the operator quits ProSlide first.
    func applicationWillTerminate(_ notification: Notification) {
        AppUpdater.shared.launchInstaller(relaunch: false)
    }
}

@main
struct ProSlideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var queue = ConversionQueue()
    @StateObject private var downloads = DownloadQueue()
    @StateObject private var lyrics = LyricsDraft()
    @StateObject private var updater = AppUpdater.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(UpdateSupport())
                .environmentObject(updater)
                .environmentObject(queue)
                .environmentObject(downloads)
                .environmentObject(lyrics)
                // A finished download is a new file for the bin to show.
                .task { downloads.onBinChanged = { [queue] in queue.reloadBin() } }
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") { updater.showOrCheck() }
            }
        }
    }
}
