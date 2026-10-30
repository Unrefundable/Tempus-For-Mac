import AppKit
import SwiftUI

/// Design tokens. Colours and corner radii follow upstream (Material 3 purple, 12 dp artwork
/// corners); text uses the system font and semantic colours so light and dark mode both work.
public enum Theme {
    /// Upstream's primary: #6750A4 in light mode, #D0BCFF in dark mode.
    public static let accent = Color(nsColor: NSColor(name: "TempusAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(srgbRed: 0x67 / 255, green: 0x50 / 255, blue: 0xA4 / 255, alpha: 1)
            : NSColor(srgbRed: 0xD0 / 255, green: 0xBC / 255, blue: 0xFF / 255, alpha: 1)
    })

    public enum Radius {
        /// Small covers: player bar and queue rows.
        public static let artworkSmall: CGFloat = 6
        /// Upstream's "Medium" rounded-corner setting.
        public static let artwork: CGFloat = 12
        public static let row: CGFloat = 12
        public static let card: CGFloat = 16
    }

    public enum Spacing {
        public static let xSmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 24
    }

    public enum Size {
        public static let playerBarCover: CGFloat = 42
        public static let playerBarHeight: CGFloat = 64
        public static let queueCover: CGFloat = 40
        public static let nowPlayingArtwork: CGFloat = 440
        public static let sidebarMinWidth: CGFloat = 200
        public static let inspectorWidth: CGFloat = 320
        /// Fits the sidebar, the content (player bar included) and the inspector, so opening the
        /// inspector never pushes columns past the window's edges.
        public static let windowMinWidth: CGFloat = 900
        public static let loginWidth: CGFloat = 480
    }

    /// Upstream dims tracks that already played in the queue.
    public static let playedOpacity = 0.45
}
