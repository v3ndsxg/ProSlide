import SwiftUI

@main
struct FileConverterApp: App {
    @StateObject private var job = ConversionJob()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(job)
                .frame(minWidth: 760, minHeight: 590)
        }
        .windowStyle(.titleBar)
    }
}
