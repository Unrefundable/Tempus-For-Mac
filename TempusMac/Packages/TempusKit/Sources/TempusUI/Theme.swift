import AppCore
import SwiftUI

/// Design tokens. Corner radii follow upstream (12 dp artwork corners); text uses Tempus's
/// typography from `DesignSystem` or the system font, with semantic colours for light and dark mode.
public enum Theme {
    /// Where upstream uses `?attr/colorPrimary`. Upstream takes that from the wallpaper by default
    /// (`Preferences.isDynamicColorAccent()`); its `#6750A4` purple is only Material 3's fallback.
    /// The Mac equivalent is the accent chosen in System Settings, unless the theme sets one.
    public static let accent = ThemeStyle(role: .accent)
    /// `.primary`, `.secondary` and `.tertiary` unless the theme sets them.
    public static let primaryText = ThemeStyle(role: .primaryText)
    public static let secondaryText = ThemeStyle(role: .secondaryText)
    public static let tertiaryText = ThemeStyle(role: .tertiaryText)
    /// The lyric line being sung.
    public static let lyrics = ThemeStyle(role: .lyrics)
    public static let error = ThemeStyle(role: .error)
    public static let success = ThemeStyle(role: .success)
    /// The player bar's material unless the theme sets a color.
    public static let playerBar = ThemeStyle(role: .playerBar)

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
        public static let sidebarIdealWidth: CGFloat = 220
        public static let inspectorWidth: CGFloat = 320
        /// Fits the sidebar, the content (player bar included) and the inspector, so opening the
        /// inspector never pushes columns past the window's edges.
        public static let windowMinWidth: CGFloat = 900
        /// The content column's least width: what's left of the narrowest window beside the
        /// sidebar, so showing the sidebar never needs more room than the window has.
        public static let detailMinWidth: CGFloat = windowMinWidth - sidebarIdealWidth
        public static let loginWidth: CGFloat = 480
        /// Upstream's disc logo above the server list.
        public static let loginLogo: CGFloat = 64
        /// Album, artist and playlist tiles in grids and Home rows.
        public static let tile: CGFloat = 156
        public static let detailCover: CGFloat = 200
        public static let trackCover: CGFloat = 32
        /// A track list's cover, as upstream's 52 dp row cover scaled to the Mac's denser lists.
        public static let trackRowCover: CGFloat = 40
        /// A track list's row as the table lays it out (the cover, its padding and the table's own
        /// row inset), for tables sized to their rows inside a scroll view.
        public static let trackRow: CGFloat = 56
        /// Starred and downloaded marks at the end of a track row.
        public static let trackMark: CGFloat = 14
        /// Starred and downloaded marks beside a title.
        public static let badgeIcon: CGFloat = 10
        /// An icon beside title-size text, such as a folder's name or an episode's play button.
        public static let titleIcon: CGFloat = 22
    }

    /// Upstream darkens the playing track's cover under its play icon (`#80000000`).
    public static let nowPlayingScrim = 0.5

    /// Upstream dims tracks that already played in the queue.
    public static let playedOpacity = 0.45
}
