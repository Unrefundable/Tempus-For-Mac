import AppCore
import DesignSystem
import SwiftUI

/// Settings' Appearance tab: a theme preset, light or dark, and a hex code for every color.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    private static let presetColumns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.medium)]

    var body: some View {
        let settings = model.settings
        let theme = settings.theme
        Form {
            Section {
                LazyVGrid(columns: Self.presetColumns, spacing: Theme.Spacing.medium) {
                    ForEach(ThemePreset.allCases) { preset in
                        PresetCard(preset: preset, isSelected: theme.preset == preset) {
                            settings.setTheme(settings.theme.applying(preset))
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xSmall)
                Picker("Appearance", selection: Binding(
                    get: { theme.appearance },
                    set: { settings.setTheme(settings.theme.setting(appearance: $0)) }
                )) {
                    ForEach(ThemeAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            } footer: {
                Text("""
                Choosing a theme replaces the colors below. Each theme has light and dark colors, so it \
                stays readable whichever appearance you pick.
                """)
                .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            }
            Section {
                ForEach(ThemeColorRole.allCases) { role in
                    ThemeColorRow(role: role, theme: theme) { color in
                        settings.setTheme(settings.theme.setting(role, to: color))
                    }
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("""
                Type a hex code such as #1E90FF, or #1E90FF80 to make it see-through, or click a swatch \
                to pick one. Clear a field to go back to the theme's color. Selected rows keep the \
                highlight color from System Settings.
                """)
                .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            }
            Section {
                Button("Reset to \(theme.preset.title)") { settings.setTheme(theme.applying(theme.preset)) }
                    .disabled(!theme.isCustomized)
            }
        }
        .formStyle(.grouped)
    }
}

/// A preset's name under a small picture of a window in its colors.
private struct PresetCard: View {
    let preset: ThemePreset
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let cornerRadius: CGFloat = 8
    private static let previewHeight: CGFloat = 56

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: Theme.Spacing.xSmall) {
                ThemePreview(theme: AppTheme(preset: preset))
                    .environment(\.colorScheme, scheme)
                    .frame(height: Self.previewHeight)
                    .clipShape(.rect(cornerRadius: Self.cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(
                                isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.separator),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                Text(preset.title)
                    .font(.inter(.caption, weight: isSelected ? .semibold : .regular))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.tempusPlain)
        .accessibilityLabel("\(preset.title) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var scheme: ColorScheme {
        switch preset.appearance {
        case .system: colorScheme
        case .light, .dark: preset.variant == .light ? .light : .dark
        }
    }
}

/// A sidebar, two lines of text and an accent dot, in `theme`'s colors or the system's.
private struct ThemePreview: View {
    let theme: AppTheme

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            color(.sidebar).frame(width: 20)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Capsule().fill(color(.primaryText)).frame(width: 36, height: 4)
                Capsule().fill(color(.secondaryText)).frame(width: 26, height: 4)
                Spacer(minLength: 0)
                HStack(spacing: Theme.Spacing.xSmall) {
                    Circle().fill(color(.accent)).frame(width: 8, height: 8)
                    Capsule().fill(color(.tertiaryText)).frame(height: 3)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(color(.background))
        }
        .accessibilityHidden(true)
    }

    private func color(_ role: ThemeColorRole) -> Color {
        theme.color(for: role, in: ThemeVariant(colorScheme)).map(Color.init) ?? .system(role)
    }
}

/// One color: its hex code to type, a swatch that opens the color picker, and a reset.
private struct ThemeColorRow: View {
    let role: ThemeColorRole
    let theme: AppTheme
    /// Nil goes back to the preset's color.
    let onChange: (ThemeColor?) -> Void

    @State private var draft = ""
    @State private var isInvalid = false
    @FocusState private var isEditing: Bool
    /// The color being dragged in the color panel, saved once the dragging pauses.
    @State private var picking: ThemeColor?
    @State private var pickTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private static let fieldWidth: CGFloat = 104
    /// How long the color panel must rest before its color is saved and the app redrawn.
    private static let pickDelay = Duration.milliseconds(200)

    var body: some View {
        let current = currentColor
        let isCustom = theme.customColors[role] != nil
        LabeledContent {
            HStack(spacing: Theme.Spacing.small) {
                TextField("Hex code", text: $draft, prompt: Text("System"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: Self.fieldWidth)
                    .focused($isEditing)
                    .onSubmit(commit)
                    .overlay {
                        if isInvalid {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.error, lineWidth: 1.5)
                        }
                    }
                    .help(isInvalid ? "Use a hex code: #RGB, #RRGGBB or #RRGGBBAA" : "")
                    .accessibilityLabel("\(role.title) hex code")
                ColorPicker(role.title, selection: Binding(
                    get: { picking.map(Color.init) ?? current.map(Color.init) ?? .system(role) },
                    set: { picked in pick(ThemeColor(picked)) }
                ), supportsOpacity: true)
                    .labelsHidden()
                Button("Use the Theme's \(role.title) Color", systemImage: "arrow.uturn.backward") { onChange(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.tempusBorderless)
                    .disabled(!isCustom)
                    .help("Use the theme's color")
            }
        } label: {
            Text(role.title)
            Text(role.summary)
        }
        .onAppear(perform: showCurrent)
        .onChange(of: current) {
            if !isEditing {
                showCurrent()
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                commit()
            }
        }
    }

    /// Shows `color` in the swatch and field at once, and saves it when the dragging pauses.
    private func pick(_ color: ThemeColor?) {
        guard let color else { return }
        picking = color
        draft = color.hex
        isInvalid = false
        pickTask?.cancel()
        pickTask = Task {
            do {
                try await Task.sleep(for: Self.pickDelay)
            } catch {
                return
            }
            picking = nil
            if color != currentColor {
                onChange(color)
            }
        }
    }

    /// The color showing now: the user's, else the preset's for the appearance in use.
    private var currentColor: ThemeColor? {
        theme.color(for: role, in: ThemeVariant(colorScheme))
    }

    private func showCurrent() {
        draft = currentColor?.hex ?? ""
        isInvalid = false
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if theme.customColors[role] != nil {
                onChange(nil)
            }
            showCurrent()
            return
        }
        guard let color = ThemeColor(hex: text) else {
            isInvalid = true
            return
        }
        isInvalid = false
        draft = color.hex
        if color != currentColor {
            onChange(color)
        }
    }
}
