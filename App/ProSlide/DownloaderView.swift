import SwiftUI

/// The Downloader tab. For now only a placeholder: the tab bar and the bin's
/// support for downloads land first, the download screen after them.
struct DownloaderView: View {
    var body: some View {
        VStack(spacing: 18) {
            AppTitleView()
            Text("Save videos and audio from links as MP4 or MP3, straight into the bin.")
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").font(.system(size: 34))
                Text("Downloads are coming in a later beta build.")
                Text("Anything saved to the Downloads folder already shows up in the bin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620, minHeight: 150)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
