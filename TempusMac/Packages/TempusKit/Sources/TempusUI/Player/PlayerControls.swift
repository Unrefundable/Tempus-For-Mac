import AppCore
import AVKit
import Playback
import SwiftUI

/// Shuffle, previous, play/pause, next and repeat, shared by the player bar and Now Playing.
struct TransportControls: View {
    let player: PlayerController
    var large = false

    var body: some View {
        HStack(spacing: large ? Theme.Spacing.xLarge : Theme.Spacing.large) {
            Button("Shuffle", systemImage: "shuffle") { player.toggleShuffle() }
                .foregroundStyle(player.queue.isShuffled ? Theme.accent : .secondary)
                .help(player.queue.isShuffled ? "Turn shuffle off" : "Turn shuffle on")
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .disabled(player.queue.isEmpty)
            Button(
                player.status.isActive ? "Pause" : "Play",
                systemImage: player.status.isActive ? "pause.fill" : "play.fill"
            ) { player.togglePlayPause() }
                .font(large ? .system(size: 34) : .title2)
                .disabled(player.queue.isEmpty)
            Button("Next", systemImage: "forward.fill") { player.next() }
                .disabled(player.queue.nextItem(afterTrackEnded: false) == nil)
            Button("Repeat", systemImage: player.queue.repeatMode == .one ? "repeat.1" : "repeat") {
                player.cycleRepeatMode()
            }
            .foregroundStyle(player.queue.repeatMode == .off ? .secondary : Theme.accent)
            .help("Repeat: \(player.queue.repeatMode.rawValue)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(large ? .title2 : .body)
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
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
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
