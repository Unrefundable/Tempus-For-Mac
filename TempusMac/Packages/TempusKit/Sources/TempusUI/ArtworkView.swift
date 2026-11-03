import AppCore
import DesignSystem
import NukeUI
import SwiftUI

extension EnvironmentValues {
    /// The signed-in server's cover pipeline; nil before sign-in and in some previews.
    @Entry var artwork: ArtworkPipeline?
}

/// A cover from the server, or upstream's placeholder for that kind of item while there is none.
struct ArtworkView: View {
    let coverArtID: String?
    let size: ArtworkSize
    var cornerRadius: CGFloat = Theme.Radius.artwork
    var placeholder: TempusPlaceholder = .album

    @Environment(\.artwork) private var artwork

    var body: some View {
        Group {
            if let artwork, let request = artwork.request(coverArtID: coverArtID, size: size) {
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderImage
                    }
                }
                .pipeline(artwork.pipeline)
            } else {
                placeholderImage
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private var placeholderImage: some View {
        Image(tempus: placeholder).resizable()
    }
}

#Preview {
    ArtworkView(coverArtID: nil, size: .thumbnail)
        .frame(width: 120)
        .padding()
}
