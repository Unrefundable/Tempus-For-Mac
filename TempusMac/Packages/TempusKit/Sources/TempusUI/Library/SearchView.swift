import AppCore
import DesignSystem
import SubsonicAPI
import SwiftUI

/// search3 across artists, albums and songs, with recent searches while the field is empty.
struct SearchView: View {
    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @State private var text = ""
    @State private var result: SearchResult?
    @State private var recent: [String] = []
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                recentList
            } else if let result {
                results(result)
            } else if let errorMessage {
                EmptyState(art: .illustration(.emptyResponse), title: "Search failed", message: Text(errorMessage))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $text, placement: .toolbar, prompt: "Artists, albums and songs")
        .searchFocused($isFocused)
        .onSubmit(of: .search) { Task { await remember(text) } }
        .task(id: text) {
            // Waits for typing to pause, as upstream's search bar.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(text)
        }
        .task(id: navigator.searchFocusRequest) { isFocused = true }
        .task { recent = await (try? session.recentSearches.recent()) ?? [] }
    }

    private var recentList: some View {
        List {
            Section("Recent Searches") {
                if recent.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(recent, id: \.self) { query in
                    Button(query) { text = query }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove") {
                                Task {
                                    try? await session.recentSearches.remove(query)
                                    recent = await (try? session.recentSearches.recent()) ?? []
                                }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder private func results(_ result: SearchResult) -> some View {
        if result.artists.isEmpty, result.albums.isEmpty, result.songs.isEmpty {
            ContentUnavailableView.search(text: text)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    if !result.artists.isEmpty {
                        CoverRow(title: "Artists", items: result.artists) { ArtistTile(artist: $0) }
                    }
                    if !result.albums.isEmpty {
                        CoverRow(title: "Albums", items: result.albums) { AlbumTile(album: $0) }
                    }
                    if !result.songs.isEmpty {
                        Text("Songs").font(.inter(.title2, weight: .bold)).padding(.horizontal, Theme.Spacing.xLarge)
                        TrackTable(songs: result.songs)
                            .frame(height: CGFloat(result.songs.count) * Theme.Size.tableRow + Theme.Size.tableHeader)
                            .padding(.horizontal, Theme.Spacing.large)
                    }
                }
                .padding(.vertical, Theme.Spacing.xLarge)
            }
        }
    }

    private func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            result = nil
            return
        }
        do throws(SubsonicError) {
            result = try await session.client.send(.search(
                query, artistCount: 20, albumCount: 40, songCount: 100, musicFolderID: session.musicFolderID
            ))
            errorMessage = nil
        } catch {
            guard error != .cancelled else { return }
            result = nil
            errorMessage = error.userMessage
        }
    }

    private func remember(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        try? await session.recentSearches.record(query, at: .now)
        recent = await (try? session.recentSearches.recent()) ?? []
    }
}
