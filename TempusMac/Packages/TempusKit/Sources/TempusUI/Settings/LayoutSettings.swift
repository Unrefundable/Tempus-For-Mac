import AppCore
import DesignSystem
import SwiftUI

/// Settings' Home & Sidebar tab: which Home sections show and in what order, then the sidebar's items.
struct LayoutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            HomeSections(settings: model.settings)
            Section {
                Text("Choose what the sidebar shows. Drag items to change their order.")
                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                SidebarEditor(settings: model.settings, unavailable: model.session?.unavailableSidebarItems ?? [])
                    .frame(height: 380)
                Button("Restore Sidebar Defaults") { model.settings.setSidebarLayout(.default) }
            } header: {
                Text("Sidebar")
            }
        }
        .formStyle(.grouped)
    }
}

private struct HomeSections: View {
    let settings: AppSettings

    var body: some View {
        let layout = settings.homeLayout
        Section {
            List {
                ForEach(layout.visible) { section in
                    HStack {
                        TempusIconImage(.dragHandle).foregroundStyle(Theme.tertiaryText).tempusIconKeepsForeground()
                        Text(section.title)
                        Spacer()
                        Button("Hide") { settings.setHomeLayout(layout.hiding(section)) }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { settings.setHomeLayout(layout.moving(fromOffsets: $0, toOffset: $1)) }
            }
            .frame(minHeight: 220)
        } header: {
            Text("Home: shown, in this order")
        }
        if !layout.hidden.isEmpty {
            Section("Home: hidden") {
                ForEach(layout.hidden) { section in
                    HStack {
                        Text(section.title).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button("Show") { settings.setHomeLayout(layout.showing(section)) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        Section {
            Button("Restore Home Defaults") { settings.setHomeLayout(.default) }
        }
    }
}
