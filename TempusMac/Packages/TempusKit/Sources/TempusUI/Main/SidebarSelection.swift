import AppCore
import AppKit
import SwiftUI

extension View {
    /// Draws the sidebar's open item in the theme's accent ("Accent and icons" in Settings ›
    /// Appearance) instead of the system's accent. With no accent set, the system's highlight stays.
    func themedSidebarSelection(isSelected: Bool) -> some View {
        modifier(ThemedSidebarSelection(isSelected: isSelected))
    }
}

private struct ThemedSidebarSelection: ViewModifier {
    /// Strong enough to see on any sidebar color, faint enough that the accent-colored icon and
    /// the text on it still read.
    private static let fillOpacity = 0.28
    private static let cornerRadius: CGFloat = 6
    /// The system highlight's inset from the sidebar's edges, so the themed one sits where it did.
    private static let horizontalInset: CGFloat = 10

    let isSelected: Bool

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let accent = theme.color(for: .accent, in: ThemeVariant(colorScheme)).map(Color.init)
        content
            .background(SourceListHighlightSwitch(hidesSystemHighlight: accent != nil))
            .listRowBackground(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(isSelected ? accent?.opacity(Self.fillOpacity) ?? .clear : .clear)
                    .padding(.horizontal, Self.horizontalInset)
            )
    }
}

/// Turns the sidebar table's own selection drawing off, or back on, from inside one of its rows.
/// SwiftUI draws a sidebar's selection in the system accent whatever the tint, so a themed
/// highlight needs AppKit's left out.
private struct SourceListHighlightSwitch: NSViewRepresentable {
    let hidesSystemHighlight: Bool

    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        view.hidesSystemHighlight = hidesSystemHighlight
        view.apply()
    }

    final class ProbeView: NSView {
        var hidesSystemHighlight = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil // never takes the row's clicks
        }

        func apply() {
            guard let table = enclosingTableView else { return }
            let style: NSTableView.SelectionHighlightStyle = hidesSystemHighlight ? .none : .sourceList
            if table.selectionHighlightStyle != style {
                table.selectionHighlightStyle = style
            }
        }

        private var enclosingTableView: NSTableView? {
            sequence(first: superview, next: { $0?.superview })
                .lazy
                .compactMap { $0 as? NSTableView }
                .first
        }
    }
}
