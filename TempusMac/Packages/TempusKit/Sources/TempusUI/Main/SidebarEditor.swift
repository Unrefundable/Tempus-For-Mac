import AppCore
import DesignSystem
import SwiftUI

/// Edit Sidebar, as in Finder and Music: a checkbox per item to show or hide it, and drag to
/// reorder within its group. Used in Settings › Sidebar and in the sheet the sidebar opens.
struct SidebarEditor: View {
    let settings: AppSettings
    /// Items this server can't show (no podcasts or shares). Listed, but the sidebar leaves them out.
    var unavailable: Set<SidebarItem> = []

    var body: some View {
        let layout = settings.sidebarLayout
        List {
            ForEach(SidebarSection.allCases) { section in
                let items = layout.items(in: section)
                Section(section.editorTitle) {
                    ForEach(items) { item in
                        row(item, canToggle: layout.canHide(item) || !layout.isVisible(item))
                    }
                    .onMove { offsets, destination in
                        settings.setSidebarLayout(
                            settings.sidebarLayout.moving(fromOffsets: offsets, toOffset: destination, among: items)
                        )
                    }
                }
            }
        }
    }

    /// `canToggle` is false for the last visible item, which has to stay.
    private func row(_ item: SidebarItem, canToggle: Bool) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { settings.sidebarLayout.isVisible(item) },
                set: { settings.setSidebarLayout(settings.sidebarLayout.setting(item, visible: $0)) }
            )) {
                SidebarLabel(item: item)
            }
            .toggleStyle(.checkbox)
            .disabled(!canToggle)
            if unavailable.contains(item) {
                Text("Not on this server").font(.inter(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            TempusIconImage(.dragHandle, accessibilityName: Text("Drag to reorder")).foregroundStyle(.tertiary)
        }
    }
}

/// The editor as a sheet over the main window, from the sidebar's context menu or View › Edit Sidebar….
struct SidebarEditorSheet: View {
    let settings: AppSettings
    var unavailable: Set<SidebarItem> = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Edit Sidebar").font(.inter(.headline))
            Text("Choose what the sidebar shows. Drag items to change their order.")
                .font(.inter(.callout))
                .foregroundStyle(.secondary)
            SidebarEditor(settings: settings, unavailable: unavailable)
                .frame(minHeight: 420)
            HStack {
                Button("Restore Defaults") { settings.setSidebarLayout(.default) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 380)
    }
}

extension ServerSession {
    /// Sidebar items this server has no screen for.
    var unavailableSidebarItems: Set<SidebarItem> {
        Set([
            features.hasPodcasts ? nil : SidebarItem.podcasts,
            features.hasShares ? nil : SidebarItem.shares,
        ].compactMap(\.self))
    }
}
