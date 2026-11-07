import AppKit

/// Colors the strip behind the toolbar in full screen.
///
/// In full screen AppKit moves the toolbar into a window of its own and fills the strip behind it,
/// beside the sidebar, with an opaque grey layer it names "NSOpaqueBackstop". No public API reaches
/// that layer: not the window's background, a transparent titlebar, SwiftUI's toolbar background
/// or the scroll edge effect, so a themed window showed a grey band across the top in full screen.
/// AppKit also sets the layer's grey again on every layout pass (each frame of the sidebar
/// sliding, say), so the color is watched and put back the moment AppKit changes it, within the
/// same pass, before anything is drawn.
///
/// Found in the full-screen toolbar window's layers on macOS 26. If a later macOS names or builds
/// it differently, nothing is found and nothing changes.
@MainActor
final class FullScreenToolbarBackstop {
    private static let toolbarWindowClassName = "NSToolbarFullScreenWindow"
    private static let backstopLayerName = "NSOpaqueBackstop"
    /// How far below the toolbar window's content layer to look. The backstop is a direct sublayer.
    private static let searchDepth = 3

    /// The color to keep the backstop in, or nil to leave it to AppKit.
    private var color: CGColor?
    private weak var backstop: CALayer?
    private var originalColor: CGColor?
    private var observation: NSKeyValueObservation?

    /// Keeps the backstop behind `window`'s full-screen toolbar in `color`, or gives it back
    /// AppKit's own color when `color` is nil. Outside full screen there's no backstop to find.
    func paint(_ color: NSColor?, behindToolbarOf window: NSWindow) {
        self.color = color?.cgColor
        if let found = Self.backstop(behindToolbarOf: window), found !== backstop {
            watch(found)
        }
        guard let backstop else { return }
        backstop.backgroundColor = self.color ?? originalColor
    }

    private func watch(_ layer: CALayer) {
        observation?.invalidate()
        backstop = layer
        originalColor = layer.backgroundColor
        observation = layer.observe(\.backgroundColor) { [weak self] _, _ in
            // AppKit lays out on the main thread, so this runs there.
            MainActor.assumeIsolated { self?.restoreColor() }
        }
    }

    private func restoreColor() {
        guard let color, let backstop, backstop.backgroundColor != color else { return }
        backstop.backgroundColor = color
    }

    /// The backstop in the toolbar window AppKit made for `window` in full screen. There is one
    /// such window per full-screen space, so it's the one on the same screen.
    private static func backstop(behindToolbarOf window: NSWindow) -> CALayer? {
        guard window.styleMask.contains(.fullScreen) else { return nil }
        let toolbarWindow = NSApp.windows.first { candidate in
            String(describing: type(of: candidate)) == toolbarWindowClassName && candidate.screen == window.screen
        }
        return backstop(in: toolbarWindow?.contentView?.layer, depth: 0)
    }

    private static func backstop(in layer: CALayer?, depth: Int) -> CALayer? {
        guard let layer, depth <= searchDepth else { return nil }
        if layer.name == backstopLayerName {
            return layer
        }
        return (layer.sublayers ?? []).lazy.compactMap { backstop(in: $0, depth: depth + 1) }.first
    }
}
