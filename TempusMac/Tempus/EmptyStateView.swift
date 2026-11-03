import DesignSystem
import SwiftUI

struct EmptyState {
    let illustration: TempusIllustration
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
}

/// Upstream's empty layout (`fragment_download.xml`): an illustration, a LabelMedium title and a
/// LabelSmall subtitle, centered.
struct EmptyStateView: View {
    private static let illustrationWidth: CGFloat = 280
    private static let subtitleWidth: CGFloat = 320

    let state: EmptyState

    var body: some View {
        VStack(spacing: 0) {
            Image(tempus: state.illustration)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Self.illustrationWidth)
            Text(state.title)
                .tempusTextStyle(.labelMedium)
                .padding(.top, 12)
            Text(state.subtitle)
                .tempusTextStyle(.labelSmall)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.subtitleWidth)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView(state: SidebarDestination.downloads.emptyState)
        .frame(width: 600, height: 500)
}
