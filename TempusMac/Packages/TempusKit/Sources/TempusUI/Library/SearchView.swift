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
        // A container, not a `Group`: a group hands its modifiers to each branch, so every switch
        // between recents, loading and results built a new search field and lost the typing focus.
        ZStack {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // In the page rather than the toolbar, where it floated apart from everything else at
        // the window's far corner.
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchField(text: $text, isFocused: $isFocused) { Task { await remember(text) } }
                .padding(.horizontal, Theme.Spacing.xLarge)
                .padding(.vertical, Theme.Spacing.medium)
                // Opaque, so results scrolling under the bar don't show through the query.
                .themedBackground(.background)
                .background(.background)
        }
        .task(id: text) {
            // Waits for typing to pause, as upstream's search bar.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(text)
        }
        .task(id: navigator.searchFocusRequest) {
            // ⌘F from another page switches here and asks for focus in the same update; wait a
            // turn so the field exists before focusing it.
            await Task.yield()
            isFocused = true
        }
        .task { recent = await (try? session.recentSearches.recent()) ?? [] }
    }

    private var recentList: some View {
        List {
            Section("Recent Searches") {
                if recent.isEmpty {
                    Text("Nothing yet").foregroundStyle(Theme.secondaryText)
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
                        TrackList(songs: result.songs)
                            .padding(.horizontal, Theme.Spacing.large)
                    }
                }
                .padding(.bottom, Theme.Spacing.xLarge)
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

/// The search page's own field: icon, text and a clear button, as one rounded bar.
private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            TempusIconImage(.search, accessibilityName: Text("Search"))
                .tempusIconSize(Self.iconSize)
                .foregroundStyle(Theme.secondaryText)
            TextField("Artists, albums and songs", text: $text)
                .textFieldStyle(.plain)
                .font(.inter(.title3))
                .focused(isFocused)
                .onSubmit(onSubmit)
                // Escape clears the text, then a second Escape leaves the field.
                .onExitCommand {
                    if text.isEmpty {
                        isFocused.wrappedValue = false
                    } else {
                        text = ""
                    }
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    private static let iconSize: CGFloat = 18
}
