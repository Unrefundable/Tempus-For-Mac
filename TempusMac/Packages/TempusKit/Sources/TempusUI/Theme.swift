import SwiftUI

/// Design tokens. Corner radii follow upstream (12 dp artwork corners); text uses Tempus's
/// typography from `DesignSystem` or the system font, with semantic colours for light and dark mode.
public enum Theme {
    /// Where upstream uses `?attr/colorPrimary`. Upstream takes that from the wallpaper by default
    /// (`Preferences.isDynamicColorAccent()`); its `#6750A4` purple is only Material 3's fallback.
    /// The Mac equivalent is the accent chosen in System Settings.
    public static let accent = Color.accentColor

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
        /// Upstream's disc logo above the server list.
        public static let loginLogo: CGFloat = 64
        /// Album, artist and playlist tiles in grids and Home rows.
        public static let tile: CGFloat = 156
        public static let detailCover: CGFloat = 200
        public static let trackCover: CGFloat = 32
        /// A track table's row and header, for tables sized to their rows inside a scroll view.
        public static let tableRow: CGFloat = 24
        public static let tableHeader: CGFloat = 44
        /// Starred and downloaded marks beside a title.
        public static let badgeIcon: CGFloat = 10
        /// An icon beside title-size text, such as a folder's name or an episode's play button.
        public static let titleIcon: CGFloat = 22
    }

    /// Upstream dims tracks that already played in the queue.
    public static let playedOpacity = 0.45
}
