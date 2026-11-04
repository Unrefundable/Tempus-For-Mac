import AppCore
import AppKit
import DesignSystem
import SubsonicAPI
import SwiftUI

/// The same rows as `TrackTable`, laid out at their full height for a page that scrolls as a whole
/// (search results, an artist's top songs). A `Table` scrolls itself, so inside another scroll view
/// it needs a guessed height that clips short lists and leaves a second scroller on long ones.
///
/// It keeps the table's behaviour: click, ⌘-click and ⇧-click select; the arrow keys move; Return
/// or a double-click plays; the context menu and a drag take the whole selection.
struct TrackList: View {
    let songs: [Song]
    var subtitleShowsAlbum = false

    @Environment(ServerSession.self) private var session
    @State private var selection = RowSelection()
    @State private var hovered: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        let current = session.player.queue.current?.song.id
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                row(song, at: index, isCurrent: song.id == current)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.return) {
            guard let first = selection.rows.min() else { return .ignored }
            play(from: first)
            return .handled
        }
        // A new search reuses row positions for different songs.
        .onChange(of: songs.map(\.id)) {
            selection = RowSelection()
            hovered = nil
        }
    }

    private func row(_ song: Song, at index: Int, isCurrent: Bool) -> some View {
        TrackRow(
            song: song,
            number: nil,
            subtitleShowsAlbum: subtitleShowsAlbum,
            isCurrent: isCurrent,
            isStarred: session.stars.isStarred(song),
            download: TrackDownloadMark.of(song, in: session.downloads)
        )
        .padding(.horizontal, Theme.Spacing.small)
        .frame(minHeight: Theme.Size.trackRow)
        .background(background(for: index))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hovered = index
            case .ended: if hovered == index { hovered = nil }
            }
        }
        .onTapGesture(count: 2) { play(from: index) }
        // Simultaneous, so selecting doesn't wait out the double-click interval.
        .simultaneousGesture(TapGesture().onEnded { click(index) })
        .contextMenu { SongMenu(songs: songs(at: selection.targets(for: index)), source: nil) }
        .draggable(SongTransfer(songs: songs(at: selection.targets(for: index))))
        .accessibilityAddTraits(selection.rows.contains(index) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { play(from: index) }
    }

    private func background(for index: Int) -> some View {
        let style: AnyShapeStyle = if selection.rows.contains(index) {
            AnyShapeStyle(Theme.accent.opacity(Self.selectedOpacity))
        } else {
            AnyShapeStyle(.primary.opacity(hovered == index ? Self.hoverOpacity : 0))
        }
        return RoundedRectangle(cornerRadius: Theme.Radius.artworkSmall).fill(style)
    }

    private func click(_ index: Int) {
        let flags = NSEvent.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        isFocused = true
        selection = selection.clicking(index, modifiers: modifiers)
    }

    private func move(by step: Int) -> KeyPress.Result {
        selection = selection.moving(by: step, count: songs.count)
        return .handled
    }

    private func play(from index: Int) {
        session.player.play(songs, startingAt: index)
    }

    private func songs(at indices: [Int]) -> [Song] {
        indices.compactMap { songs.indices.contains($0) ? songs[$0] : nil }
    }

    private static let hoverOpacity = 0.06
    private static let selectedOpacity = 0.25
}
