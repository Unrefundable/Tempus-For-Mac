import AppCore
import Persistence
import SwiftUI

/// The main window: the server list until a server is in use, then the library and player.
public struct RootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                ServerListView()
            case let .connecting(profile):
                ConnectingView(profile: profile)
            case .signedIn:
                if let session = model.session {
                    MainView(session: session)
                        .environment(\.artwork, session.artwork)
                }
            }
        }
        .frame(minWidth: Theme.Size.windowMinWidth, minHeight: 560)
        .tint(Theme.accent)
    }
}

private struct ConnectingView: View {
    let profile: ServerProfile

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            ProgressView()
            Text("Connecting to \(profile.name)…").font(.headline)
            Text(profile.address.url.absoluteString).font(.subheadline).foregroundStyle(.secondary)
            Button("Cancel") {
                Task { await model.signOut() }
            }
        }
    }
}

/// When Tempus can't open its database at launch, there is nothing else to show.
public struct StartupFailureView: View {
    let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label("Tempus couldn't start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

#Preview("Signed out") {
    RootView().environment(PreviewSupport.model(signedIn: false))
}

#Preview("Signed in") {
    RootView().environment(PreviewSupport.model(signedIn: true))
}
