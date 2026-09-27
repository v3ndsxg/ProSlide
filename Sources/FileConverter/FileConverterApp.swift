import AppKit
import SwiftUI

/// `swift run` and Xcode launch this target as a bare executable, not an app
/// bundle, so AppKit gives it a prohibited activation policy and the window
/// never reaches the screen. Claiming a regular policy and activating fixes
/// that for the unbundled case and is a no-op once it runs from a real bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct FileConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var job = ConversionJob()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(job)
                .frame(minWidth: 1180, minHeight: 640)
        }
        .windowStyle(.titleBar)
    }
}
