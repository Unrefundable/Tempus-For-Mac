import AppCore
import AppKit
import SwiftUI

public extension EnvironmentValues {
    /// The look chosen in Settings › Appearance.
    @Entry var appTheme: AppTheme = .default
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
        if let color = environment.appTheme.color(for: role) {
            return AnyShapeStyle(Color(color))
        }
        return switch role {
        case .accent: AnyShapeStyle(Color.accentColor)
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
}

private struct AppThemeModifier: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ThemeStyle(role: .primaryText))
            .tint(theme.color(for: .accent).map(Color.init))
            .environment(\.appTheme, theme)
            .onChange(of: theme.appearance, initial: true) { _, appearance in
                appearance.apply()
            }
    }
}

extension ThemeAppearance {
    /// Sets light or dark on the app rather than each window, so menus, the menu bar player and
    /// Settings follow too.
    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct ThemedBackground: ViewModifier {
    let role: ThemeColorRole
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        let color = theme.color(for: role)
        content
            .scrollContentBackground(color == nil ? .automatic : .hidden)
            .background(color.map(Color.init) ?? .clear)
    }
}
