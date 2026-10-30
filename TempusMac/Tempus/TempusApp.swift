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

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        controller.prepareForTermination {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
