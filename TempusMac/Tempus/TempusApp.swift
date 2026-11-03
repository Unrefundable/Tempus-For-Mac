import DesignSystem
import SwiftUI

@main
struct TempusApp: App {
    init() {
        TempusFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
