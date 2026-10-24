import AppKit
import FileConverterCore
import SwiftUI

/// The Downloader tab: paste links, choose a format and quality, press Download.
/// Finished files, and the downloads still running, appear in the bin.
struct DownloaderView: View {
    @EnvironmentObject private var downloads: DownloadQueue

    var body: some View {
        VStack(spacing: 16) {
            AppTitleView()
            Text("Paste video links to save them as MP4 or MP3 in the bin, ready to drag into ProPresenter.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let reason = downloads.availability.error {
                unavailable(reason)
            } else {
                linkBox
                options
                linkList
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

    // MARK: - Links

    private var linkBox: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $downloads.linkText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
            if downloads.linkText.isEmpty {
                Text("Paste one link per line\u{2026}")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: 620, minHeight: 96, maxHeight: 96)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35)))
        .overlay(alignment: .topTrailing) {
            Button("Paste") { paste() }
                .controlSize(.small)
                .padding(8)
        }
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
                GridRow {
                    Text("Quality")
                    HStack(spacing: 10) {
                        Picker("Quality", selection: $downloads.quality) {
                            // Qualities no pasted link offers are greyed out.
                            ForEach(DownloadQuality.allCases) { quality in
                                Text(quality.title).tag(quality)
                                    .disabled(!downloads.isOffered(quality))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Text(qualityHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var qualityHint: String {
        if !downloads.isOffered(downloads.quality) {
            return "None of these links offer \(downloads.quality.title). Each downloads at its best."
        }
        return "Up to this quality. A video without it downloads at its best."
    }

    private var linkList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !downloads.items.isEmpty {
                    HStack {
                        Text("Downloads").font(.headline)
                        Spacer()
                        Button("Clear") { downloads.clearFinished() }
                            .disabled(downloads.isDownloading)
                    }
                    ForEach(downloads.items) { itemRow($0) }
                }
                if !downloads.links.isEmpty {
                    Text("Pasted links").font(.headline)
                        .padding(.top, downloads.items.isEmpty ? 0 : 10)
                    ForEach(downloads.links) { linkRow($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 620)
        .contextMenu {
            Button("Show Download Log") { showLog() }
        }
    }

    private func linkRow(_ link: DownloadLink) -> some View {
        let lookup = downloads.lookups[link.id]
        return HStack(spacing: 10) {
            Group {
                if link.unsupportedReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    switch lookup {
                    case .found?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    case .failed?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    default: ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: link, lookup: lookup)).lineLimit(1).truncationMode(.middle)
                if let detail = detail(for: link, lookup: lookup) {
                    Text(detail).font(.caption)
                        .foregroundStyle(link.unsupportedReason != nil || isFailure(lookup) ? Color.red : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
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
        HStack(spacing: 10) {
            switch item.status {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 18)
            case .downloading: ProgressView().controlSize(.small).frame(width: 18)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                Text(item.statusLine)
                    .font(.caption)
                    .foregroundStyle(isFailed(item) ? Color.red : .secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if item.canRetry {
                Button("Retry") { downloads.retry(item.id) }
                    .disabled(downloads.isDownloading)
            }
        }
        .padding(.vertical, 3)
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
