import DesignSystem
import SwiftUI

/// The main window: upstream's drawer as a sidebar, and the selected page on the system background,
/// which stands in for upstream's wallpaper-derived surface.
struct RootView: View {
    @State private var selection: SidebarDestination = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarDestination.main) { SidebarRow(destination: $0) }
                }
                Section("All") {
                    ForEach(SidebarDestination.catalogues) { SidebarRow(destination: $0) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader() }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            EmptyStateView(state: selection.emptyState)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// Upstream's toolbar logo and app name (`layout_toolbar.xml`).
private struct SidebarHeader: View {
    private static let logoSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            Image(tempus: .toolbarLogo)
                .resizable()
                .frame(width: Self.logoSize, height: Self.logoSize)
            Text("Tempus")
                .tempusTextStyle(.labelLarge)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct SidebarRow: View {
    private static let iconSize: CGFloat = 18

    let destination: SidebarDestination

    var body: some View {
        Label {
            Text(destination.title)
                .font(TempusTextStyle.bodyMedium.font)
        } icon: {
            Image(tempus: destination.icon)
                .resizable()
                .scaledToFit()
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
        .tag(destination)
    }
}

#Preview {
    RootView()
}
