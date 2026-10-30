import Foundation
import SubsonicAPI

/// One entry in the play queue. A song can be queued more than once, so entries have their own id.
public struct QueueItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let song: Song

    public init(song: Song, id: UUID = UUID()) {
        self.id = id
        self.song = song
    }
}

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    /// The order the repeat button cycles through, as in the Mac's Music app.
    public var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// What plays, in what order, and what plays next. Every edit returns a new queue.
///
/// Navigation follows upstream (Media3): repeat one replays a track only when it ends by itself;
/// skipping moves on as if repeat were off. Shuffle reorders the queue with the current track first,
/// and turning it off restores the order tracks were added in.
public struct PlaybackQueue: Sendable, Equatable {
    /// Entries in play order.
    public private(set) var items: [QueueItem]
    public private(set) var currentID: QueueItem.ID?
    public private(set) var isShuffled: Bool
    public private(set) var repeatMode: RepeatMode
    /// Entries in the order they were added, which turning shuffle off returns to.
    private var addedOrder: [QueueItem]

    public init(songs: [Song] = [], startingAt index: Int = 0, repeatMode: RepeatMode = .off) {
        let items = songs.map { QueueItem(song: $0) }
        self.items = items
        addedOrder = items
        currentID = items.indices.contains(index) ? items[index].id : items.first?.id
        isShuffled = false
        self.repeatMode = repeatMode
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    public var current: QueueItem? {
        currentIndex.map { items[$0] }
    }

    /// The current entry's position in `items`.
    public var currentIndex: Int? {
        currentID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    // MARK: Navigation

    /// The entry after the current one, or nil at the end of the queue.
    /// - Parameter afterTrackEnded: true when the current track finished by itself, false for a skip.
    public func nextItem(afterTrackEnded: Bool) -> QueueItem? {
        guard let index = currentIndex else { return nil }
        if afterTrackEnded, repeatMode == .one {
            return items[index]
        }
        if items.indices.contains(index + 1) {
            return items[index + 1]
        }
        return repeatMode == .all ? items.first : nil
    }

    /// The entry before the current one, or nil at the start of the queue.
    public func previousItem() -> QueueItem? {
        guard let index = currentIndex else { return nil }
        if index > 0 {
            return items[index - 1]
        }
        return repeatMode == .all ? items.last : nil
    }

    /// The queue with `id` as the current entry, or unchanged if there is no such entry.
    public func repeating(_ mode: RepeatMode) -> Self {
        var copy = self
        copy.repeatMode = mode
        return copy
    }

    public func selecting(_ id: QueueItem.ID) -> Self {
        guard items.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.currentID = id
        return copy
    }

    // MARK: Edits

    /// Inserts `songs` right after the current track, in the given order.
    public func insertingNext(_ songs: [Song]) -> Self {
        let added = songs.map { QueueItem(song: $0) }
        var copy = self
        copy.items.insert(contentsOf: added, at: currentIndex.map { $0 + 1 } ?? items.endIndex)
        let addedPosition = currentID.flatMap { id in addedOrder.firstIndex { $0.id == id } }
        copy.addedOrder.insert(contentsOf: added, at: addedPosition.map { $0 + 1 } ?? addedOrder.endIndex)
        return copy.startingIfIdle(with: added)
    }

    /// Adds `songs` at the end of the queue.
    public func appending(_ songs: [Song]) -> Self {
        let added = songs.map { QueueItem(song: $0) }
        var copy = self
        copy.items += added
        copy.addedOrder += added
        return copy.startingIfIdle(with: added)
    }

    /// Removes an entry. The current entry can't be removed, as upstream: skip it first.
    public func removing(_ id: QueueItem.ID) -> Self {
        guard id != currentID else { return self }
        var copy = self
        copy.items.removeAll { $0.id == id }
        copy.addedOrder.removeAll { $0.id == id }
        return copy
    }

    /// Moves an entry to `destination` in play order (clamped to the queue).
    public func moving(_ id: QueueItem.ID, to destination: Int) -> Self {
        guard let source = items.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        let item = copy.items.remove(at: source)
        copy.items.insert(item, at: min(max(0, destination), copy.items.endIndex))
        if !isShuffled {
            copy.addedOrder = copy.items
        }
        return copy
    }

    /// Plays every entry in random order, starting with the current one.
    public func shuffled(using generator: inout some RandomNumberGenerator) -> Self {
        guard let current else { return self }
        var copy = self
        copy.items = [current] + items.filter { $0.id != current.id }.shuffled(using: &generator)
        copy.isShuffled = true
        return copy
    }

    /// Returns to the order entries were added in. The current entry stays current.
    public func unshuffled() -> Self {
        var copy = self
        copy.items = addedOrder
        copy.isShuffled = false
        return copy
    }

    /// Shuffles only the entries after the current one, for good (upstream's "Shuffle upcoming").
    public func shufflingUpcoming(using generator: inout some RandomNumberGenerator) -> Self {
        guard let index = currentIndex else { return self }
        var copy = self
        copy.items = Array(items[...index]) + items[(index + 1)...].shuffled(using: &generator)
        copy.addedOrder = copy.items
        copy.isShuffled = false
        return copy
    }

    private func startingIfIdle(with added: [QueueItem]) -> Self {
        guard currentID == nil, let first = added.first else { return self }
        var copy = self
        copy.currentID = first.id
        return copy
    }
}
