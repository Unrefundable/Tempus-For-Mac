import AppCore
import DesignSystem
import SubsonicAPI
import SwiftUI

/// Starred tracks on a page of their own: Home's Starred Tracks row as a full, playable list.
/// Reloads after a star changes, and drops a track as soon as it's unstarred here.
struct FavoritesView: View {
    @Environment(ServerSession.self) private var session

    var body: some View {
        SnapshotView(
            request: .starred(musicFolderID: session.musicFolderID),
            reloadKey: session.stars.revision
        ) { starred in
            let songs = starred.songs.filter { session.stars.isStarred($0) }
            if songs.isEmpty {
                EmptyState(
                    art: .icon(.favoritesOutlined),
                    title: "No favorites yet",
                    message: Text("Star tracks to find them here.")
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Favorites").font(.inter(.largeTitle, weight: .bold))
                            Text(TrackFormatting.queueSummary(songs)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        PlayButtons { songs }
                    }
                    .padding(Theme.Spacing.xLarge)
                    TrackTable(songs: songs)
                }
            }
        }
    }
}
