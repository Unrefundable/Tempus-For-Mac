import AppCore
import DesignSystem
import Playback
import SubsonicAPI
import SwiftUI

/// Upstream's lyrics page: synced lyrics follow the song, with the current line highlighted and
/// centred; clicking a line seeks to it. Plain lyrics scroll freely. Synced lyrics whose times are
/// out of step with the audio can be nudged earlier or later, remembered per song.
struct LyricsPanel: View {
    let player: PlayerController
    let service: LyricsService
    let settings: AppSettings
    let serverID: String

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
                if let songID = player.queue.current?.song.id {
                    let nudge = settings.lyricsNudge(song: songID, server: serverID)
                    VStack(spacing: 0) {
                        SyncedLyrics(lines: lines.map { $0.shifted(sooner: nudge) }, player: player)
                        Divider()
                        LyricsNudgeBar(nudge: nudge) { settings.setLyricsNudge($0, song: songID, server: serverID) }
                    }
                }
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

/// Moves the lines half a second at a time, for lyrics made for another version of the song (a
/// longer intro, say). Upstream has no equivalent; it shows such lyrics out of step.
private struct LyricsNudgeBar: View {
    let nudge: TimeInterval
    let onChange: (TimeInterval) -> Void

    var body: some View {
        // Laid out like a timeline: minus moves the lines toward the start, plus toward the end.
        HStack(spacing: Theme.Spacing.small) {
            Button("Show Lyrics Earlier", tempus: .minus) { onChange(nudge + AppSettings.lyricsNudgeStep) }
                .help("Show lyrics earlier")
                .disabled(nudge >= AppSettings.lyricsNudgeLimit)
            Text(TrackFormatting.lyricsNudge(nudge))
                .font(.inter(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 90)
            Button("Show Lyrics Later", tempus: .add) { onChange(nudge - AppSettings.lyricsNudgeStep) }
                .help("Show lyrics later")
                .disabled(nudge <= -AppSettings.lyricsNudgeLimit)
            Button("Reset Lyrics Timing", tempus: .replay) { onChange(0) }
                .help("Use the lyrics' own timing")
                .disabled(nudge == 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(Theme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lyrics timing")
    }
}
