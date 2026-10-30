import SwiftUI

@main
struct TempusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView(
                "Tempus",
                systemImage: "music.note",
                description: Text("Connect to a Subsonic server to get started.")
            )
            .frame(minWidth: 900, minHeight: 600)
        }
    }
}
