import AppCore
import DesignSystem
import Playback
import SubsonicAPI
import SwiftUI

/// Upstream's lyrics page: synced lyrics follow the song, with the current line highlighted and
/// centred; clicking a line seeks to it. Plain lyrics scroll freely.
struct LyricsPanel: View {
    let player: PlayerController
    let service: LyricsService

    @State private var state = LoadState.loading

    private enum LoadState: Equatable {
        case loading
        case loaded(LyricsContent)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().frame(maxHeight: .infinity)
            case let .failed(message):
                EmptyState(art: .illustration(.emptyDescription), title: "Lyrics unavailable", message: Text(message))
            case .loaded(.none):
                EmptyState(art: .illustration(.emptyDescription), title: "No lyrics available")
            case let .loaded(.plain(text)):
                ScrollView {
                    Text(text)
                        .font(.inter(.title3, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.xLarge)
                        .frame(maxWidth: .infinity)
                }
            case let .loaded(.synced(lines)):
                SyncedLyrics(lines: lines, player: player)
            }
        }
        .task(id: player.queue.current?.song.id) { await load() }
    }

    private func load() async {
        guard let song = player.queue.current?.song else {
            state = .loaded(.none)
            return
        }
        state = .loading
        do {
            let content = try await service.lyrics(for: song)
            guard !Task.isCancelled else { return }
            state = .loaded(content)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.userMessage)
        }
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricsContent.Line]
    let player: PlayerController

    var body: some View {
        let current = LyricsContent.currentLineIndex(in: lines, at: player.position)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.medium) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            // Upstream seeks a millisecond in, so the line is current at once.
                            player.seek(to: line.start + 0.001)
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.inter(.title3, weight: .bold))
                                .foregroundStyle(index == current ? .primary : .tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(Theme.Spacing.xLarge)
            }
            .onChange(of: current) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }
}
