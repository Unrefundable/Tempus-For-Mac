import DesignSystem
import Testing

@Suite("RowSelection")
struct RowSelectionTests {
    @Test("a plain click selects only that row")
    func plainClickSelectsOnlyThatRow() {
        let selection = RowSelection(rows: [1, 2], anchor: 1).clicking(4, modifiers: [])
        #expect(selection.rows == [4])
        #expect(selection.anchor == 4)
    }

    @Test("a command-click adds a row, and removes it the second time")
    func commandClickToggles() {
        let once = RowSelection(rows: [1], anchor: 1).clicking(3, modifiers: .command)
        #expect(once.rows == [1, 3])
        #expect(once.clicking(3, modifiers: .command).rows == [1])
    }

    @Test("a shift-click selects from the anchor to the row, either way")
    func shiftClickSelectsRange() {
        let down = RowSelection(rows: [2], anchor: 2).clicking(5, modifiers: .shift)
        #expect(down.rows == [2, 3, 4, 5])
        #expect(down.anchor == 2)
        let up = RowSelection(rows: [5], anchor: 5).clicking(3, modifiers: .shift)
        #expect(up.rows == [3, 4, 5])
    }

    @Test("a shift-click with nothing selected selects just that row")
    func shiftClickWithoutAnchor() {
        #expect(RowSelection().clicking(3, modifiers: .shift).rows == [3])
    }

    @Test("arrow keys move one row and stop at the ends", arguments: [
        (start: Int?.none, step: 1, expected: 0),
        (start: 0, step: 1, expected: 1),
        (start: 4, step: 1, expected: 4),
        (start: 0, step: -1, expected: 0),
        (start: Int?.none, step: -1, expected: 4),
    ])
    func arrowMoves(start: Int?, step: Int, expected: Int) {
        let selection = RowSelection(rows: start.map { [$0] } ?? [], anchor: start)
        let moved = selection.moving(by: step, count: 5)
        #expect(moved.rows == [expected])
        #expect(moved.anchor == expected)
    }

    @Test("arrow keys do nothing in an empty list")
    func arrowInEmptyList() {
        #expect(RowSelection().moving(by: 1, count: 0) == RowSelection())
    }

    @Test("the rows a menu or drag acts on are the selection when the row is in it")
    func targetRows() {
        let selection = RowSelection(rows: [3, 1], anchor: 1)
        #expect(selection.targets(for: 3) == [1, 3])
        #expect(selection.targets(for: 2) == [2])
    }
}
