import AppCore
import DesignSystem
import Playback
import SwiftUI

/// The Settings window (⌘,): general (with Discord and updates), appearance, Home and the sidebar,
/// playback, the equalizer, and storage (with downloads).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Kept here, not in the Storage tab, so a clear in progress survives switching tabs.
    @State private var caches: CacheViewer?

    var body: some View {
        TabView {
            Tab { GeneralSettings() } label: { Label("General", tempus: .settings) }
            Tab { AppearanceSettings() } label: { Label("Appearance", systemImage: "paintpalette") }
            Tab { LayoutSettings() } label: { Label("Home & Sidebar", tempus: .home) }
            Tab { PlaybackSettingsPane() } label: { Label("Playback", tempus: .play) }
            Tab { EqualizerPane() } label: { Label("Equalizer", tempus: .equalizer) }
            Tab { StorageSettings(viewer: caches) } label: { Label("Storage", systemImage: "internaldrive") }
        }
        .themedBackground(.background)
        .frame(width: 560)
        .frame(minHeight: 420)
        .task {
            if caches == nil {
                caches = CacheViewer(storage: model.cacheStorage)
            }
        }
    }
}

/// Playback settings live on the player, so they need a server in use.
struct NeedsPlayer<Content: View>: View {
    @ViewBuilder let content: (PlayerController) -> Content

    @Environment(AppModel.self) private var model

    var body: some View {
        if let player = model.session?.player {
            content(player)
        } else {
            ContentUnavailableView(
                "Sign in to a server",
                systemImage: "server.rack",
                description: Text("Playback settings are available once a server is in use.")
            )
        }
    }
}

private struct PlaybackSettingsPane: View {
    var body: some View {
        NeedsPlayer { player in
            let stream = player.settings.stream
            let gain = player.settings.replayGain
            Form {
                Section("Streaming quality") {
                    Toggle("Let the server decide", isOn: Binding(
                        get: { stream.serverDecides },
                        set: { player.setStreamSettings(Self.stream(stream, serverDecides: $0)) }
                    ))
                    if !stream.serverDecides {
                        QualityPicker(
                            title: "Format",
                            format: stream.format,
                            bitrate: stream.maxBitrate
                        ) { format, bitrate in
                            player.setStreamSettings(StreamSettings(
                                format: format, maxBitrate: bitrate,
                                constrainedFormat: stream.constrainedFormat,
                                constrainedMaxBitrate: stream.constrainedMaxBitrate
                            ))
                        }
                        QualityPicker(
                            title: "On a hotspot or in Low Data Mode",
                            format: stream.constrainedFormat,
                            bitrate: stream.constrainedMaxBitrate
                        ) { format, bitrate in
                            player.setStreamSettings(StreamSettings(
                                format: stream.format, maxBitrate: stream.maxBitrate,
                                constrainedFormat: format, constrainedMaxBitrate: bitrate
                            ))
                        }
                    }
                    Text(
                        "Changes apply from the next track. Opus and Vorbis are always converted, since macOS can't stream them."
                    )
                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                }
                Section("ReplayGain") {
                    Picker("Mode", selection: Binding(
                        get: { gain.mode },
                        set: { player.setReplayGain(ReplayGainSettings(
                            mode: $0,
                            preampDB: gain.preampDB,
                            preventsClipping: gain.preventsClipping
                        )) }
                    )) {
                        Text("Off").tag(ReplayGainMode.off)
                        Text("Track").tag(ReplayGainMode.track)
                        Text("Album").tag(ReplayGainMode.album)
                        Text("Auto").tag(ReplayGainMode.auto)
                    }
                    Toggle("Prevent clipping", isOn: Binding(
                        get: { gain.preventsClipping },
                        set: { player.setReplayGain(ReplayGainSettings(
                            mode: gain.mode,
                            preampDB: gain.preampDB,
                            preventsClipping: $0
                        )) }
                    ))
                    .disabled(gain.mode == .off)
                    LabeledContent("Pre-amplification") {
                        Slider(value: Binding(
                            get: { gain.preampDB },
                            set: { player.setReplayGain(ReplayGainSettings(
                                mode: gain.mode,
                                preampDB: $0.rounded(),
                                preventsClipping: gain.preventsClipping
                            )) }
                        ), in: ReplayGainSettings.preampRange, step: 1)
                        Text(String(format: "%+.0f dB", gain.preampDB)).monospacedDigit().frame(width: 52)
                    }
                }
                Section("Speed") {
                    Picker("Pitch", selection: Binding(
                        get: { PitchChoice(player.settings.speed.pitch) },
                        set: { player.setSpeed(PlaybackSpeed(rate: player.settings.speed.rate, pitch: $0.mode)) }
                    )) {
                        Text("Keep the original pitch").tag(PitchChoice.fixed)
                        Text("Change pitch with speed").tag(PitchChoice.followsRate)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    static func stream(_ stream: StreamSettings, serverDecides: Bool) -> StreamSettings {
        StreamSettings(
            serverDecides: serverDecides, format: stream.format, maxBitrate: stream.maxBitrate,
            constrainedFormat: stream.constrainedFormat, constrainedMaxBitrate: stream.constrainedMaxBitrate
        )
    }
}

private enum PitchChoice: Hashable {
    case fixed, followsRate

    init(_ mode: PitchMode) {
        self = mode == .followsRate ? .followsRate : .fixed
    }

    var mode: PitchMode {
        self == .fixed ? .fixed : .followsRate
    }
}

private struct QualityPicker: View {
    let title: String
    let format: TranscodeFormat
    let bitrate: Int
    let onChange: (TranscodeFormat, Int) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Picker("Format", selection: Binding(get: { format }, set: { onChange($0, bitrate) })) {
                    Text("Original").tag(TranscodeFormat.original)
                    Text("MP3").tag(TranscodeFormat.mp3)
                    Text("AAC").tag(TranscodeFormat.aac)
                    Text("FLAC").tag(TranscodeFormat.flac)
                }
                .labelsHidden()
                Picker("Bitrate", selection: Binding(get: { bitrate }, set: { onChange(format, $0) })) {
                    ForEach(StreamSettings.bitrates, id: \.self) { rate in
                        Text(rate == 0 ? "No limit" : "\(rate) kbps").tag(rate)
                    }
                }
                .labelsHidden()
                .disabled(format == .original || format == .flac)
            }
        }
    }
}
