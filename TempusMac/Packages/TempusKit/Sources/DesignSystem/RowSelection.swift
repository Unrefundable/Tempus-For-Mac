import SwiftUI

/// Which rows of a hand-built list are selected, with the Mac's clicks: a plain click picks one
/// row, ⌘ adds or removes one, ⇧ extends from the last plain click, and the arrow keys step.
public struct RowSelection: Equatable, Sendable {
    public private(set) var rows: Set<Int>
    /// The row a ⇧-click or arrow key extends from.
    public private(set) var anchor: Int?

    public init(rows: Set<Int> = [], anchor: Int? = nil) {
        self.rows = rows
        self.anchor = anchor
    }

    public func clicking(_ row: Int, modifiers: EventModifiers) -> RowSelection {
        if modifiers.contains(.command) {
            var toggled = rows
            if toggled.remove(row) == nil {
                toggled.insert(row)
            }
            return RowSelection(rows: toggled, anchor: row)
        }
        if modifiers.contains(.shift), let anchor {
            return RowSelection(rows: Set(min(anchor, row) ... max(anchor, row)), anchor: anchor)
        }
        return RowSelection(rows: [row], anchor: row)
    }

    /// One row up (`step` -1) or down (+1) among `count`, starting at an end with nothing selected.
    public func moving(by step: Int, count: Int) -> RowSelection {
        guard count > 0 else { return self }
        let target = anchor.map { $0 + step } ?? (step > 0 ? 0 : count - 1)
        let clamped = min(max(target, 0), count - 1)
        return RowSelection(rows: [clamped], anchor: clamped)
    }

    /// What a menu or drag on `row` acts on: the whole selection if it holds the row, else the row.
    public func targets(for row: Int) -> [Int] {
        rows.contains(row) ? rows.sorted() : [row]
    }
}
