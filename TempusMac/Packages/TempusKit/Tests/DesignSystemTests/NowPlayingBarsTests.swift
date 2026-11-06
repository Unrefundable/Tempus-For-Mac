import CoreGraphics
@testable import DesignSystem
import Foundation
import Testing

@Suite("Now playing bars")
struct NowPlayingBarsTests {
    @Test("Playing bars stay between the floor and full height", arguments: Array(stride(from: 0.0, to: 10, by: 0.37)))
    func levelsInRange(time: TimeInterval) {
        let levels = NowPlayingBars.levels(at: time)
        #expect(levels.count == 3)
        #expect(levels.allSatisfy { $0 >= NowPlayingBars.minimumLevel && $0 <= 1 })
    }

    @Test("The bars move over time")
    func levelsChange() {
        #expect(NowPlayingBars.levels(at: 0) != NowPlayingBars.levels(at: 0.25))
    }

    @Test("Bars stand on the icon's baseline, side by side, as in ic_eq")
    func barGeometry() {
        let size = CGSize(width: 24, height: 24)
        let full = NowPlayingBars.barRect(index: 1, level: 1, in: size)
        #expect(full == CGRect(x: 10, y: 4, width: 4, height: 16))

        let first = NowPlayingBars.barRect(index: 0, level: 0.5, in: size)
        #expect(first == CGRect(x: 4, y: 12, width: 4, height: 8))

        let last = NowPlayingBars.barRect(index: 2, level: 2, in: size)
        #expect(last.maxX == 20)
        #expect(last.height == 16)
    }
}
