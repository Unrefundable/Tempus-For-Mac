import CryptoKit
import Foundation
import Observation
import os
import Persistence
import Playback
import SubsonicAPI
import Synchronization

/// Background downloads into Application Support, the Downloads view's data, playlists kept
/// downloaded and offline starred tracks (Phase 8). Two files download at a time.
@MainActor
@Observable
public final class DownloadManager {
    static let concurrentDownloads = 2
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Downloads")

    public struct Source: Sendable, Hashable {
        public let playlistID: String
        public let playlistName: String

        public init(playlistID: String, playlistName: String) {
            self.playlistID = playlistID
            self.playlistName = playlistName
        }
    }

    private struct Job {
        let song: Song
        let source: Source?
    }

    /// Downloaded tracks by song id.
    public private(set) var records: [String: DownloadRecord] = [:]
    /// Songs downloading now.
    public private(set) var active: Set<String> = []
    /// Songs waiting their turn.
    public private(set) var waiting: [String] = []
    public private(set) var syncedPlaylists: [SyncedPlaylist] = []
    /// Why the last download failed. Safe to show.
    public private(set) var errorMessage: String?
    /// True while downloads wait for an unconstrained network.
    public private(set) var isHeldForNetwork = false

    public let index = DownloadIndex()

    @ObservationIgnored private let client: SubsonicClient
    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let syncedStore: SyncedPlaylistStore
    @ObservationIgnored private let serverID: String
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let downloader: any FileDownloading
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let streamSettings: @MainActor () -> StreamSettings
    @ObservationIgnored private let isOnConstrainedNetwork: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    /// Jobs wait until what's on disk is known, so loading can't drop a fresh download.
    @ObservationIgnored private var isLoaded = false
    /// Set when the session ends; nothing new starts after that.
    @ObservationIgnored private var isEnded = false

    init(
        client: SubsonicClient,
        database: AppDatabase,
        serverID: String,
        directory: URL,
        downloader: any FileDownloading,
        settings: AppSettings,
        streamSettings: @escaping @MainActor () -> StreamSettings,
        isOnConstrainedNetwork: @escaping @MainActor () -> Bool,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        store = DownloadStore(database: database)
        syncedStore = SyncedPlaylistStore(database: database)
        self.serverID = serverID
        self.directory = directory.appending(path: Self.safeName(serverID), directoryHint: .isDirectory)
        self.downloader = downloader
        self.settings = settings
        self.streamSettings = streamSettings
        self.isOnConstrainedNetwork = isOnConstrainedNetwork
        self.now = now
    }

    // MARK: Reading

    public var downloads: [DownloadRecord] {
        Array(records.values)
    }

    public func isDownloaded(_ songID: String) -> Bool {
        records[songID] != nil
    }

    public func isPending(_ songID: String) -> Bool {
        active.contains(songID) || waiting.contains(songID)
    }

    public var totalBytes: Int64 {
        records.values.reduce(0) { $0 + $1.size }
    }

    public func isKeptSynced(_ playlistID: String) -> Bool {
        syncedPlaylists.contains { $0.id == playlistID }
    }

    /// Loads what is on disk. Rows whose file has gone are dropped, and so are files with no row.
    func load() async {
        do {
            let stored = try await store.all(server: serverID)
            var kept: [String: DownloadRecord] = [:]
            var missing: [String] = []
            for record in stored {
                if FileManager.default.fileExists(atPath: fileURL(record.fileName).path) {
                    kept[record.song.id] = record
                } else {
                    missing.append(record.song.id)
                }
            }
            try await store.delete(songIDs: missing, server: serverID)
            records = kept
            index.replaceAll(kept.mapValues { fileURL($0.fileName) })
            removeStrayFiles(keeping: Set(kept.values.map(\.fileName)))
            syncedPlaylists = try await syncedStore.all(server: serverID)
        } catch {
            Self.logger.error("Couldn't load downloads: \(error)")
        }
        isLoaded = true
        pump()
    }

    // MARK: Downloading

    /// Queues songs not on disk yet. Radio and podcast episodes the server hasn't fetched are skipped.
    public func download(_ songs: [Song], from source: Source? = nil) {
        guard !isEnded else { return }
        for song in songs where song.type != RadioStation.songType && song.isDir != true {
            guard !isDownloaded(song.id), !isPending(song.id) else { continue }
            jobs.append(Job(song: song, source: source))
            waiting.append(song.id)
        }
        pump()
    }

    /// Starts waiting jobs while there is room, unless the network is constrained and the user
    /// asked to wait for a better one.
    public func pump() {
        guard isLoaded, !isEnded else { return }
        isHeldForNetwork = settings.downloadsOnlyUnconstrained && isOnConstrainedNetwork() && !jobs.isEmpty
        guard !isHeldForNetwork else { return }
        while running.count < Self.concurrentDownloads, !jobs.isEmpty {
            let job = jobs.removeFirst()
            waiting.removeAll { $0 == job.song.id }
            active.insert(job.song.id)
            running[job.song.id] = Task { [weak self] in
                await self?.run(job)
            }
        }
    }

    /// Waits until nothing is downloading or waiting (or downloads are held for the network).
    func settled() async {
        while let task = running.values.first {
            await task.value
        }
    }

    /// The session ended: stop, and start nothing new.
    func end() {
        isEnded = true
        cancelAll()
    }

    /// Stops everything waiting or downloading.
    public func cancelAll() {
        jobs.removeAll()
        waiting.removeAll()
        for task in running.values {
            task.cancel()
        }
    }

    private func run(_ job: Job) async {
        defer {
            active.remove(job.song.id)
            running[job.song.id] = nil
            pump()
        }
        do {
            let record = try await fetch(job)
            try await store.save(record, server: serverID)
            records[job.song.id] = record
            index.set(fileURL(record.fileName), forSong: job.song.id)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return // Stop, or the session ended
        } catch let error as SubsonicError {
            errorMessage = "Couldn't download “\(job.song.title ?? "a track")”: \(error.userMessage)"
        } catch {
            // Only the code: a URLError's description holds the credentialed URL.
            let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
            Self.logger.error("Download failed with code \(code)")
            errorMessage = "Couldn't download “\(job.song.title ?? "a track")”."
        }
    }

    private func fetch(_ job: Job) async throws -> DownloadRecord {
        let song = job.song
        let (url, suffix) = try remoteFile(for: song)
        var request = URLRequest(url: url, timeoutInterval: 60)
        for (name, value) in client.mediaRequestPolicy.headers(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (temporary, response) = try await downloader.download(request, policy: client.mediaRequestPolicy)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try Self.validate(response, file: temporary)

        try Self.prepare(directory)
        let name = "\(Self.safeName(song.id)).\(suffix)"
        let destination = fileURL(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        return DownloadRecord(
            song: song, fileName: name, size: size,
            playlistID: job.source?.playlistID, playlistName: job.source?.playlistName,
            downloadedAt: now()
        )
    }

    /// The original file, or the stream in the chosen quality when downloads are transcoded.
    private func remoteFile(for song: Song) throws(SubsonicError) -> (URL, String) {
        guard settings.transcodesDownloads else {
            return try (client.downloadURL(id: song.id), Self.safeSuffix(song.suffix))
        }
        let quality = streamSettings().quality(for: song, onConstrainedNetwork: false)
        let suffix: String? = switch quality {
        case let .transcoded(format, _): format
        case .serverDefault: song.transcodedSuffix ?? song.suffix
        case .original: song.suffix
        }
        return try (client.streamURL(id: song.id, quality: quality), Self.safeSuffix(suffix))
    }

    /// A Subsonic error arrives as a 200 with a JSON or XML body instead of audio.
    static func validate(_ response: URLResponse, file: URL) throws {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw SubsonicError.httpStatus(http.statusCode)
        }
        let type = (response.mimeType ?? "").lowercased()
        guard type.contains("json") || type.contains("xml") else { return }
        let data = (try? Data(contentsOf: file)) ?? Data()
        if case let .failure(error) = Result(catching: { try SubsonicClient.decode(.ping, from: data) }),
           let subsonic = error as? SubsonicError
        {
            throw subsonic
        }
        throw SubsonicError.decoding("Expected audio, got \(type)")
    }

    // MARK: Removing

    public func delete(_ songIDs: [String]) async {
        let files = songIDs.compactMap { records[$0]?.fileName }
        do {
            try await store.delete(songIDs: songIDs, server: serverID)
        } catch {
            errorMessage = "Couldn't remove the downloads."
            return
        }
        for id in songIDs {
            records[id] = nil
            index.set(nil, forSong: id)
        }
        for name in files {
            try? FileManager.default.removeItem(at: fileURL(name))
        }
    }

    public func deleteAll() async {
        cancelAll()
        await delete(Array(records.keys))
    }

    // MARK: Kept-synced playlists and starred tracks

    /// Turns "Keep synced" on (downloading every missing track now) or off (keeping the files).
    public func setKeepsSynced(_ keeps: Bool, playlist: Playlist) async {
        do {
            if keeps {
                let synced = SyncedPlaylist(id: playlist.id, name: playlist.name ?? "Playlist")
                try await syncedStore.add(synced, server: serverID)
                syncedPlaylists = try await syncedStore.all(server: serverID)
                await sync(synced)
            } else {
                try await syncedStore.remove(playlist.id, server: serverID)
                syncedPlaylists = try await syncedStore.all(server: serverID)
            }
        } catch {
            Self.logger.error("Couldn't change a synced playlist: \(error)")
            errorMessage = "Couldn't change Keep Synced."
        }
    }

    /// Downloads tracks added to kept-synced playlists, and starred tracks when that's on. Runs at
    /// sign-in. Removed tracks stay downloaded, as upstream.
    func syncAll() async {
        for playlist in syncedPlaylists {
            await sync(playlist)
        }
        guard settings.syncsStarredTracks else { return }
        do throws(SubsonicError) {
            let starred = try await client.send(.starred(musicFolderID: nil))
            download(starred.songs)
        } catch {
            Self.logger.notice("Couldn't sync starred tracks: \(error.userMessage, privacy: .public)")
        }
    }

    /// Fetches one kept-synced playlist and queues what isn't on disk yet.
    public func sync(_ playlist: SyncedPlaylist) async {
        do throws(SubsonicError) {
            let fresh = try await client.send(.playlist(id: playlist.id))
            guard !Task.isCancelled else { return }
            download(fresh.entries, from: Source(playlistID: playlist.id, playlistName: fresh.name ?? playlist.name))
        } catch {
            Self.logger.notice("Couldn't sync a playlist: \(error.userMessage, privacy: .public)")
        }
    }

    // MARK: Files

    /// Creates the folder, kept out of Time Machine: the files can be downloaded again.
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Deletes a server's downloaded files, when the server itself is deleted.
    static func removeFiles(forServer serverID: String, in root: URL) {
        try? FileManager.default.removeItem(at: root.appending(path: safeName(serverID), directoryHint: .isDirectory))
    }

    private func fileURL(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    private func removeStrayFiles(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where !names.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: fileURL(name))
        }
    }

    /// Ids are server data; only plain ones become file names, others are hashed.
    static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if !id.isEmpty, id.count <= 100, id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) {
            return id
        }
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func safeSuffix(_ suffix: String?) -> String {
        guard let suffix = suffix?.lowercased(), (1 ... 8).contains(suffix.count),
              suffix.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return "audio" }
        return suffix
    }
}
