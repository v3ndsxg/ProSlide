import AppKit
import FileConverterCore
import SwiftUI

/// The Downloader tab: paste links, choose a format and quality, press Download.
/// Finished files, and the downloads still running, appear in the bin.
struct DownloaderView: View {
    @EnvironmentObject private var downloads: DownloadQueue
    @State private var cardHeight: CGFloat = 60

    var body: some View {
        VStack(spacing: 16) {
            AppTitleView()
            Text("Paste video links to save them as MP4 or MP3 in the bin, ready to drag into ProPresenter.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let reason = downloads.availability.error {
                unavailable(reason)
            } else {
                linkCard
                options
            }

            if let message = downloads.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    // MARK: - The link card

    /// One card: where links are pasted, then a row for each pasted link and for
    /// each download, with the site's badge, its title and what it is doing.
    private var linkCard: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                entry
                if !downloads.links.isEmpty {
                    ForEach(downloads.links) { link in
                        Divider()
                        linkRow(link)
                    }
                }
                if !downloads.items.isEmpty {
                    Divider()
                    HStack {
                        Text("Downloads")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button("Clear") { downloads.clearFinished() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(downloads.isDownloading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    ForEach(downloads.items) { item in
                        Divider()
                        itemRow(item)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
        // A scroll view takes all the room it is offered. This sizes it to the
        // card, up to a limit, so the options stay right under it.
        .frame(maxWidth: 620)
        .frame(height: min(cardHeight, 340))
        .contextMenu {
            Button("Show Download Log") { showLog() }
        }
    }

    private var entry: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $downloads.linkText)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: entryHeight)
                if downloads.linkText.isEmpty {
                    Text("Paste a video link, or several, one per line\u{2026}")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            Button("Paste") { paste() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    /// One line when empty, growing with what is pasted up to a few lines.
    private var entryHeight: CGFloat {
        let lines = max(downloads.linkText.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        return min(max(CGFloat(lines) * 18 + 10, 30), 100)
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let separator = downloads.linkText.isEmpty || downloads.linkText.hasSuffix("\n") ? "" : "\n"
        downloads.linkText += separator + text
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                Text("Format")
                Picker("Format", selection: $downloads.format) {
                    ForEach(DownloadFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
            if downloads.format == .mp4 {
                GridRow(alignment: .top) {
                    Text("Quality").padding(.top, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        QualityTabs(selection: $downloads.quality, isOffered: { downloads.isOffered($0) })
                        QualityAdviceText(advice: QualityAdvice.make(selected: downloads.quality, infos: downloads.pastedInfos))
                    }
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func linkRow(_ link: DownloadLink) -> some View {
        let lookup = downloads.lookups[link.id]
        return HStack(spacing: 11) {
            SiteBadgeView(badge: SiteBadge.forHost(link.url?.host))
            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: link, lookup: lookup))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let detail = detail(for: link, lookup: lookup) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(link.unsupportedReason != nil || isFailure(lookup) ? Color.red : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Group {
                if link.unsupportedReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    switch lookup {
                    case .found?: Image(systemName: "checkmark").foregroundStyle(.green)
                    case .failed?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    default: ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(width: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func title(for link: DownloadLink, lookup: LinkLookup?) -> String {
        if case .found(let info)? = lookup { return info.title }
        return link.text
    }

    private func detail(for link: DownloadLink, lookup: LinkLookup?) -> String? {
        if let reason = link.unsupportedReason { return reason }
        switch lookup {
        case .found(let info)?:
            var parts = [Self.site(of: link)]
            if let duration = info.duration { parts.append(Self.clock(duration)) }
            if let height = info.maxHeight { parts.append("up to \(height >= 2160 ? "4K" : "\(height)p")") }
            if downloads.format == .mp4, info.convertsToH264(at: downloads.quality) {
                parts.append("will be converted to H.264")
            }
            return parts.joined(separator: " \u{00B7} ")
        case .failed(let reason)?: return reason
        default: return "\(Self.site(of: link)) \u{00B7} checking\u{2026}"
        }
    }

    private func isFailure(_ lookup: LinkLookup?) -> Bool {
        if case .failed? = lookup { return true }
        return false
    }

    private func itemRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 11) {
            SiteBadgeView(badge: SiteBadge.forHost(item.url.host))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                }
                Text(item.statusLine)
                    .font(.caption)
                    .foregroundStyle(statusColor(item))
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if item.canRetry {
                Button("Retry") { downloads.retry(item.id) }
                    .disabled(downloads.isDownloading)
            } else if case .done = item.status {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func statusColor(_ item: DownloadItem) -> Color {
        switch item.status {
        case .failed: .red
        case .downloading: .blue
        default: .secondary
        }
    }

    private func isFailed(_ item: DownloadItem) -> Bool {
        if case .failed = item.status { return true }
        return false
    }

    private func showLog() {
        DownloadLog.shared.ensureExists()
        BinOpener.reveal(DownloadLog.shared.fileURL)
    }

    // MARK: - Unavailable

    private func unavailable(_ reason: DownloadError) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34))
            Text(reason.localizedDescription)
            Text(reason == .unsupportedHardware
                 ? "The Converter works as usual. Downloads need an Apple Silicon Mac."
                 : "Rebuild the app with Scripts/make-app-bundle.sh to include them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620, minHeight: 150)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Only download videos you own or have permission to use.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if downloads.isDownloading {
                Button("Stop", role: .destructive) { downloads.cancel() }
            }
            Button(downloadTitle) { downloads.download() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(downloads.downloadableLinks.isEmpty || downloads.isDownloading || downloads.availability.error != nil)
        }
    }

    private var downloadTitle: String {
        if downloads.isDownloading { return "Downloading\u{2026}" }
        let count = downloads.downloadableLinks.count
        return count > 1 ? "Download \(count) links" : "Download"
    }

    /// "youtube.com" from a link, for the line under a title.
    private static func site(of link: DownloadLink) -> String {
        let host = link.url?.host ?? link.text
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The height of the link card's content, so its scroll view can match it.
private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 60
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
