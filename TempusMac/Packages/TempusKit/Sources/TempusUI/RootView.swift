import AppCore
import DesignSystem
import Persistence
import SwiftUI

/// The main window: the server list until a server is in use, then the library and player.
public struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigator: Navigator

    public init() {
        _navigator = State(initialValue: Navigator())
    }

    init(navigator: Navigator) {
        _navigator = State(initialValue: navigator)
    }

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
                        .environment(navigator)
                        .id(session.id)
                }
            }
        }
        .frame(minWidth: Theme.Size.windowMinWidth, minHeight: 560)
        .background(model.phase == .signedIn ? nil : ThemedFill())
        // Another server's album and artist ids mean nothing here.
        .onChange(of: model.session?.profile.id) {
            navigator.path = []
            if navigator.selection != .nowPlaying {
                navigator.selection = .home
            }
        }
    }
}

/// The theme's background behind the server list and the connecting screen. The signed-in window
/// colors its sidebar and content itself.
private struct ThemedFill: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let color = theme.color(for: .background) {
            Color(color).ignoresSafeArea()
        }
    }
}

private struct ConnectingView: View {
    let profile: ServerProfile

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            ProgressView()
            Text("Connecting to \(profile.name)…").font(.inter(.headline))
            Text(profile.address.url.absoluteString).font(.inter(.subheadline)).foregroundStyle(Theme.secondaryText)
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
            Label("Tempus couldn't start", tempus: .error)
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
