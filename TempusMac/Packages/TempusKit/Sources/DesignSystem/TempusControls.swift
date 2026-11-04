import SwiftUI

public extension EnvironmentValues {
    /// The point size of Tempus icons. Asset images don't follow `.font` the way SF Symbols do,
    /// so controls set this where they would set a symbol's font size.
    @Entry var tempusIconSize: CGFloat = TempusIconImage.defaultSize
}

public extension EnvironmentValues {
    /// The color icons are drawn in, or nil to draw them in the foreground style like text.
    @Entry var tempusIconColor: Color?
    /// True where an icon's own foreground style carries meaning (an error, a toggle that's off,
    /// a drag handle), so `tempusIconColor` doesn't replace it.
    @Entry var tempusIconKeepsForeground = false
}

public extension View {
    func tempusIconSize(_ size: CGFloat) -> some View {
        environment(\.tempusIconSize, size)
    }

    /// Draws icons inside this view in `color`; nil leaves them in the foreground style.
    func tempusIconColor(_ color: Color?) -> some View {
        environment(\.tempusIconColor, color)
    }

    /// Keeps icons inside this view in the foreground style set on them, whatever
    /// `tempusIconColor` says. Use it where the icon's color means something.
    func tempusIconKeepsForeground(_ keeps: Bool = true) -> some View {
        environment(\.tempusIconKeepsForeground, keeps)
    }

    /// Applies `tempusIconColor` to an image that isn't a `TempusIconImage`, such as an SF Symbol.
    func tempusIconTinted() -> some View {
        modifier(TempusIconTint())
    }
}

/// `tempusIconColor`, unless the icon keeps its foreground or sits in a disabled control, where
/// the system's dimmed style must show that it can't be used.
private struct TempusIconTint: ViewModifier {
    @Environment(\.tempusIconColor) private var color
    @Environment(\.tempusIconKeepsForeground) private var keepsForeground
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if let color, !keepsForeground, isEnabled {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

/// One of upstream's icons at the environment's `tempusIconSize`, in `tempusIconColor` when the
/// theme sets one and the foreground style otherwise.
public struct TempusIconImage: View {
    /// About the size of a body-text SF Symbol.
    public nonisolated static let defaultSize: CGFloat = 16

    private let icon: TempusIcon
    private let accessibilityName: Text?
    @Environment(\.tempusIconSize) private var size

    /// - Parameter accessibilityName: what VoiceOver says for the icon. Leave it out for an icon
    ///   that only decorates text beside it.
    public init(_ icon: TempusIcon, accessibilityName: Text? = nil) {
        self.icon = icon
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .tempusIconTinted()
    }

    /// A decorative image ignores a label added later, so a named icon is built with its label.
    private var image: Image {
        if let accessibilityName {
            Image(icon.rawValue, bundle: .module, label: accessibilityName)
        } else {
            Image(tempus: icon)
        }
    }
}

// The initializers below mirror SwiftUI's `systemImage:` ones, so a call site swaps
// `systemImage: "forward.fill"` for `tempus: .skipNext`.

public extension Label where Title == Text, Icon == TempusIconImage {
    /// The icon is decorative: the label's visible title names it.
    init(_ titleKey: LocalizedStringKey, tempus icon: TempusIcon) {
        self.init { Text(titleKey) } icon: { TempusIconImage(icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, tempus icon: TempusIcon) {
        self.init { Text(title) } icon: { TempusIconImage(icon) }
    }
}

/// A control's label, named for VoiceOver exactly once in either label style. SwiftUI names an
/// icon-only label from its title only for SF Symbol icons, and a label added to the whole
/// `Label` doesn't survive the icon-only style. So the icon carries the name, and the visible
/// title is hidden from VoiceOver so it isn't read twice.
public typealias TempusControlLabel = Label<ModifiedContent<Text, AccessibilityAttachmentModifier>, TempusIconImage>

private extension Label where Title == ModifiedContent<Text, AccessibilityAttachmentModifier>, Icon == TempusIconImage {
    init(control title: Text, tempus icon: TempusIcon) {
        self.init { title.accessibilityHidden(true) } icon: { TempusIconImage(icon, accessibilityName: title) }
    }
}

public extension Button where Label == TempusControlLabel {
    init(_ titleKey: LocalizedStringKey, tempus icon: TempusIcon, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { SwiftUI.Label(control: Text(titleKey), tempus: icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, tempus icon: TempusIcon, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { SwiftUI.Label(control: Text(title), tempus: icon) }
    }
}

public extension Menu where Label == TempusControlLabel {
    init(_ titleKey: LocalizedStringKey, tempus icon: TempusIcon, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(control: Text(titleKey), tempus: icon) }
    }
}
