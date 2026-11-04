import AppCore
import DesignSystem
import Persistence
import SwiftUI

/// Upstream's "Subsonic servers" screen: the saved servers, name over address, connect on click.
/// With no server saved it goes straight to the editor, as the login screen.
struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditorTarget?
    @State private var selection: ServerProfile.ID?

    var body: some View {
        if model.servers.isEmpty {
            ScrollView {
                VStack(spacing: Theme.Spacing.xLarge) {
                    header(subtitle: "Add your Subsonic, OpenSubsonic or Navidrome server to start listening.")
                    errorBanner
                    ServerEditorView(existing: nil, onDone: nil)
                        .frame(width: Theme.Size.loginWidth)
                }
                .padding(Theme.Spacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: Theme.Spacing.large) {
            header(subtitle: "Choose a server to connect to.")
            errorBanner
            List(model.servers, selection: $selection) { server in
                ServerRow(server: server)
                    .contextMenu { contextMenu(for: server) }
            }
            .contextMenu(forSelectionType: ServerProfile.ID.self) { _ in
            } primaryAction: { ids in
                connect(ids.first)
            }
            .frame(width: Theme.Size.loginWidth, height: 280)
            .clipShape(.rect(cornerRadius: Theme.Radius.card))
            HStack {
                Button("Add Server…", tempus: .add) { editing = .new }
                Spacer()
                Button("Edit…") { editing = selectedServer.map(EditorTarget.edit) }
                    .disabled(selectedServer == nil)
                Button("Connect") { connect(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedServer == nil)
            }
            .frame(width: Theme.Size.loginWidth)
        }
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editing) { target in
            ServerEditorView(existing: target.server) { editing = nil }
                .frame(width: Theme.Size.loginWidth)
                .padding(Theme.Spacing.large)
        }
        .onAppear { selection = selection ?? model.servers.first?.id }
    }

    private var selectedServer: ServerProfile? {
        model.servers.first { $0.id == selection }
    }

    private func header(subtitle: String) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(tempus: .toolbarLogo)
                .resizable()
                .frame(width: Theme.Size.loginLogo, height: Theme.Size.loginLogo)
            Text("Subsonic servers").font(.inter(.largeTitle, weight: .bold))
            Text(subtitle).foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let message = model.errorMessage {
            Label(message, tempus: .error)
                .foregroundStyle(Theme.error)
                .tempusIconKeepsForeground()
                .frame(width: Theme.Size.loginWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func contextMenu(for server: ServerProfile) -> some View {
        Button("Connect") { connect(server.id) }
        Button("Edit…") { editing = .edit(server) }
    }

    private func connect(_ id: ServerProfile.ID?) {
        guard let server = model.servers.first(where: { $0.id == id }) else { return }
        Task { await model.connect(to: server) }
    }
}

private struct ServerRow: View {
    let server: ServerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.name).font(.inter(.headline))
            Text(server.address.url.absoluteString)
                .font(.inter(.subheadline))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, Theme.Spacing.xSmall)
    }
}

/// Which server the editor sheet is for.
enum EditorTarget: Identifiable {
    case new
    case edit(ServerProfile)

    var id: String {
        server?.id ?? "new"
    }

    var server: ServerProfile? {
        if case let .edit(server) = self {
            server
        } else {
            nil
        }
    }
}

#Preview {
    ServerListView()
        .environment(PreviewSupport.model(signedIn: false))
        .frame(width: 700, height: 700)
}
