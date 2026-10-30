@testable import Playback
import SubsonicAPI
import Testing

@Suite("Play queue: order, navigation and edits")
struct PlayQueueTests {
    private func ids(_ items: [QueueItem]) -> [String] {
        items.map(\.song.id)
    }

    private func queue(_ ids: String..., at index: Int = 0, repeat mode: RepeatMode = .off) throws -> PlaybackQueue {
        try PlaybackQueue(songs: ids.map { try song($0) }, startingAt: index, repeatMode: mode)
    }

    @Test("Starts at the requested track; an out-of-range start falls back to the first")
    func start() throws {
        #expect(try queue("a", "b", "c", at: 1).current?.song.id == "b")
        #expect(try queue("a", "b", at: 9).current?.song.id == "a")
        #expect(PlaybackQueue().current == nil)
        #expect(PlaybackQueue().isEmpty)
    }

    @Test("Next advances, stops at the end, and wraps only with repeat all")
    func next() throws {
        #expect(try queue("a", "b").nextItem(afterTrackEnded: true)?.song.id == "b")
        #expect(try queue("a", "b", at: 1).nextItem(afterTrackEnded: true) == nil)
        #expect(try queue("a", "b", at: 1, repeat: .all).nextItem(afterTrackEnded: false)?.song.id == "a")
    }

    @Test("Repeat one replays the track when it ends, but a skip still moves on")
    func repeatOne() throws {
        let looping = try queue("a", "b", repeat: .one)
        #expect(looping.nextItem(afterTrackEnded: true)?.id == looping.current?.id)
        #expect(looping.nextItem(afterTrackEnded: false)?.song.id == "b")
        #expect(try queue("a", "b", at: 1, repeat: .one).nextItem(afterTrackEnded: false) == nil)
    }

    @Test("Previous goes back, and wraps to the last track only with repeat all")
    func previous() throws {
        #expect(try queue("a", "b", at: 1).previousItem()?.song.id == "a")
        #expect(try queue("a", "b").previousItem() == nil)
        #expect(try queue("a", "b", repeat: .all).previousItem()?.song.id == "b")
    }

    @Test("Selecting an entry makes it current; an unknown id changes nothing")
    func select() throws {
        let original = try queue("a", "b", "c")
        let third = original.items[2]
        #expect(original.selecting(third.id).current == third)
        #expect(try original.selecting(QueueItem(song: song("x")).id) == original)
    }

    @Test("Play next inserts right after the current track, keeping the inserted order")
    func playNext() throws {
        let edited = try queue("a", "b", "c").insertingNext(songs("x", "y"))
        #expect(ids(edited.items) == ["a", "x", "y", "b", "c"])
        #expect(edited.current?.song.id == "a")
    }

    @Test("Adding to an empty queue makes the first added track current")
    func addToEmpty() throws {
        #expect(try PlaybackQueue().appending(songs("x", "y")).current?.song.id == "x")
        #expect(try PlaybackQueue().insertingNext(songs("x")).current?.song.id == "x")
    }

    @Test("Add to queue appends at the end")
    func append() throws {
        #expect(try ids(queue("a", "b").appending(songs("x")).items) == ["a", "b", "x"])
    }

    @Test("Removing works for any entry except the current one")
    func remove() throws {
        let original = try queue("a", "b", "c", at: 1)
        #expect(ids(original.removing(original.items[2].id).items) == ["a", "b"])
        #expect(original.removing(original.items[1].id) == original)
    }

    @Test("The same song can be queued twice and each entry is handled on its own")
    func duplicates() throws {
        let original = try queue("a", "a", "b")
        let edited = original.removing(original.items[1].id)
        #expect(ids(edited.items) == ["a", "b"])
        #expect(edited.current == original.items[0])
    }

    @Test("Moving an entry reorders the queue and keeps the current track")
    func move() throws {
        let original = try queue("a", "b", "c", "d", at: 1)
        let moved = original.moving(original.items[3].id, to: 0)
        #expect(ids(moved.items) == ["d", "a", "b", "c"])
        #expect(moved.current?.song.id == "b")
        #expect(ids(original.moving(original.items[0].id, to: 99).items) == ["b", "c", "d", "a"])
    }

    @Test("Shuffle puts the current track first and keeps every entry")
    func shuffle() throws {
        var generator = SeededGenerator(seed: 7)
        let original = try queue("a", "b", "c", "d", "e", at: 2)
        let shuffled = original.shuffled(using: &generator)

        #expect(shuffled.isShuffled)
        #expect(shuffled.items.first == original.current)
        #expect(Set(shuffled.items) == Set(original.items))
        #expect(shuffled.items != original.items)
    }

    @Test("Turning shuffle off restores the original order and keeps the current track")
    func unshuffle() throws {
        var generator = SeededGenerator(seed: 7)
        let original = try queue("a", "b", "c", "d", at: 2)
        let restored = original.shuffled(using: &generator).unshuffled()

        #expect(restored.items == original.items)
        #expect(restored.current == original.current)
        #expect(!restored.isShuffled)
    }

    @Test("Tracks added while shuffled play next, and keep their place when shuffle is turned off")
    func editWhileShuffled() throws {
        var generator = SeededGenerator(seed: 3)
        let shuffled = try queue("a", "b", "c", at: 1).shuffled(using: &generator)
        let edited = try shuffled.insertingNext(songs("x")).appending(songs("z"))

        #expect(edited.nextItem(afterTrackEnded: true)?.song.id == "x")
        #expect(edited.items.last?.song.id == "z")
        #expect(ids(edited.unshuffled().items) == ["a", "b", "x", "c", "z"])
    }

    @Test("Shuffling upcoming tracks leaves played tracks and the current one in place")
    func shuffleUpcoming() throws {
        var generator = SeededGenerator(seed: 11)
        let original = try queue("a", "b", "c", "d", "e", "f", at: 1)
        let edited = original.shufflingUpcoming(using: &generator)

        #expect(ids(Array(edited.items.prefix(2))) == ["a", "b"])
        #expect(Set(edited.items.dropFirst(2)) == Set(original.items.dropFirst(2)))
        #expect(edited.items != original.items)
        #expect(!edited.isShuffled)
        #expect(edited.unshuffled().items == edited.items)
    }

    @Test("The repeat button cycles off, all, one")
    func repeatCycle() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }
}
