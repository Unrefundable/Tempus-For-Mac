import AppCore
import DesignSystem
import SwiftUI

/// Settings' Storage tab: the space each cache takes and clearing them, then how tracks download
/// and the space downloads take.
struct StorageSettings: View {
    /// Nil until the Settings window has made it.
    let viewer: CacheViewer?

    var body: some View {
        if let viewer {
            StorageForm(viewer: viewer)
                .task { await viewer.refresh() }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StorageForm: View {
    let viewer: CacheViewer
    @Environment(AppModel.self) private var model
    @State private var confirmsClearAll = false

    var body: some View {
        Form {
            Section {
                ForEach(CacheCategory.allCases) { category in
                    CacheRow(
                        category: category,
                        bytes: viewer.usage?.bytes(for: category),
                        isClearing: viewer.clearing.contains(category)
                    ) {
                        Task { await viewer.clear([category]) }
                    }
                }
                LabeledContent("Total") { ByteCount(bytes: viewer.usage?.totalBytes) }
                    .fontWeight(.semibold)
                Button("Clear All Caches…") { confirmsClearAll = true }
                    .disabled((viewer.usage?.totalBytes ?? 0) == 0 || !viewer.clearing.isEmpty)
            } header: {
                Text("Cache")
            } footer: {
                Text(
                    "For every server. Tempus fetches what you clear again from your server when it's next needed."
                )
                .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            }
            .confirmationDialog("Clear all caches?", isPresented: $confirmsClearAll) {
                Button("Clear All Caches", role: .destructive) {
                    Task { await viewer.clear(Set(CacheCategory.allCases)) }
                }
            } message: {
                Text("""
                Covers, library data and lyrics load again from your server, \
                so offline you'll see less until they do. Downloads are kept.
                """)
            }

            if let errorMessage = viewer.errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error)
            }

            DownloadingSection(settings: model.settings) { model.networkChanged() }

            if let session = model.session {
                Section {
                    LabeledContent("Tracks", value: "\(session.downloads.records.count)")
                    LabeledContent("Size") { ByteCount(bytes: session.downloads.totalBytes) }
                    RemoveDownloadsButton(downloads: session.downloads, serverName: session.profile.name)
                } header: {
                    Text("Downloaded songs for \(session.profile.name)")
                } footer: {
                    Text("Downloads aren't cache: they stay until you remove them.")
                        .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// When and how tracks download.
private struct DownloadingSection: View {
    @Bindable var settings: AppSettings
    /// Downloads waiting on the network start or stop when the network rule changes.
    let onNetworkRuleChange: () -> Void

    var body: some View {
        Section {
            Toggle(
                "Only on networks that aren't a hotspot or in Low Data Mode",
                isOn: $settings.downloadsOnlyUnconstrained
            )
            .onChange(of: settings.downloadsOnlyUnconstrained) { onNetworkRuleChange() }
            Toggle(
                "Download in the streaming quality instead of the original file",
                isOn: $settings.transcodesDownloads
            )
            Toggle("Keep starred tracks downloaded", isOn: $settings.syncsStarredTracks)
        } header: {
            Text("Downloading")
        } footer: {
            Text("Starred tracks and kept-synced playlists are checked each time you sign in.")
                .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct CacheRow: View {
    let category: CacheCategory
    /// Nil while measuring.
    let bytes: Int64?
    let isClearing: Bool
    let onClear: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.medium) {
                ByteCount(bytes: bytes)
                if isClearing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Clear", action: onClear)
                        .disabled((bytes ?? 0) == 0)
                        .accessibilityLabel("Clear \(category.title)")
                }
            }
        } label: {
            Text(category.title)
            Text(category.summary)
        }
    }
}

/// A size in bytes as Finder writes it, or a spinner while it is being measured.
private struct ByteCount: View {
    let bytes: Int64?

    var body: some View {
        if let bytes {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).monospacedDigit()
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Removes every download for the server in use, after asking.
struct RemoveDownloadsButton: View {
    let downloads: DownloadManager
    let serverName: String
    @State private var confirmsRemoval = false

    var body: some View {
        Button("Remove All Downloads…", role: .destructive) { confirmsRemoval = true }
            .disabled(downloads.records.isEmpty)
            .confirmationDialog("Remove every download for \(serverName)?", isPresented: $confirmsRemoval) {
                Button("Remove All", role: .destructive) { Task { await downloads.deleteAll() } }
            }
    }
}
