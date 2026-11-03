import SwiftUI

/// Upstream Tempus's icons, imported from its vector drawables. Each raw value is the drawable's
/// name, so `ic_skip_next` here is `@drawable/ic_skip_next` there.
///
/// They render as templates: set the color with `foregroundStyle`, as upstream sets `app:tint`.
public enum TempusIcon: String, CaseIterable, Sendable {
    case add = "ic_add"
    case albums = "ic_albums"
    case arrowBack = "ic_arrow_back"
    case arrowDown = "ic_arrow_down"
    case artists = "ic_artists"
    case bookmark = "ic_bookmark"
    case bookmarkSync = "ic_bookmark_sync"
    case checkCircle = "ic_check_circle"
    case close = "ic_close"
    case delete = "ic_delete"
    case done = "ic_done"
    case download = "ic_download"
    case dragHandle = "ic_drag_handle"
    case equalizer = "ic_eq"
    case error = "ic_error"
    case expandMore = "ic_expand_more"
    case expandMoreSmall = "ic_expand_more_small"
    case export = "ic_export"
    case favorite = "ic_favorite"
    case favoritesOutlined = "ic_favorites_outlined"
    case feed = "ic_feed"
    case fileDownload = "ic_file_download"
    case filterList = "ic_filter_list"
    case folder = "ic_folder"
    case forward = "ic_forward"
    case genres = "ic_genres"
    /// Upstream's Library tab.
    case graphicEq = "ic_graphic_eq"
    case heart = "ic_heart"
    case history = "ic_history"
    case home = "ic_home"
    case infoStream = "ic_info_stream"
    case instantMixOff = "ic_instantmix_off"
    case instantMixOn = "ic_instantmix_on"
    case lanRemote = "ic_lan_remote"
    case link = "ic_link"
    case log = "ic_log"
    case lyrics = "ic_lyrics"
    case lyricsSyncLock = "ic_lyrics_sync_lock"
    case minus = "ic_minus"
    case mixFromHere = "ic_mix_from_here"
    case moreVert = "ic_more_vert"
    case navigateNext = "ic_navigate_next"
    case pause = "ic_pause"
    case play = "ic_play"
    /// Upstream's Downloads tab.
    case playForWork = "ic_play_for_work"
    case playlist = "ic_playlist"
    case playlistAdd = "ic_playlist_add"
    case podcastDownload = "ic_podcast_download"
    case queue = "ic_queue"
    case refresh = "ic_refresh"
    case `repeat` = "ic_repeat"
    case repeatOne = "ic_repeat_one"
    case replay = "ic_replay"
    case search = "ic_search"
    case serverTranscodePriority = "ic_server_transcode_priority"
    case settings = "ic_settings"
    case share = "ic_share"
    case shuffle = "ic_shuffle"
    case skipNext = "ic_skip_next"
    case skipPrevious = "ic_skip_previous"
    case skipSilence = "ic_skip_silence"
    case skipSilenceOutlined = "ic_skip_silence_outlined"
    case sortList = "ic_sort_list"
    case star = "ic_star"
    case starOutlined = "ic_star_outlined"
    case tap = "ic_tap"
    case timer = "ic_timer"
    case toolbarMotionOn = "ic_toolbar_motion_on"
    case transcode = "ic_transcode"
}

/// Artwork placeholders, drawn in the theme's surface colors for light and dark appearance.
public enum TempusPlaceholder: String, CaseIterable, Sendable {
    case album = "ic_placeholder_album"
    case artist = "ic_placeholder_artist"
    case directory = "ic_placeholder_directory"
    case folder = "ic_placeholder_folder"
    case playlist = "ic_placeholder_playlist"
    case podcast = "ic_placeholder_podcast"
    case radio = "ic_placeholder_radio"
    case song = "ic_placeholder_song"
}

/// Full-color drawings: the logo and upstream's empty-state illustrations.
public enum TempusIllustration: String, CaseIterable, Sendable {
    case logo
    /// The disc drawn on upstream's toolbar.
    case toolbarLogo = "ic_toolbar_tempo"
    case splashLogo = "ic_splash_logo"
    case crash = "ui_crash"
    case emptyDescription = "ui_empty_description"
    case emptyList = "ui_empty_list"
    case emptyPodcast = "ui_empty_podcast"
    case emptyRadioStation = "ui_empty_radio_station"
    case emptyResponse = "ui_empty_response"
    case equalizerManagedExternally = "ui_eq_managed_externally"
    case share = "ui_share"
}

/// These images are decorative, so VoiceOver doesn't read asset names like `ic_skip_next`. Give
/// an icon-only control its own label, as with `Label` or `accessibilityLabel`.
public extension Image {
    init(tempus icon: TempusIcon) {
        self.init(decorative: icon.rawValue, bundle: .module)
    }

    init(tempus placeholder: TempusPlaceholder) {
        self.init(decorative: placeholder.rawValue, bundle: .module)
    }

    init(tempus illustration: TempusIllustration) {
        self.init(decorative: illustration.rawValue, bundle: .module)
    }
}
