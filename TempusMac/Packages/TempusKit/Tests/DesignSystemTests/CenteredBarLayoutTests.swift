import CoreGraphics
@testable import DesignSystem
import Testing

@Suite("Centered bar layout")
struct CenteredBarLayoutTests {
    let layout = CenteredBarLayout(spacing: 16, middleShare: 0.45, middleWidths: 280 ... 520)

    @Test
    func `a wide bar caps the middle and gives the rest to the sides`() {
        let columns = layout.columns(width: 1200, middleMinimum: 0, trailingMinimum: 100)
        #expect(columns == .init(side: 324, middle: 520))
    }

    @Test
    func `a narrower bar shrinks the middle with it, so the sides keep room for the titles`() {
        let columns = layout.columns(width: 700, middleMinimum: 0, trailingMinimum: 100)
        #expect(columns == .init(side: 176.5, middle: 315))
    }

    @Test
    func `the narrowest bar the window allows still leaves room for the titles`() {
        // A 900 pt window less the 200 pt sidebar and the bar's 16 pt padding on each side.
        let columns = layout.columns(width: 668, middleMinimum: 190, trailingMinimum: 90)
        #expect(columns.middle == 300.6)
        #expect(columns.side == 167.7)
    }

    @Test
    func `the middle never shrinks below its floor`() {
        let columns = layout.columns(width: 500, middleMinimum: 0, trailingMinimum: 50)
        #expect(columns.middle == 280)
        #expect(columns.side == 94)
    }

    @Test
    func `the middle never shrinks below what its content needs`() {
        let columns = layout.columns(width: 700, middleMinimum: 330, trailingMinimum: 100)
        #expect(columns.middle == 330)
        #expect(columns.side == 169)
    }

    @Test
    func `the middle gives way so the trailing buttons fit`() {
        let columns = layout.columns(width: 700, middleMinimum: 0, trailingMinimum: 190)
        #expect(columns == .init(side: 190, middle: 288))
    }

    @Test(arguments: [600.0, 700, 900, 1100, 1600])
    func `both sides are equal, so the middle is centered`(width: CGFloat) {
        let columns = layout.columns(width: width, middleMinimum: 0, trailingMinimum: 100)
        #expect(2 * columns.side + columns.middle + 2 * 16 == width)
    }

    @Test
    func `a bar too small for anything gives the sides nothing rather than a negative width`() {
        let columns = layout.columns(width: 100, middleMinimum: 0, trailingMinimum: 100)
        #expect(columns.side == 0)
        #expect(columns.middle == 280)
    }
}
