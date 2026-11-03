@testable import AppCore
import Foundation
import Testing

struct SidebarLayoutTests {
    @Test
    func `defaults show every item, with Favorites in Library`() {
        let layout = SidebarLayout(storedOrder: nil, storedHidden: nil)
        #expect(layout == .default)
        #expect(layout.hidden.isEmpty)
        #expect(layout.order == SidebarItem.allCases)
        #expect(layout.items(in: .library) == [.albums, .artists, .genres, .playlists, .favorites, .folders])
        #expect(layout.visibleItems(in: .main) == [.nowPlaying, .home, .search])
        #expect(SidebarItem.favorites.title == "Favorites")
    }

    @Test
    func `every item belongs to exactly one section`() {
        let grouped = SidebarSection.allCases.flatMap { SidebarLayout.default.items(in: $0) }
        #expect(grouped.count == SidebarItem.allCases.count)
        #expect(Set(grouped) == Set(SidebarItem.allCases))
    }

    @Test
    func `stored layouts ignore unknown and repeated names and add new items`() {
        let layout = SidebarLayout(
            storedOrder: ["radio", "fromTheFuture", "albums", "radio"],
            storedHidden: ["albums", "alsoFromTheFuture"]
        )
        #expect(layout.order.prefix(2) == [.radio, .albums])
        #expect(Set(layout.order) == Set(SidebarItem.allCases))
        #expect(layout.order.count == SidebarItem.allCases.count)
        #expect(layout.hidden == [.albums])
        #expect(layout.items(in: .more).first == .radio)
        // Items the stored order didn't know about keep their default order after the known ones.
        #expect(layout.items(in: .library) == [.albums, .artists, .genres, .playlists, .favorites, .folders])
    }

    @Test
    func `hiding and showing items`() {
        let layout = SidebarLayout.default.hiding(.radio).hiding(.shares)
        #expect(layout.visibleItems(in: .more) == [.podcasts, .downloads])
        #expect(!layout.isVisible(.radio))
        #expect(layout.showing(.radio).visibleItems(in: .more) == [.podcasts, .radio, .downloads])
        #expect(layout.setting(.shares, visible: true) == layout.showing(.shares))
        #expect(layout.hiding(.radio) == layout)
        #expect(layout.items(in: .more) == [.podcasts, .radio, .shares, .downloads])
    }

    @Test
    func `moving items within the rows a section shows`() {
        let layout = SidebarLayout.default
        let library = layout.items(in: .library)
        let moved = layout.moving(fromOffsets: [4], toOffset: 0, among: library)
        #expect(moved.items(in: .library) == [.favorites, .albums, .artists, .genres, .playlists, .folders])
        #expect(moved.items(in: .main) == layout.items(in: .main))
        #expect(moved.items(in: .more) == layout.items(in: .more))
    }

    @Test
    func `moving among visible rows keeps hidden items in their slots`() {
        let layout = SidebarLayout.default.hiding(.genres)
        let shown = layout.visibleItems(in: .library) // albums, artists, playlists, favorites, folders
        let moved = layout.moving(fromOffsets: [0], toOffset: 4, among: shown)
        #expect(moved.visibleItems(in: .library) == [.artists, .playlists, .favorites, .albums, .folders])
        #expect(moved.items(in: .library) == [.artists, .playlists, .genres, .favorites, .albums, .folders])
        #expect(moved.hidden == [.genres])
    }

    @Test
    func `moving several rows, onto itself and with stray offsets`() {
        let layout = SidebarLayout.default
        let more = layout.items(in: .more) // podcasts, radio, shares, downloads
        let both = layout.moving(fromOffsets: [0, 2], toOffset: 4, among: more)
        #expect(both.items(in: .more) == [.radio, .downloads, .podcasts, .shares])
        #expect(layout.moving(fromOffsets: [1], toOffset: 1, among: more) == layout)
        #expect(layout.moving(fromOffsets: [1], toOffset: 2, among: more) == layout)
        #expect(layout.moving(fromOffsets: [9], toOffset: 0, among: more) == layout)
    }

    @Test
    func `the last visible item can't be hidden`() {
        let onlyHome = SidebarItem.allCases.filter { $0 != .home }.reduce(SidebarLayout.default) { $0.hiding($1) }
        #expect(onlyHome.visibleItems(in: .main) == [.home])
        #expect(!onlyHome.canHide(.home))
        #expect(!onlyHome.canHide(.albums))
        #expect(SidebarLayout.default.canHide(.home))
    }

    @MainActor @Test
    func `settings persist the sidebar layout`() throws {
        let defaults = try #require(UserDefaults(suiteName: "SidebarLayoutTests-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.sidebarLayout == .default)
        let layout = SidebarLayout.default
            .hiding(.folders)
            .moving(fromOffsets: [4], toOffset: 0, among: SidebarLayout.default.items(in: .library))
        settings.setSidebarLayout(layout)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.sidebarLayout == layout)
        #expect(reloaded.sidebarLayout.visibleItems(in: .library).first == .favorites)
        #expect(!reloaded.sidebarLayout.isVisible(.folders))
    }
}
