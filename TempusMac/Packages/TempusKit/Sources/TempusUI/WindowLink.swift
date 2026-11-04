import AppKit
import SwiftUI

/// Keeps the Settings window with the main window. On its own, Settings is a separate window:
/// it stayed on screen when the main window was minimized and stayed behind when the main window
/// moved to another Space. As a child window it minimizes, hides and changes Space with the main
/// window, and opens over it in full screen.
@MainActor
final class WindowLink {
    private weak var main: NSWindow?
    private weak var settings: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    func setMain(_ window: NSWindow) {
        guard main !== window else { return }
        main = window
        attach()
    }

    func setSettings(_ window: NSWindow) {
        guard settings !== window else { return }
        detach()
        settings = window
        observe(window)
        attach()
    }

    /// Only a showing Settings window is attached: adding a child window orders it in, so attaching
    /// a closed one would reopen it.
    private func attach() {
        guard let main, let settings, settings !== main, settings.isVisible, settings.parent !== main else { return }
        settings.parent?.removeChildWindow(settings)
        main.addChildWindow(settings, ordered: .above)
    }

    private func detach() {
        guard let settings else { return }
        settings.parent?.removeChildWindow(settings)
    }

    /// The Settings window's content arrives before the window shows, and SwiftUI keeps the window
    /// after it closes to show again on ⌘,. So it's attached each time it comes on screen or
    /// becomes key, and let go when it closes so the main window can't bring it back.
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        let attachOn: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        observers = attachOn.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach() }
            }
        }
        let close = NSWindow.willCloseNotification
        let onClose = center.addObserver(forName: close, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        }
        observers.append(onClose)
    }
}

extension View {
    /// Calls `found` with the window this view moves into. Not when it leaves one: SwiftUI can
    /// rebuild a window's content, and the old view leaving after the new one arrives mustn't
    /// undo it. `WindowLink` holds windows weakly, so a closed one goes away by itself.
    func onWindowChange(_ found: @escaping @MainActor (NSWindow) -> Void) -> some View {
        background(WindowReader(found: found))
    }
}

private struct WindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context _: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReaderView, context _: Context) {
        view.found = found
    }

    final class ReaderView: NSView {
        var found: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                found?(window)
            }
        }
    }
}
