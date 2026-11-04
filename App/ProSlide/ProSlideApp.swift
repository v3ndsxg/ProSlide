import AppKit
import FileConverterCore
import SwiftUI

/// ProSlide ships as a real .app bundle, so AppKit already gives it a regular
/// activation policy. Claiming it explicitly and bringing the app forward is
/// cheap insurance for the cases where the window still fails to surface:
/// a debugger attach to the raw binary, or another app holding focus at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct ProSlideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var queue = ConversionQueue()
    @StateObject private var downloads = DownloadQueue()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(queue)
                .environmentObject(downloads)
                // A finished download is a new file for the bin to show.
                .task { downloads.onBinChanged = { [queue] in queue.reloadBin() } }
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 720)
    }
}
