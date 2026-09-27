import AppKit
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
    @StateObject private var job = ConversionJob()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(job)
                .frame(minWidth: 1180, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 720)
    }
}
