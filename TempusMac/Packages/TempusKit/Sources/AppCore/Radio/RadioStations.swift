import Foundation
import Persistence
import SubsonicAPI

/// A radio station from the server or kept on this Mac (upstream marks local ones LOCAL).
public struct RadioStation: Sendable, Hashable, Identifiable {
    public enum Origin: Sendable, Hashable {
        case server, local
    }

    /// The `type` of a queue entry that is a radio stream; never scrobbled or kept in history.
    public static let songType = "radio"

    public let id: String
    public let name: String
    public let streamURL: URL
    public let homePageURL: URL?
    public let coverArtURL: URL?
    public let origin: Origin

    public init(id: String, name: String, streamURL: URL, homePageURL: URL?, coverArtURL: URL?, origin: Origin) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homePageURL = homePageURL
        self.coverArtURL = coverArtURL
        self.origin = origin
    }

    init?(server station: InternetRadioStation) {
        guard let url = station.streamURL else { return nil }
        self.init(
            id: station.id, name: station.name ?? "Radio", streamURL: url,
            homePageURL: station.homePageURL, coverArtURL: nil, origin: .server
        )
    }

    init(local station: LocalRadioStation) {
        self.init(
            id: station.id, name: station.name, streamURL: station.streamURL,
            homePageURL: station.homePageURL, coverArtURL: station.coverArtURL, origin: .local
        )
    }

    /// The queue entry that plays it. Its stream address travels in `path`, which
    /// `SessionStreamSource` reads; it has no duration and no cover from the server.
    public var song: Song {
        Song(
            id: "radio-\(origin == .local ? "local-" : "")\(id)",
            title: name,
            album: origin == .local ? "Local radio" : "Internet radio",
            artist: streamURL.host(),
            type: Self.songType,
            path: streamURL.absoluteString
        )
    }

    /// Public `http` streams are refused by App Transport Security (ADR 0005).
    public var isCleartext: Bool {
        streamURL.scheme?.lowercased() == "http"
    }
}

/// The station form: name and stream address are required, the home page optional.
public struct RadioStationForm: Sendable, Equatable {
    public var name = ""
    public var streamAddress = ""
    public var homePageAddress = ""
    public var coverAddress = ""

    public init() {}

    public init(station: RadioStation) {
        name = station.name
        streamAddress = station.streamURL.absoluteString
        homePageAddress = station.homePageURL?.absoluteString ?? ""
        coverAddress = station.coverArtURL?.absoluteString ?? ""
    }

    public enum Problem: Error, Equatable, Sendable {
        case missingName, invalidStream, invalidHomePage

        public var message: String {
            switch self {
            case .missingName: "Enter the station's name."
            case .invalidStream: "Enter a stream address that starts with http:// or https://."
            case .invalidHomePage: "The home page must start with http:// or https://."
            }
        }
    }

    public struct Valid: Sendable, Equatable {
        public let name: String
        public let streamURL: URL
        public let homePageURL: URL?
        public let coverArtURL: URL?
    }

    public func validated() -> Result<Valid, Problem> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.missingName) }
        guard let stream = Self.webURL(streamAddress) else { return .failure(.invalidStream) }
        let homePage = Self.webURL(homePageAddress)
        if homePage == nil, !homePageAddress.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(.invalidHomePage)
        }
        return .success(Valid(
            name: name,
            streamURL: stream,
            homePageURL: homePage,
            coverArtURL: Self.webURL(coverAddress)
        ))
    }

    public static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }
}

/// Server and local stations together, with adding, editing and deleting in either place.
public struct RadioService: Sendable {
    let client: SubsonicClient
    let local: LocalRadioStore

    /// Server stations first, then local ones, each by name. A server without radio support
    /// (or offline) still lists the local stations; its error comes back alongside.
    public func stations() async -> (stations: [RadioStation], serverError: SubsonicError?) {
        var serverError: SubsonicError?
        var server: [RadioStation] = []
        do throws(SubsonicError) {
            server = try await client.send(.internetRadioStations).compactMap(RadioStation.init(server:))
        } catch {
            serverError = error
        }
        let locals = await ((try? local.all()) ?? []).map(RadioStation.init(local:))
        let byName: (RadioStation, RadioStation) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (server.sorted(by: byName) + locals.sorted(by: byName), serverError)
    }

    public func add(_ station: RadioStationForm.Valid, origin: RadioStation.Origin) async throws {
        switch origin {
        case .server:
            _ = try await client.send(.createInternetRadioStation(
                streamURL: station.streamURL, name: station.name, homePageURL: station.homePageURL
            ))
        case .local:
            try await local.save(LocalRadioStation(
                id: UUID().uuidString, name: station.name, streamURL: station.streamURL,
                homePageURL: station.homePageURL, coverArtURL: station.coverArtURL
            ))
        }
    }

    /// A station stays where it was saved; upstream can't move one between server and local.
    public func update(_ station: RadioStation, with form: RadioStationForm.Valid) async throws {
        switch station.origin {
        case .server:
            _ = try await client.send(.updateInternetRadioStation(
                id: station.id, streamURL: form.streamURL, name: form.name, homePageURL: form.homePageURL
            ))
        case .local:
            try await local.save(LocalRadioStation(
                id: station.id, name: form.name, streamURL: form.streamURL,
                homePageURL: form.homePageURL, coverArtURL: form.coverArtURL
            ))
        }
    }

    public func delete(_ station: RadioStation) async throws {
        switch station.origin {
        case .server: _ = try await client.send(.deleteInternetRadioStation(id: station.id))
        case .local: try await local.delete(id: station.id)
        }
    }
}

/// A station found on radio-browser.info, the public directory upstream searches.
public struct RadioBrowserStation: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let streamURL: URL?
    public let homePageURL: URL?
    public let faviconURL: URL?
    public let country: String?
    public let codec: String?
    public let bitrate: Int?
    public let votes: Int?

    private enum CodingKeys: String, CodingKey {
        case id = "stationuuid", name, streamURL = "url_resolved", url, homePageURL = "homepage"
        case faviconURL = "favicon", country, codec, bitrate, votes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Radio"
        let resolved = (try? container.decode(String.self, forKey: .streamURL)).flatMap(RadioStationForm.webURL)
        let plain = (try? container.decode(String.self, forKey: .url)).flatMap(RadioStationForm.webURL)
        streamURL = resolved ?? plain
        homePageURL = (try? container.decode(String.self, forKey: .homePageURL)).flatMap(RadioStationForm.webURL)
        faviconURL = (try? container.decode(String.self, forKey: .faviconURL)).flatMap(RadioStationForm.webURL)
        country = try? container.decode(String.self, forKey: .country)
        codec = try? container.decode(String.self, forKey: .codec)
        bitrate = try? container.decode(Int.self, forKey: .bitrate)
        votes = try? container.decode(Int.self, forKey: .votes)
    }

    /// Fills the station form, as upstream's **Use**.
    public var form: RadioStationForm {
        var form = RadioStationForm()
        form.name = name
        form.streamAddress = streamURL?.absoluteString ?? ""
        form.homePageAddress = homePageURL?.absoluteString ?? ""
        form.coverAddress = faviconURL?.absoluteString ?? ""
        return form
    }
}

/// Searches radio-browser.info by name, country or both: up to 30 stations, most voted first.
public struct RadioBrowser: Sendable {
    public static let resultLimit = 30
    static let endpoint = URL(string: "https://all.api.radio-browser.info/json/stations/search")
    /// The directory is public, but a runaway answer still shouldn't fill memory.
    static let maximumResponseSize = 2 * 1024 * 1024

    let transport: any HTTPTransport

    public init(transport: (any HTTPTransport)? = nil) {
        self.transport = transport ?? RadioBrowserTransport()
    }

    static func request(name: String, country: String) -> URLRequest? {
        guard let endpoint, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = [
            URLQueryItem(name: "limit", value: String(resultLimit)),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
            URLQueryItem(name: "hidebroken", value: "true"),
        ]
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = country.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: name))
        }
        if !country.isEmpty {
            items.append(URLQueryItem(name: "country", value: country))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Tempus-macOS", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func search(name: String, country: String) async throws -> [RadioBrowserStation] {
        guard let request = Self.request(name: name, country: country) else { throw URLError(.badURL) }
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard data.count <= Self.maximumResponseSize else { throw URLError(.dataLengthExceedsMaximum) }
        let stations = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
        return Array(stations.filter { $0.streamURL != nil }.prefix(Self.resultLimit))
    }
}

private struct RadioBrowserTransport: HTTPTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Self.session.data(for: request)
    }
}
