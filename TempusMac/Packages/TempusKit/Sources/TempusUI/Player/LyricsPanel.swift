import AppCore
import DesignSystem
import Playback
import SubsonicAPI
import SwiftUI

/// Upstream's lyrics page: synced lyrics follow the song, with the current line highlighted and
/// centred, picking up again after the reader scrolls away; clicking a line seeks to it. Plain
/// lyrics scroll freely. Synced lyrics whose times are out of step with the audio can be nudged
/// earlier or later, remembered per song.
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

/// Opens on the line being sung and keeps it in the middle. Scrolling lets the reader look around;
/// the lyrics follow the song again when they click a line, scroll the sung line back near the
/// middle, or leave them alone for `resumeDelay`.
private struct SyncedLyrics: View {
    /// How long after the reader stops scrolling the lyrics go back to following the song.
    private static let resumeDelay = Duration.seconds(4)
    /// How long a scroll must rest before the sung line's place on screen counts, so scrolling
    /// away from it isn't taken for scrolling back.
    private static let settleDelay = Duration.milliseconds(400)
    /// Long enough for the lyrics' own animated scroll to finish moving the view.
    private static let autoScrollAllowance: TimeInterval = 0.6

    let lines: [LyricsContent.Line]
    let player: PlayerController

    @State private var isFollowing = true
    @State private var isUserScrolling = false
    @State private var visibleLines: Set<Int> = []
    /// Changes whenever the reader starts or stops scrolling, restarting the wait to follow again.
    @State private var scrollGeneration = 0
    /// Until then, the view is moving because the lyrics scrolled it themselves.
    @State private var autoScrollEnds = Date.distantPast

    private var current: Int? {
        LyricsContent.currentLineIndex(in: lines, at: player.position)
    }

    var body: some View {
        let current = current
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.medium) {
                    // Room above the first line and below the last, so either can sit in the middle.
                    halfHeightSpacer
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            // Upstream seeks a millisecond in, so the line is current at once.
                            player.seek(to: line.start + 0.001)
                            follow(index, with: proxy)
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.inter(.title3, weight: .bold))
                                .foregroundStyle(index == current ? Theme.lyrics : Theme.tertiaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tempusPlain)
                        .id(index)
                    }
                    halfHeightSpacer
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.Spacing.xLarge)
            }
            .onAppear { scroll(proxy, to: current, animated: false) }
            .onChange(of: current) { _, index in
                guard isFollowing else { return }
                scroll(proxy, to: index, animated: true)
            }
            .onScrollPhaseChange { _, phase in
                let userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                guard userScrolling != isUserScrolling else { return }
                isUserScrolling = userScrolling
                if userScrolling {
                    isFollowing = false
                }
                scrollGeneration += 1
            }
            // Catches what the phases don't, such as dragging the scroll bar: any move the lyrics
            // didn't make themselves is the reader looking around.
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { old, new in
                guard old != new, !isUserScrolling, Date.now > autoScrollEnds else { return }
                isFollowing = false
                scrollGeneration += 1
            }
            .onScrollTargetVisibilityChange(idType: Int.self) { visibleLines = Set($0) }
            .task(id: scrollGeneration) { await resumeFollowing(with: proxy) }
        }
    }

    private var halfHeightSpacer: some View {
        Color.clear.containerRelativeFrame(.vertical) { height, _ in height / 2 }
    }

    /// Once the reader has stopped scrolling: follow if they left the sung line near the middle,
    /// else after `resumeDelay`. Scrolling again cancels the wait.
    private func resumeFollowing(with proxy: ScrollViewProxy) async {
        guard !isFollowing, !isUserScrolling else { return }
        do {
            try await Task.sleep(for: Self.settleDelay)
            if let current, LyricsContent.isLine(current, nearMiddleOf: visibleLines) {
                follow(current, with: proxy)
                return
            }
            try await Task.sleep(for: Self.resumeDelay - Self.settleDelay)
        } catch {
            return // the reader scrolled again
        }
        follow(current, with: proxy)
    }

    private func follow(_ index: Int?, with proxy: ScrollViewProxy) {
        isFollowing = true
        scroll(proxy, to: index, animated: true)
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?, animated: Bool) {
        guard let index else { return }
        autoScrollEnds = Date.now.addingTimeInterval(Self.autoScrollAllowance)
        if animated {
            withAnimation(.easeInOut) { proxy.scrollTo(index, anchor: .center) }
        } else {
            proxy.scrollTo(index, anchor: .center)
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
                .foregroundStyle(Theme.secondaryText)
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
        .buttonStyle(.tempusBorderless)
        .padding(Theme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lyrics timing")
    }
}
