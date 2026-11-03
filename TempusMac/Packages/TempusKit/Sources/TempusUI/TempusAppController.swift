import AppCore
import AppKit
import DesignSystem
import os
import SwiftUI

/// What the app target needs: the model on live services, the window's content, the menu
/// commands and the work to do before quitting. Keeps the Xcode target down to `TempusUI`.
@MainActor
public final class TempusAppController {
    public enum DemoMode: Sendable {
        case signedIn, signedOut
    }

    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "App")

    private let model: Result<AppModel, any Error>
    private let isDemo: Bool
    private let navigator = Navigator()
    private lazy var dock = DockMenu(model: try? model.get())

    /// - Parameter demo: run on in-memory preview data, signed in or not, for screenshots that
    ///   leave the real database and Keychain alone. Debug builds only.
    public init(demo: DemoMode? = nil) {
        isDemo = demo != nil
        model = demo.map { .success(PreviewSupport.model(signedIn: $0 == .signedIn)) } ?? Result { try AppModel.live() }
        if case let .failure(error) = model {
            Self.logger.fault("Couldn't start: \(error)")
        }
        Self.current = self
    }

    /// Every window's text defaults to Tempus's typeface, Inter.
    public var rootView: some View {
        rootContent.font(.inter(.body))
    }

    @ViewBuilder private var rootContent: some View {
        switch model {
        case let .success(model):
            let launches = !isDemo
            RootView(navigator: navigator)
                .environment(model)
                .task {
                    if launches {
                        await model.launch()
                    }
                }
        case let .failure(error):
            StartupFailureView(message: error.localizedDescription)
        }
    }

    public var commands: TempusCommands {
        TempusCommands(model: try? model.get(), navigator: navigator)
    }

    /// The Settings window's content.
    @ViewBuilder public var settingsView: some View {
        if case let .success(model) = model {
            SettingsView().environment(model).font(.inter(.body))
        }
    }

    /// The menu bar mini player's content.
    @ViewBuilder public var menuBarContent: some View {
        if case let .success(model) = model {
            MenuBarPlayer().environment(model).font(.inter(.body))
        }
    }

    /// The controller the app is running on, for App Intents and other system entry points.
    public private(set) weak static var current: TempusAppController?

    public func togglePlayPause() {
        (try? model.get())?.session?.player.togglePlayPause()
    }

    public func next() {
        (try? model.get())?.session?.player.next()
    }

    public func previous() {
        (try? model.get())?.session?.player.previous()
    }

    /// For `applicationDockMenu`.
    public func dockMenu() -> NSMenu {
        dock.menu()
    }

    /// Saves the player's place, then calls `done` once; after `terminationDeadline` it calls
    /// `done` anyway, so a stuck save can't stop the app quitting. Use from
    /// `applicationShouldTerminate` with `.terminateLater`.
    public func prepareForTermination(then done: @escaping @MainActor () -> Void) {
        guard case let .success(model) = model else {
            done()
            return
        }
        let once = Once(done)
        Task {
            await model.prepareForTermination()
            once.run()
        }
        Task {
            try? await Task.sleep(for: Self.terminationDeadline)
            once.run()
        }
    }

    static let terminationDeadline = Duration.seconds(2)
}

/// Runs an action the first time it's asked to.
@MainActor
private final class Once {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func run() {
        action?()
        action = nil
    }
}
