import AppCore
import DesignSystem
import SwiftUI

/// Settings' General tab: the server, display, the library in use, Discord and, last, updates.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Server") {
                Toggle("Scrobble what I play", isOn: $settings.scrobbles)
                Text("Tells your server what you play. It may pass it on to Last.fm or ListenBrainz if set up to.")
                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                Toggle("Sync the play queue with the server", isOn: $settings.syncsPlayQueue)
                Text(
                    "Saves your queue and position when you pause, change track and every 30 seconds, so another device can continue."
                )
                .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
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
            DiscordSection(settings: settings, presence: model.discord)
            UpdateSections()
        }
        .formStyle(.grouped)
    }
}

/// Showing the track playing in the user's Discord status.
private struct DiscordSection: View {
    @Bindable var settings: AppSettings
    let presence: DiscordPresence?

    var body: some View {
        Section {
            Toggle("Show what I'm listening to on Discord", isOn: $settings.sharesNowPlayingOnDiscord)
            Text(
                "While music plays, your Discord status shows the track and artist to everyone who can see your profile. The Discord app needs to be open on this Mac."
            )
            .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            if settings.sharesNowPlayingOnDiscord {
                if let presence {
                    LabeledContent("Status") {
                        HStack(spacing: Theme.Spacing.small) {
                            Text(Self.description(of: presence.status))
                                .foregroundStyle(Self.isProblem(presence.status) ? Theme.error : Theme.secondaryText)
                            if Self.isProblem(presence.status) {
                                Button("Try Again") { presence.refresh() }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Discord")
        }
    }

    private static func description(of status: DiscordPresence.Status) -> String {
        switch status {
        case .off: "Off"
        case .waiting: "Ready. Shows while music plays."
        case .connecting: "Connecting to Discord…"
        case .connected: "Showing in Discord"
        case let .unavailable(message): message
        }
    }

    private static func isProblem(_ status: DiscordPresence.Status) -> Bool {
        if case .unavailable = status {
            return true
        }
        return false
    }
}

/// Automatic and beta updates, and checking now. Development builds don't update.
private struct UpdateSections: View {
    @Environment(AppUpdater.self) private var updater: AppUpdater?

    var body: some View {
        if let updater {
            @Bindable var updater = updater
            Section {
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyUpdates)
                Text("Checks once a day. New versions install in the background when you quit Tempus.")
                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                Toggle("Get beta updates", isOn: $updater.receivesBetaUpdates)
                Text("Betas are pre-releases of the next version. They come sooner, with rougher edges.")
                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            } header: {
                Text("Updates")
            }
            .disabled(!updater.isEnabled)
            Section {
                LabeledContent("Version", value: AppUpdater.currentVersion)
                Button("Check for Updates Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                if !updater.isEnabled {
                    Text("Development builds don't update themselves.")
                        .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}
