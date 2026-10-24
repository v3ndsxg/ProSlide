import FileConverterCore
import SwiftUI

/// The quality choice as a row of tabs, styled like the Format control beside it.
///
/// SwiftUI's own segmented picker can't grey out a single segment, so this is
/// built by hand. A quality that none of the pasted links offer is greyed out
/// and can't be clicked, though it stays shown as chosen if it was chosen
/// earlier, so the choice is never silently changed.
struct QualityTabs: View {
    @Binding var selection: DownloadQuality
    let isOffered: (DownloadQuality) -> Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DownloadQuality.allCases) { quality in
                tab(quality)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quality")
    }

    private func tab(_ quality: DownloadQuality) -> some View {
        let offered = isOffered(quality)
        let chosen = quality == selection
        return Button {
            if offered { selection = quality }
        } label: {
            Text(quality.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(offered ? Color.primary : Color.secondary.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(offered ? 1 : 0.6))
                            .shadow(color: .black.opacity(offered ? 0.2 : 0.1), radius: 0.5, y: 0.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!offered)
        .accessibilityLabel(offered ? quality.title : "\(quality.title), not offered by these links")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The line under the quality tabs: plain, or yellow or red when the chosen
/// quality isn't offered.
struct QualityAdviceText: View {
    let advice: QualityAdvice

    var body: some View {
        Text(advice.text)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch advice.severity {
        case .neutral: .secondary
        // A darker yellow than the system one, which is hard to read on white.
        case .warning: Color(red: 0.72, green: 0.47, blue: 0.12)
        case .error: .red
        }
    }
}

/// The coloured badge beside a link, naming its site.
struct SiteBadgeView: View {
    let badge: SiteBadge

    var body: some View {
        Text(badge.label)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color(hex: badge.color), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
