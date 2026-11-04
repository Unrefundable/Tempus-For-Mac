import AppCore
import AVKit
import DesignSystem
import Playback
import SwiftUI

/// Shuffle, previous, play/pause, next and repeat, shared by the player bar and Now Playing.
struct TransportControls: View {
    /// Icon sizes standing in for the symbol fonts these controls used: body and title2 for the
    /// player bar, title2 and 34 pt in Now Playing.
    private enum IconSize {
        static let control: CGFloat = 18
        static let largeControl: CGFloat = 24
        static let playPause: CGFloat = 28
        static let largePlayPause: CGFloat = 40
    }

    let player: PlayerController
    var large = false

    var body: some View {
        HStack(spacing: large ? Theme.Spacing.xLarge : Theme.Spacing.large) {
            Button("Shuffle", tempus: .shuffle) { player.toggleShuffle() }
                .foregroundStyle(player.queue.isShuffled ? Theme.accent : Theme.secondaryText)
                .help(player.queue.isShuffled ? "Turn shuffle off" : "Turn shuffle on")
            Button("Previous", tempus: .skipPrevious) { player.previous() }
                .disabled(player.queue.isEmpty)
            Button(
                player.status.isActive ? "Pause" : "Play",
                tempus: player.status.isActive ? .pause : .play
            ) { player.togglePlayPause() }
                .tempusIconSize(large ? IconSize.largePlayPause : IconSize.playPause)
                .disabled(player.queue.isEmpty)
            Button("Next", tempus: .skipNext) { player.next() }
                .disabled(player.queue.nextItem(afterTrackEnded: false) == nil)
            Button("Repeat", tempus: player.queue.repeatMode == .one ? .repeatOne : .repeat) {
                player.cycleRepeatMode()
            }
            .foregroundStyle(player.queue.repeatMode == .off ? Theme.secondaryText : Theme.accent)
            .help("Repeat: \(player.queue.repeatMode.rawValue)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .tempusIconSize(large ? IconSize.largeControl : IconSize.control)
    }
}

/// A seek slider with elapsed and total time. While dragging it shows the drag position and
/// seeks only on release, so the engine isn't flooded with seeks.
struct SeekBar: View {
    let player: PlayerController
    var compact = false

    @State private var dragPosition: TimeInterval?
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(TrackFormatting.time(dragPosition ?? player.position))
                .frame(minWidth: 40, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { dragPosition ?? player.position },
                    set: { value in
                        // Keyboard and VoiceOver changes don't drag: seek at once.
                        if isDragging {
                            dragPosition = value
                        } else {
                            player.seek(to: value)
                        }
                    }
                ),
                in: 0 ... max(player.duration, 1)
            ) { editing in
                isDragging = editing
                if !editing, let target = dragPosition {
                    player.seek(to: target)
                    dragPosition = nil
                }
            }
            .controlSize(compact ? .mini : .small)
            .disabled(player.duration <= 0)
            Text(player.duration > 0 ? TrackFormatting.time(player.duration) : "--")
                .frame(minWidth: 40, alignment: .leading)
        }
        .font(.inter(.caption).monospacedDigit())
        .foregroundStyle(Theme.secondaryText)
    }
}

/// AirPlay and other outputs. AudioStreaming renders to the system output, so the picker routes it.
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context _: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_: AVRoutePickerView, context _: Context) {}
}
