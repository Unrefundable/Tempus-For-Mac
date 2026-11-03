import AppIntents
import SwiftUI
import TempusUI

@main
struct TempusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Tempus", id: "main") {
            appDelegate.controller.rootView
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .commands { appDelegate.controller.commands }

        Settings {
            appDelegate.controller.settingsView
        }

        MenuBarExtra("Tempus", systemImage: "music.note") {
            appDelegate.controller.menuBarContent
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the app's model for its whole life, and saves the player's place before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
        /// `-TempusDemo` (signed in) and `-TempusDemoSignedOut` show preview data instead of the
        /// saved servers.
        let controller = TempusAppController(demo: AppDelegate.demoMode)

        private static var demoMode: TempusAppController.DemoMode? {
            let arguments = CommandLine.arguments
            if arguments.contains("-TempusDemoSignedOut") {
                return .signedOut
            }
            return arguments.contains("-TempusDemo") ? .signedIn : nil
        }
    #else
        let controller = TempusAppController()
    #endif

    /// Music keeps playing with the window closed, as in Music.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        controller.dockMenu()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        controller.prepareForTermination {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Play/pause, next and previous for Shortcuts and Siri.
struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        TempusAppController.current?.togglePlayPause()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        TempusAppController.current?.next()
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        TempusAppController.current?.previous()
        return .result()
    }
}

struct TempusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: ["Play or pause \(.applicationName)"],
            shortTitle: "Play or Pause",
            systemImageName: "playpause"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track in \(.applicationName)"],
            shortTitle: "Next Track",
            systemImageName: "forward"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["Previous track in \(.applicationName)"],
            shortTitle: "Previous Track",
            systemImageName: "backward"
        )
    }
}
