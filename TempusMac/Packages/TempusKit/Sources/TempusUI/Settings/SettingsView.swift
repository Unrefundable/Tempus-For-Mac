import AppCore
import DesignSystem
import Playback
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,): general, Home, playback, equalizer and downloads.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab { GeneralSettings() } label: { Label("General", tempus: .settings) }
            Tab { HomeSettings() } label: { Label("Home", tempus: .home) }
            Tab { PlaybackSettingsPane() } label: { Label("Playback", tempus: .play) }
            Tab { EqualizerPane() } label: { Label("Equalizer", tempus: .equalizer) }
            Tab { DownloadSettings() } label: { Label("Downloads", tempus: .playForWork) }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Server") {
                Toggle("Scrobble what I play", isOn: $settings.scrobbles)
                Text("Tells your server what you play. It may pass it on to Last.fm or ListenBrainz if set up to.")
                    .font(.inter(.caption)).foregroundStyle(.secondary)
                Toggle("Sync the play queue with the server", isOn: $settings.syncsPlayQueue)
                Text(
                    "Saves your queue and position when you pause, change track and every 30 seconds, so another device can continue."
                )
                .font(.inter(.caption)).foregroundStyle(.secondary)
                Toggle(
                    "Remember where I stopped in podcasts, audiobooks and long tracks",
                    isOn: $settings.savesBookmarks
                )
            }
            Section("Display") {
                Toggle("Show the track number in Now Playing", isOn: $settings.showsTrackNumber)
            }
            if let session = model.session, session.features.musicFolders.count > 1 {
                Section("Music library") {
                    Picker("Browse and search", selection: Binding(
                        get: { session.musicFolderID },
                        set: { settings.setMusicFolderID($0, server: session.profile.id) }
                    )) {
                        Text("All Libraries").tag(String?.none)
                        ForEach(session.features.musicFolders) { folder in
                            Text(folder.name ?? folder.id).tag(Optional(folder.id))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HomeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let layout = model.settings.homeLayout
        Form {
            Section("Shown, in this order") {
                List {
                    ForEach(layout.visible) { section in
                        HStack {
                            TempusIconImage(.dragHandle).foregroundStyle(.tertiary)
                            Text(section.title)
                            Spacer()
                            Button("Hide") { model.settings.setHomeLayout(layout.hiding(section)) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .onMove { model.settings.setHomeLayout(layout.moving(fromOffsets: $0, toOffset: $1)) }
                }
                .frame(minHeight: 220)
            }
            if !layout.hidden.isEmpty {
                Section("Hidden") {
                    ForEach(layout.hidden) { section in
                        HStack {
                            Text(section.title).foregroundStyle(.secondary)
                            Spacer()
                            Button("Show") { model.settings.setHomeLayout(layout.showing(section)) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Button("Restore Defaults") { model.settings.setHomeLayout(.default) }
        }
        .formStyle(.grouped)
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
                    .font(.inter(.caption)).foregroundStyle(.secondary)
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

private struct DownloadSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsRemoval = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Downloading") {
                Toggle(
                    "Only on networks that aren't a hotspot or in Low Data Mode",
                    isOn: $settings.downloadsOnlyUnconstrained
                )
                .onChange(of: settings.downloadsOnlyUnconstrained) { model.networkChanged() }
                Toggle(
                    "Download in the streaming quality instead of the original file",
                    isOn: $settings.transcodesDownloads
                )
                Toggle("Keep starred tracks downloaded", isOn: $settings.syncsStarredTracks)
                Text("Starred tracks and kept-synced playlists are checked each time you sign in.")
                    .font(.inter(.caption)).foregroundStyle(.secondary)
            }
            if let session = model.session {
                Section("On this Mac for \(session.profile.name)") {
                    LabeledContent("Tracks", value: "\(session.downloads.records.count)")
                    LabeledContent(
                        "Size",
                        value: ByteCountFormatter.string(fromByteCount: session.downloads.totalBytes, countStyle: .file)
                    )
                    Button("Remove All Downloads…", role: .destructive) { confirmsRemoval = true }
                        .disabled(session.downloads.records.isEmpty)
                }
                .confirmationDialog(
                    "Remove every download for \(session.profile.name)?",
                    isPresented: $confirmsRemoval
                ) {
                    Button("Remove All", role: .destructive) { Task { await session.downloads.deleteAll() } }
                }
            }
        }
        .formStyle(.grouped)
    }
}
