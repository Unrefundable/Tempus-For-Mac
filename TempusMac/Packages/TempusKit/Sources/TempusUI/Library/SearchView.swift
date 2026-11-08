import AppCore
import DesignSystem
import SubsonicAPI
import SwiftUI

/// search3 across artists, albums and songs, with recent searches while the field is empty. With
/// lyrics search on, songs whose lyrics match come from this Mac's index as each key is typed.
struct SearchView: View {
    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @State private var text = ""
    @State private var result: SearchResult?
    @State private var lyricMatches: [LyricsSearchMatch] = []
    @State private var recent: [String] = []
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        // A container, not a `Group`: a group hands its modifiers to each branch, so every switch
        // between recents, loading and results built a new search field and lost the typing focus.
        ZStack {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                recentList
            } else if result != nil || !lyricMatches.isEmpty {
                // Lyric matches show at once, before the server's results arrive.
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                SearchField(
                    text: $text,
                    isFocused: $isFocused,
                    prompt: session.lyricsSearch.isEnabled
                        ? "Artists, albums, songs and lyrics"
                        : "Artists, albums and songs"
                ) { Task { await remember(text) } }
                if session.lyricsSearch.isEnabled, let progress = session.lyricsSearch.progress {
                    LyricsIndexingNote(progress: progress)
                }
            }
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
        // The index is on this Mac and answers in milliseconds, so no pause for typing.
        .task(id: LyricsQuery(text: text, isEnabled: session.lyricsSearch.isEnabled)) {
            let matches = await session.lyricsSearch.search(text)
            // A search overtaken by more typing must not replace the newer one's results.
            guard !Task.isCancelled else { return }
            lyricMatches = matches
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
                        .buttonStyle(.tempusPlain)
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

    /// `result` is nil while the server's answer is on its way.
    @ViewBuilder private func results(_ result: SearchResult?) -> some View {
        let artists = result?.artists ?? []
        let albums = result?.albums ?? []
        let songs = result?.songs ?? []
        if result != nil, artists.isEmpty, albums.isEmpty, songs.isEmpty, lyricMatches.isEmpty {
            ContentUnavailableView.search(text: text)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    if !artists.isEmpty {
                        CoverRow(title: "Artists", items: artists) { ArtistTile(artist: $0) }
                    }
                    if !albums.isEmpty {
                        CoverRow(title: "Albums", items: albums) { AlbumTile(album: $0) }
                    }
                    if !songs.isEmpty {
                        sectionTitle("Songs")
                        TrackList(songs: songs)
                            .padding(.horizontal, Theme.Spacing.large)
                    }
                    if !lyricMatches.isEmpty {
                        sectionTitle("Lyrics")
                        TrackList(
                            songs: lyricMatches.map(\.song),
                            captions: Dictionary(
                                lyricMatches.map { ($0.song.id, $0.caption) },
                                uniquingKeysWith: { first, _ in first }
                            )
                        )
                        .padding(.horizontal, Theme.Spacing.large)
                    }
                }
                .padding(.bottom, Theme.Spacing.xLarge)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.inter(.title2, weight: .bold)).padding(.horizontal, Theme.Spacing.xLarge)
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

/// What the lyrics search depends on: a change to either searches again.
private struct LyricsQuery: Equatable {
    let text: String
    let isEnabled: Bool
}

/// The line a song's lyrics matched, the typed words in bold.
private extension LyricsSearchMatch {
    var caption: AttributedString {
        var caption = AttributedString(line)
        for range in highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: caption),
                  let upper = AttributedString.Index(range.upperBound, within: caption)
            else { continue }
            caption[lower ..< upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return caption
    }
}

/// Shown under the search field while lyrics are being fetched for lyrics search.
private struct LyricsIndexingNote: View {
    let progress: LyricsIndexProgress

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text("Getting lyrics for search: \(progress.done.formatted()) of \(progress.total.formatted()) songs")
                .font(.inter(.caption))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .accessibilityElement(children: .combine)
    }
}

/// The search page's own field: icon, text and a clear button, as one rounded bar.
private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let prompt: LocalizedStringKey
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            TempusIconImage(.search, accessibilityName: Text("Search"))
                .tempusIconSize(Self.iconSize)
                .foregroundStyle(Theme.secondaryText)
            TextField(prompt, text: $text)
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
                .buttonStyle(.tempusBorderless)
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
