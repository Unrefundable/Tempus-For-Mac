import AppCore
import AppKit

/// Zooms or minimizes the main window when its titlebar is double-clicked, as System Settings ›
/// Desktop & Dock asks. The Mac does this by itself for most windows, but here the toolbar's empty
/// space belongs to its space items, which take the clicks, so double-clicking it did nothing.
@MainActor
final class TitlebarDoubleClick {
    private weak var window: NSWindow?
    private var monitor: Any?

    func attach(to window: NSWindow) {
        self.window = window
        guard monitor == nil else { return }
        // Monitors run on the main thread. Only the click's place crosses into the main actor.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount == 2 else { return event }
            let location = event.locationInWindow
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                self?.handleDoubleClick(at: location, windowNumber: windowNumber) ?? false
            }
            return handled ? nil : event
        }
    }

    /// Acts on a double-click on the titlebar's empty space, and says whether it did.
    private func handleDoubleClick(at location: CGPoint, windowNumber: Int) -> Bool {
        guard let window, window.windowNumber == windowNumber,
              !window.styleMask.contains(.fullScreen),
              location.y >= window.contentLayoutRect.maxY,
              !Self.isOverButton(location, in: window)
        else { return false }
        switch TitlebarDoubleClickAction(defaults: .standard) {
        case .zoom:
            window.zoom(nil)
        case .minimize:
            window.miniaturize(nil)
        case .nothing:
            return false
        }
        return true
    }

    /// Whether `location` is on a toolbar button or the window's own buttons. The toolbar's spaces
    /// have no view, so everything else in the titlebar is empty space.
    private static func isOverButton(_ location: CGPoint, in window: NSWindow) -> Bool {
        let itemViews = (window.toolbar?.items ?? []).compactMap(\.view)
        let windowButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        return (itemViews + windowButtons).contains { view in
            !view.isHiddenOrHasHiddenAncestor && view.convert(view.bounds, to: nil).contains(location)
        }
    }
}
