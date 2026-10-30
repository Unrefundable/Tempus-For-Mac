import Foundation
@testable import SubsonicAPI
import Synchronization
import Testing

/// Which addresses answer, and which were probed, in order.
private final class FakeNetwork: Sendable {
    private let state = Mutex<(reachable: Set<URL>, probes: [URL])>(([], []))

    func setReachable(_ addresses: ServerAddress...) {
        state.withLock { $0.reachable = Set(addresses.map(\.url)) }
    }

    var probes: [URL] {
        state.withLock { $0.probes }
    }

    func isReachable(_ address: ServerAddress) async -> Bool {
        await Task.yield() // a real probe suspends; give concurrent callers the chance to interleave
        return state.withLock {
            $0.probes.append(address.url)
            return $0.reachable.contains(address.url)
        }
    }
}

private final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))

    var now: Date {
        current.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Mirrors upstream MainActivity.pingServer / probeLocalAddress.
@Suite("Home and away address switching")
struct AddressSwitcherTests {
    let publicAddress: ServerAddress
    let localAddress: ServerAddress
    private let network = FakeNetwork()
    private let clock = TestClock()

    init() throws {
        publicAddress = try ServerAddress("https://music.example.com")
        localAddress = try ServerAddress("http://192.168.1.5:4533")
    }

    private func switcher(local: ServerAddress?, inUse: ServerAddress? = nil) -> AddressSwitcher {
        AddressSwitcher(
            publicAddress: publicAddress,
            localAddress: local,
            inUse: inUse,
            isReachable: { [network] in await network.isReachable($0) },
            now: { [clock] in clock.now }
        )
    }

    @Test("Without a local address, the public address is used or reported unreachable")
    func publicOnly() async {
        let switcher = switcher(local: nil)

        network.setReachable(publicAddress)
        #expect(await switcher.refresh() == publicAddress)

        network.setReachable()
        #expect(await switcher.refresh() == nil)
    }

    @Test("On the public address, an answering local address is switched to")
    func movesToLocal() async {
        let switcher = switcher(local: localAddress)
        network.setReachable(publicAddress, localAddress)

        #expect(await switcher.refresh() == localAddress)
        #expect(await switcher.inUse == localAddress)
    }

    @Test("A silent local address is not probed again for 15 seconds")
    func localProbeCooldown() async {
        let switcher = switcher(local: localAddress)
        network.setReachable(publicAddress)

        #expect(await switcher.refresh() == publicAddress)
        clock.advance(by: 10)
        #expect(await switcher.refresh() == publicAddress)
        #expect(network.probes == [localAddress.url, publicAddress.url, publicAddress.url])

        network.setReachable(publicAddress, localAddress)
        clock.advance(by: 6)
        #expect(await switcher.refresh() == localAddress)
    }

    @Test("When the local address stops answering, the public address takes over")
    func fallsBackToPublic() async {
        let switcher = switcher(local: localAddress, inUse: localAddress)
        network.setReachable(publicAddress)

        #expect(await switcher.refresh() == publicAddress)
        #expect(await switcher.inUse == publicAddress)
        #expect(network.probes == [localAddress.url, publicAddress.url])
    }

    @Test("When both addresses are down, the server is unreachable")
    func bothDown() async {
        let switcher = switcher(local: localAddress, inUse: localAddress)
        network.setReachable()

        #expect(await switcher.refresh() == nil)
    }

    @Test("Identical local and public addresses never loop (upstream issue #242)")
    func identicalAddresses() async {
        let switcher = switcher(local: publicAddress, inUse: publicAddress)
        network.setReachable()

        #expect(await switcher.refresh() == nil)
        #expect(network.probes == [publicAddress.url])
    }

    @Test("A refresh after the previous one finished probes again")
    func laterRefreshProbesAgain() async {
        let switcher = switcher(local: localAddress, inUse: localAddress)
        network.setReachable(localAddress)

        _ = await switcher.refresh()
        _ = await switcher.refresh()

        #expect(network.probes == [localAddress.url, localAddress.url])
    }

    @Test("Concurrent refreshes share one probe")
    func coalescesRefreshes() async {
        let switcher = switcher(local: localAddress)
        network.setReachable(publicAddress, localAddress)

        async let first = switcher.refresh()
        async let second = switcher.refresh()
        let results = await [first, second]

        #expect(results == [localAddress, localAddress])
        #expect(network.probes == [localAddress.url])
    }
}
