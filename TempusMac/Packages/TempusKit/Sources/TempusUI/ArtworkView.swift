import AppCore
import NukeUI
import SwiftUI

extension EnvironmentValues {
    /// The signed-in server's cover pipeline; nil before sign-in and in some previews.
    @Entry var artwork: ArtworkPipeline?
}

/// A cover from the server, or a placeholder note while there is none.
struct ArtworkView: View {
    let coverArtID: String?
    let size: ArtworkSize
    var cornerRadius: CGFloat = Theme.Radius.artwork

    @Environment(\.artwork) private var artwork

    var body: some View {
        Group {
            if let artwork, let request = artwork.request(coverArtID: coverArtID, size: size) {
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .pipeline(artwork.pipeline)
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
    }
}

#Preview {
    ArtworkView(coverArtID: nil, size: .thumbnail)
        .frame(width: 120)
        .padding()
}
