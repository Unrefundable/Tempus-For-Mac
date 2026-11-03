import DesignSystem
import SwiftUI

/// Upstream's empty layout (`fragment_download.xml`): an illustration, a LabelMedium title and a
/// LabelSmall line under it. Where upstream has no illustration for the screen, a large icon
/// stands in.
struct EmptyState<Actions: View>: View {
    enum Art {
        case illustration(TempusIllustration)
        case icon(TempusIcon)
    }

    private static var illustrationWidth: CGFloat {
        240
    }

    private static var iconSize: CGFloat {
        44
    }

    let art: Art
    let title: LocalizedStringKey
    var message: Text?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: Theme.Spacing.medium) {
                artwork
                Text(title).tempusTextStyle(.labelMedium)
            }
        } description: {
            message.map { $0.tempusTextStyle(.labelSmall) }
        } actions: {
            actions()
        }
    }

    @ViewBuilder private var artwork: some View {
        switch art {
        case let .illustration(illustration):
            Image(tempus: illustration)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Self.illustrationWidth)
        case let .icon(icon):
            TempusIconImage(icon)
                .tempusIconSize(Self.iconSize)
                .foregroundStyle(.secondary)
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(art: Art, title: LocalizedStringKey, message: Text? = nil) {
        self.init(art: art, title: title, message: message) { EmptyView() }
    }
}

#Preview {
    EmptyState(
        art: .illustration(.emptyList),
        title: "No downloads",
        message: Text("Download tracks, albums or playlists to play them offline.")
    )
    .frame(width: 600, height: 500)
}
