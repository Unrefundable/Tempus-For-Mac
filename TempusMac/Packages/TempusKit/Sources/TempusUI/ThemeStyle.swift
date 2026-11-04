import AppCore
import AppKit
import DesignSystem
import SwiftUI

public extension EnvironmentValues {
    /// The look chosen in Settings › Appearance.
    @Entry var appTheme: AppTheme = .default
}

extension EnvironmentValues {
    /// The theme's color for `role` in the appearance showing, or nil to use the system's.
    func themeColor(_ role: ThemeColorRole) -> ThemeColor? {
        appTheme.color(for: role, in: ThemeVariant(colorScheme))
    }
}

extension ThemeVariant {
    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

extension Color {
    init(_ color: ThemeColor) {
        let unit = color.unitComponents
        self.init(.sRGB, red: unit[0], green: unit[1], blue: unit[2], opacity: unit[3])
    }

    /// What `role` looks like when the theme leaves it to the system, for swatches and previews.
    static func system(_ role: ThemeColorRole) -> Color {
        switch role {
        case .accent: .accentColor
        case .icons: .primary
        case .background: Color(nsColor: .textBackgroundColor)
        case .sidebar: Color(nsColor: .underPageBackgroundColor)
        case .playerBar: Color(nsColor: .windowBackgroundColor)
        case .primaryText, .lyrics: .primary
        case .secondaryText: .secondary
        case .tertiaryText: Color(nsColor: .tertiaryLabelColor)
        case .error: .red
        case .success: .green
        }
    }
}

extension ThemeColor {
    /// `color` in sRGB, or nil when it can't be expressed there (a pattern, say).
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            unitRed: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: srgb.alphaComponent
        )
    }
}

/// One of the theme's colors, or the system style it stands in for when the theme leaves it unset,
/// so the default look keeps the system's adaptive colors and materials.
public struct ThemeStyle: ShapeStyle {
    let role: ThemeColorRole

    public func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if let color = environment.themeColor(role) {
            return AnyShapeStyle(Color(color))
        }
        return switch role {
        case .accent: AnyShapeStyle(Color.accentColor)
        // Icons take the foreground style when unset; see `tempusIconColor`.
        case .icons: AnyShapeStyle(.foreground)
        // Backgrounds are only drawn when set; see `themedBackground(_:)`.
        case .background, .sidebar: AnyShapeStyle(Color.clear)
        case .playerBar: AnyShapeStyle(.bar)
        case .primaryText, .lyrics: AnyShapeStyle(.primary)
        case .secondaryText: AnyShapeStyle(.secondary)
        case .tertiaryText: AnyShapeStyle(.tertiary)
        case .error: AnyShapeStyle(Color.red)
        case .success: AnyShapeStyle(Color.green)
        }
    }
}

extension View {
    /// Applies `theme` to a window's content: its colors, the accent controls use, the default
    /// text color and light or dark.
    func appTheme(_ theme: AppTheme) -> some View {
        modifier(AppThemeModifier(theme: theme))
    }

    /// Fills behind this view with the theme's `role` color, hiding lists' and tables' own
    /// backgrounds so it shows through. Unset, the system's background stays. The modifiers are
    /// the same either way, so changing the theme doesn't rebuild the view.
    func themedBackground(_ role: ThemeColorRole) -> some View {
        modifier(ThemedBackground(role: role))
    }

    /// Paints the window's toolbar in the theme's background color, when it sets one. AppKit
    /// otherwise draws the toolbar's own grey whenever no scroll view sits under it (an empty
    /// state, a header above a table, Now Playing), so the bar changed color from screen to screen.
    func themedToolbar() -> some View {
        modifier(ThemedToolbar())
    }
}

private struct AppThemeModifier: ViewModifier {
    let theme: AppTheme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let variant = ThemeVariant(colorScheme)
        content
            .foregroundStyle(ThemeStyle(role: .primaryText))
            .tint(theme.color(for: .accent, in: variant).map(Color.init))
            .tempusIconColor(theme.color(for: .icons, in: variant).map(Color.init))
            .environment(\.appTheme, theme)
            .onChange(of: theme.appearance, initial: true) { _, appearance in
                appearance.apply()
            }
    }
}

@MainActor
extension ThemeAppearance {
    /// Sets light or dark on the app rather than each window, so menus, the menu bar player and
    /// Settings follow too.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct ThemedToolbar: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let color = theme.color(for: .background, in: ThemeVariant(colorScheme))
        content
            .toolbarBackground(color.map(Color.init) ?? .clear, for: .windowToolbar)
            .toolbarBackgroundVisibility(color == nil ? .automatic : .visible, for: .windowToolbar)
    }
}

private struct ThemedBackground: ViewModifier {
    let role: ThemeColorRole
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let color = theme.color(for: role, in: ThemeVariant(colorScheme))
        content
            .scrollContentBackground(color == nil ? .automatic : .hidden)
            .background(color.map(Color.init) ?? .clear)
    }
}
