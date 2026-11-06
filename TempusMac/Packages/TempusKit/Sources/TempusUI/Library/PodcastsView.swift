import AppCore
import DesignSystem
import SubsonicAPI
import SwiftUI

// MARK: Podcasts

struct PodcastsView: View {
    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @State private var revision = 0
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        SnapshotView(request: .podcasts(includeEpisodes: false), reloadKey: revision) { channels in
            if channels.isEmpty {
                EmptyState(art: .illustration(.emptyPodcast), title: "No podcasts") {
                    Button("Add Podcast…") { isAdding = true }
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Theme.Size.tile), spacing: Theme.Spacing.large)],
                        spacing: Theme.Spacing.xLarge
                    ) {
                        ForEach(channels) { channel in
                            Button { navigator.open(.podcast(id: channel.id)) } label: {
                                CoverTile(
                                    coverArtID: channel.coverArtID,
                                    title: channel.title ?? "Podcast",
                                    subtitle: channel.status == "error" ? "Couldn't update" : channel.description,
                                    placeholder: .podcast
                                )
                            }
                            .buttonStyle(.tempusPlain)
                            .contextMenu {
                                Button("Delete Podcast", role: .destructive) {
                                    Task { await perform(.deletePodcastChannel(id: channel.id)) }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.xLarge)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error).padding(Theme.Spacing.small)
            }
        }
        .toolbar {
            Button("Add Podcast", tempus: .add) { isAdding = true }
            Button("Check for New Episodes", tempus: .refresh) {
                Task { await perform(.refreshPodcasts) }
            }
        }
        .sheet(isPresented: $isAdding) { AddPodcastSheet { revision += 1 } }
    }

    private func perform(_ request: SubsonicRequest<EmptyResponse>) async {
        do throws(SubsonicError) {
            _ = try await session.client.send(request)
            errorMessage = nil
            revision += 1
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct AddPodcastSheet: View {
    let onAdded: () -> Void

    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Add a Podcast").font(.inter(.headline))
            Text("Paste the podcast's RSS feed address. Your server downloads its episodes.")
                .font(.inter(.callout)).foregroundStyle(Theme.secondaryText)
            TextField("https://example.com/feed.xml", text: $address).textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 420)
    }

    @State private var isAdding = false

    private func add() {
        guard !isAdding else { return }
        guard let url = RadioStationForm.webURL(address) else {
            errorMessage = "Enter a feed address that starts with http:// or https://."
            return
        }
        isAdding = true
        Task {
            defer { isAdding = false }
            do throws(SubsonicError) {
                _ = try await session.client.send(.createPodcastChannel(url: url))
                onAdded()
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

struct PodcastChannelView: View {
    let channelID: String

    @Environment(ServerSession.self) private var session
    @State private var revision = 0
    @State private var errorMessage: String?

    var body: some View {
        SnapshotView(request: .podcasts(includeEpisodes: true, id: channelID), reloadKey: revision) { channels in
            if let channel = channels.first {
                let episodes = channel.episodes
                    .sorted { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) }
                let playable = episodes.compactMap { $0.song(channelTitle: channel.title) }
                VStack(spacing: 0) {
                    DetailHeader(
                        coverArtID: channel.coverArtID,
                        kind: "Podcast",
                        title: channel.title ?? "Podcast",
                        subtitle: nil,
                        detail: "\(episodes.count) episodes"
                    ) {
                        PlayButtons { playable }
                    }
                    if let description = channel.description, !description.isEmpty {
                        Text(ArtistDetailView.plainText(description))
                            .font(.inter(.callout)).foregroundStyle(Theme.secondaryText).lineLimit(3)
                            .padding(.horizontal, Theme.Spacing.xLarge)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error)
                    }
                    List(episodes) { episode in
                        EpisodeRow(episode: episode, channelTitle: channel.title) { request in
                            Task { await perform(request) }
                        } play: { song in
                            session.player.play(playable, startingAt: playable.firstIndex(of: song) ?? 0)
                        }
                    }
                }
            } else {
                EmptyState(art: .icon(.error), title: "Podcast not found")
            }
        }
        .navigationTitle("Podcast")
    }

    private func perform(_ request: SubsonicRequest<EmptyResponse>) async {
        do throws(SubsonicError) {
            _ = try await session.client.send(request)
            errorMessage = nil
            revision += 1
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct EpisodeRow: View {
    let episode: PodcastEpisode
    let channelTitle: String?
    let perform: (SubsonicRequest<EmptyResponse>) -> Void
    let play: (Song) -> Void

    var body: some View {
        let song = episode.song(channelTitle: channelTitle)
        HStack(spacing: Theme.Spacing.medium) {
            Button("Play", tempus: .play) { song.map(play) }
                .labelStyle(.iconOnly)
                .buttonStyle(.tempusBorderless)
                .tempusIconSize(Theme.Size.titleIcon)
                .disabled(song == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title ?? "Episode").font(.inter(.callout, weight: .medium))
                Text([
                    episode.publishDate?.formatted(date: .abbreviated, time: .omitted),
                    episode.duration.map { TrackFormatting.time(TimeInterval($0)) },
                    Self.status(episode.status),
                ].compactMap(\.self).joined(separator: " • "))
                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if song == nil, episode.status != "downloading" {
                Button("Download to Server") { perform(.downloadPodcastEpisode(id: episode.id)) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .contextMenu {
            if let song {
                SongMenu(songs: [song])
                Divider()
            }
            Button("Delete Episode", role: .destructive) { perform(.deletePodcastEpisode(id: episode.id)) }
        }
    }

    static func status(_ status: String?) -> String? {
        switch status {
        case "downloading": "Downloading on server"
        case "new", "skipped": "Not downloaded"
        case "error": "Download failed"
        case "deleted": "Deleted"
        default: nil
        }
    }
}
