@testable import AppCore
import Foundation
import SubsonicAPI
import Testing

struct ArtworkPipelineTests {
    let client: SubsonicClient

    init() throws {
        client = try SubsonicClient(
            server: ServerAddress(TestData.address),
            auth: SubsonicAuth(username: "alice", credential: .tokenized(password: "pw")),
            headers: CustomHeaders(parsing: "X-Token: abc")
        )
    }

    @Test
    func `requests are keyed by server, cover and size, never by the credentialed URL`() throws {
        let artwork = ArtworkPipeline(client: client, serverID: "s1", caches: .inMemory)
        let request = try #require(artwork.request(coverArtID: "al-1", size: .thumbnail))

        #expect(request.imageID == "s1/al-1/160")
        let url = try #require(request.urlRequest?.url)
        #expect(url.query()?.contains("size=160") == true)
        #expect(url.query()?.contains("id=al-1") == true)
        #expect(request.urlRequest?.value(forHTTPHeaderField: "X-Token") == "abc")
    }

    @Test
    func `the original size has its own key and no size parameter`() throws {
        let artwork = ArtworkPipeline(client: client, serverID: "s1", caches: .inMemory)
        let request = try #require(artwork.request(coverArtID: "al-1", size: .original))
        #expect(request.imageID == "s1/al-1/original")
        #expect(request.urlRequest?.url?.query()?.contains("size=") == false)
    }

    @Test
    func `no cover means no request`() {
        let artwork = ArtworkPipeline(client: client, serverID: "s1", caches: .inMemory)
        #expect(artwork.request(coverArtID: nil, size: .thumbnail) == nil)
        #expect(artwork.request(coverArtID: "", size: .thumbnail) == nil)
    }

    @Test
    func `redirects off the server drop the custom headers`() async throws {
        let delegate = ArtworkSessionDelegate(policy: client.mediaRequestPolicy)
        var redirect = try URLRequest(url: #require(URL(string: "https://cdn.example.net/cover.jpg")))
        redirect.setValue("abc", forHTTPHeaderField: "X-Token")
        redirect.setValue("image/*", forHTTPHeaderField: "Accept")

        let followed = await withCheckedContinuation { continuation in
            delegate.urlSession(
                URLSession.shared,
                task: URLSession.shared.dataTask(with: redirect),
                willPerformHTTPRedirection: HTTPURLResponse(),
                newRequest: redirect
            ) { continuation.resume(returning: $0) }
        }

        #expect(followed?.value(forHTTPHeaderField: "X-Token") == nil)
        #expect(followed?.value(forHTTPHeaderField: "Accept") == "image/*")
    }

    @Test
    func `the image session keeps nothing on disk`() {
        let configuration = ArtworkPipeline.sessionConfiguration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
    }
}
