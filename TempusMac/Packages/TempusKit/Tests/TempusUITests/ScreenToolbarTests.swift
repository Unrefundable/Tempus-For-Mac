@testable import AppCore
@testable import TempusUI
import Testing

@MainActor
struct ScreenToolbarTests {
    @Test
    func `sidebar items with their own controls map to their screen`() {
        #expect(ToolbarScreen(selection: .home, route: nil) == .home)
        #expect(ToolbarScreen(selection: .albums, route: nil) == .albums)
        #expect(ToolbarScreen(selection: .playlists, route: nil) == .playlists)
        #expect(ToolbarScreen(selection: .podcasts, route: nil) == .podcasts)
        #expect(ToolbarScreen(selection: .radio, route: nil) == .radio)
        #expect(ToolbarScreen(selection: .shares, route: nil) == .shares)
        #expect(ToolbarScreen(selection: .downloads, route: nil) == .downloads)
    }

    @Test
    func `screens without controls show only the panel button`() {
        for item in [SidebarItem.nowPlaying, .search, .artists, .genres, .favorites, .folders] {
            #expect(ToolbarScreen(selection: item, route: nil) == .other)
        }
    }

    @Test
    func `an opened page replaces the sidebar screen's controls`() {
        #expect(ToolbarScreen(selection: .home, route: .album(id: "1")) == .other)
        #expect(ToolbarScreen(selection: .playlists, route: .playlist(id: "1")) == .other)
        // Home's "see all playlists" shows the Playlists screen, controls included.
        #expect(ToolbarScreen(selection: .home, route: .allPlaylists) == .playlists)
    }

    @Test
    func `each screen offers the buttons it had before`() {
        #expect(ToolbarScreen.home.refreshTitle == "Reload Home")
        #expect(ToolbarScreen.home.addTitle == nil)
        #expect(ToolbarScreen.playlists.addTitle == "New Playlist")
        #expect(ToolbarScreen.playlists.refreshTitle == "Refresh")
        #expect(ToolbarScreen.podcasts.addTitle == "Add Podcast")
        #expect(ToolbarScreen.podcasts.refreshTitle == "Check for New Episodes")
        #expect(ToolbarScreen.radio.addTitle == "Add a New Radio")
        #expect(ToolbarScreen.radio.refreshTitle == nil)
        #expect(ToolbarScreen.shares.refreshTitle == "Refresh")
        #expect(ToolbarScreen.albums.addTitle == nil)
        #expect(ToolbarScreen.albums.refreshTitle == nil)
        #expect(ToolbarScreen.other.addTitle == nil)
        #expect(ToolbarScreen.other.refreshTitle == nil)
    }

    @Test
    func `repeated clicks of one button are each a new command`() {
        let commands = ScreenCommands()
        #expect(commands.latest == nil)

        commands.send(.refresh)
        let first = commands.latest
        commands.send(.refresh)

        #expect(first?.command == .refresh)
        #expect(commands.latest?.command == .refresh)
        #expect(commands.latest != first)
    }
}
