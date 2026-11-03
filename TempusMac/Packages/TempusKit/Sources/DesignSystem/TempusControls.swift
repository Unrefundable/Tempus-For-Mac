import SwiftUI

public extension EnvironmentValues {
    /// The point size of Tempus icons. Asset images don't follow `.font` the way SF Symbols do,
    /// so controls set this where they would set a symbol's font size.
    @Entry var tempusIconSize: CGFloat = TempusIconImage.defaultSize
}

public extension View {
    func tempusIconSize(_ size: CGFloat) -> some View {
        environment(\.tempusIconSize, size)
    }
}

/// One of upstream's icons at the environment's `tempusIconSize`, tinted by the foreground style.
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
