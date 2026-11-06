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
                .tempusIconKeepsForeground(!player.queue.isShuffled)
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
            .tempusIconKeepsForeground(player.queue.repeatMode == .off)
            .help("Repeat: \(player.queue.repeatMode.rawValue)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.tempusBorderless)
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

/// The player's volume: a speaker that mutes and unmutes, and a slider. The speaker's waves fill
/// with the level, as in Music.
struct VolumeControl: View {
    private static let sliderWidth: CGFloat = 80
    /// Wide enough for the fullest speaker, so the slider doesn't shift as the waves change.
    private static let speakerWidth: CGFloat = 22

    let player: PlayerController

    var body: some View {
        let volume = player.settings.volume
        HStack(spacing: Theme.Spacing.xSmall) {
            Button { player.toggleMute() } label: {
                Label {
                    Text(volume > 0 ? "Mute" : "Unmute")
                } icon: {
                    Image(systemName: volume > 0 ? "speaker.wave.3.fill" : "speaker.slash.fill", variableValue: volume)
                        .tempusIconTinted()
                        .frame(width: Self.speakerWidth)
                }
            }
            .help(volume > 0 ? "Mute" : "Unmute")
            Slider(
                value: Binding(get: { player.settings.volume }, set: { player.setVolume($0) }),
                in: 0 ... 1
            )
            .controlSize(.mini)
            .frame(width: Self.sliderWidth)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            .help("Volume")
        }
    }
}

/// AirPlay and other outputs. AudioStreaming renders to the system output, so the picker routes it.
/// Its button is AppKit's, so the theme's icon color is passed to it by hand.
struct RoutePicker: NSViewRepresentable {
    @Environment(\.tempusIconColor) private var iconColor

    func makeNSView(context _: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context _: Context) {
        // Nil puts back the system's color.
        let color = iconColor.map { NSColor($0) }
        picker.setRoutePickerButtonColor(color, for: .normal)
        picker.setRoutePickerButtonColor(color, for: .normalHighlighted)
    }
}
