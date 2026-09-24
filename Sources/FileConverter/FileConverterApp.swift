import SwiftUI

@main
struct FileConverterApp: App {
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
