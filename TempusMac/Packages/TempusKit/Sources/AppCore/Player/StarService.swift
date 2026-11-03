import Foundation
import Observation
import os
import Persistence
import SubsonicAPI

/// Stars (upstream's hearts) and ratings. A change shows at once; it is sent to the server, and if
/// the server can't be reached it is queued (upstream's `favorite` table) and sent at the next
/// sign-in. A change the server refuses is undone, with a message.
@MainActor
@Observable
public final class StarService {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Stars")

    /// Local changes over what the server last said.
    public private(set) var overrides: [StarTarget: Bool] = [:]
    public private(set) var ratings: [String: Int] = [:]
    /// Why the last change failed. Safe to show.
    public private(set) var errorMessage: String?
    /// Bumped after every change the server accepted, so starred lists reload.
    public private(set) var revision = 0

    @ObservationIgnored private let client: SubsonicClient
    @ObservationIgnored private let pending: PendingStarStore
    @ObservationIgnored private let serverID: String
    @ObservationIgnored private let now: @Sendable () -> Date

    init(client: SubsonicClient, pending: PendingStarStore, serverID: String, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.pending = pending
        self.serverID = serverID
        self.now = now
    }

    // MARK: Reading

    /// Whether the player's current entry can be starred: a track is playing, not a radio stream.
    public static func canStar(_ song: Song?) -> Bool {
        guard let song else { return false }
        return song.type != RadioStation.songType
    }

    public func isStarred(_ song: Song) -> Bool {
        overrides[.song(song.id)] ?? (song.starred != nil)
    }

    public func isStarred(_ album: Album) -> Bool {
        overrides[.album(album.id)] ?? (album.starred != nil)
    }

    public func isStarred(_ artist: Artist) -> Bool {
        overrides[.artist(artist.id)] ?? (artist.starred != nil)
    }

    public func rating(of song: Song) -> Int {
        ratings[song.id] ?? song.userRating ?? 0
    }

    // MARK: Changing

    public func toggle(_ song: Song) async {
        await setStarred(!isStarred(song), .song(song.id))
    }

    public func toggle(_ album: Album) async {
        await setStarred(!isStarred(album), .album(album.id))
    }

    public func toggle(_ artist: Artist) async {
        await setStarred(!isStarred(artist), .artist(artist.id))
    }

    public func setStarred(_ starred: Bool, _ target: StarTarget) async {
        let previous = overrides[target]
        overrides[target] = starred
        errorMessage = nil
        do throws(SubsonicError) {
            _ = try await client.send(Self.request(starred, target))
            revision += 1
        } catch where error.isAnswerFromServer {
            overrides[target] = previous
            errorMessage = error.userMessage
        } catch {
            // Offline: keep it and send it later.
            do {
                try await pending.enqueue(
                    PendingStar(target: target, isStarred: starred, createdAt: now()),
                    server: serverID
                )
            } catch {
                Self.logger.error("Couldn't queue a star: \(error)")
            }
        }
    }

    /// 0 removes the rating; 1–5 stars otherwise.
    public func setRating(_ rating: Int, for song: Song) async {
        let clamped = min(max(rating, 0), 5)
        let previous = ratings[song.id]
        ratings[song.id] = clamped
        errorMessage = nil
        do throws(SubsonicError) {
            _ = try await client.send(.setRating(id: song.id, rating: clamped))
        } catch {
            ratings[song.id] = previous
            errorMessage = error.userMessage
        }
    }

    /// Sends changes queued while offline, oldest first, and drops each one the server answered.
    func sendPending() async {
        let queued: [QueuedStar]
        do {
            queued = try await pending.pending(server: serverID)
        } catch {
            Self.logger.error("Couldn't read queued stars: \(error)")
            return
        }
        var sent: [Int64] = []
        for item in queued {
            do throws(SubsonicError) {
                _ = try await client.send(Self.request(item.change.isStarred, item.change.target))
                sent.append(item.id)
            } catch where error.isAnswerFromServer {
                sent.append(item.id) // refused for good; don't keep retrying
            } catch {
                break // still offline
            }
        }
        do {
            try await pending.remove(ids: sent)
        } catch {
            Self.logger.error("Couldn't clear sent stars: \(error)")
        }
        if !sent.isEmpty {
            revision += 1
        }
    }

    static func request(_ starred: Bool, _ target: StarTarget) -> SubsonicRequest<EmptyResponse> {
        let (songs, albums, artists): ([String], [String], [String]) = switch target {
        case let .song(id): ([id], [], [])
        case let .album(id): ([], [id], [])
        case let .artist(id): ([], [], [id])
        }
        return starred
            ? .star(songIDs: songs, albumIDs: albums, artistIDs: artists)
            : .unstar(songIDs: songs, albumIDs: albums, artistIDs: artists)
    }
}
