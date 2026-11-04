import FileConverterCore
import SwiftUI

/// The app's name, with an orange BETA badge in the beta build. Shared by every
/// tab so the heading stays put when the tab changes.
struct AppTitleView: View {
    var body: some View {
        HStack(spacing: 10) {
            Text(AppIdentity.current.displayName).font(.largeTitle.weight(.semibold))
            if AppIdentity.current.isBeta {
                Text("BETA")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
                    .foregroundStyle(.black)
            }
        }
    }
}
