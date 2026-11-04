import DesignSystem
import Playback
import SwiftUI
import UniformTypeIdentifiers

struct EqualizerPane: View {
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NeedsPlayer { player in
            let equalizer = player.settings.equalizer
            Form {
                Picker("Equalizer", selection: Binding(
                    get: { equalizer.mode },
                    set: { mode in player.setEqualizer(Self.settings(equalizer, mode: mode)) }
                )) {
                    Text("Off").tag(EqualizerMode.off)
                    Text("10-band").tag(EqualizerMode.graphic)
                    Text("AutoEQ profile").tag(EqualizerMode.parametric)
                        .disabled(equalizer.parametric == nil)
                }
                .pickerStyle(.segmented)
                Section("10-band") {
                    HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
                        ForEach(
                            Array(EqualizerSettings.graphicFrequencies.enumerated()),
                            id: \.offset
                        ) { index, frequency in
                            VStack {
                                Text(String(format: "%+.0f", equalizer.graphicGains[index]))
                                    .font(.inter(.caption2)).monospacedDigit()
                                Slider(value: Binding(
                                    get: { equalizer.graphicGains[index] },
                                    set: { gain in
                                        var gains = equalizer.graphicGains
                                        gains[index] = gain.rounded()
                                        player.setEqualizer(EqualizerSettings(
                                            mode: .graphic, graphicGains: gains,
                                            parametric: equalizer.parametric, parametricName: equalizer.parametricName
                                        ))
                                    }
                                ), in: EqualizerSettings.graphicGainRange, step: 1)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 120, height: 24)
                                    .frame(width: 28, height: 120)
                                Text(Self.label(frequency)).font(.inter(.caption2))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Button("Reset") {
                        player.setEqualizer(EqualizerSettings(
                            mode: equalizer.mode, parametric: equalizer.parametric,
                            parametricName: equalizer.parametricName
                        ))
                    }
                }
                Section("AutoEQ") {
                    LabeledContent("Profile", value: equalizer.parametricName ?? "None")
                    Button("Import ParametricEQ.txt…") { isImporting = true }
                    if let importError {
                        Text(importError).font(.inter(.callout)).foregroundStyle(Theme.error)
                    }
                    Text("Download a headphone's “ParametricEQ.txt” from autoeq.app and import it here.")
                        .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text]) { result in
                importProfile(result, into: player)
            }
        }
    }

    private func importProfile(_ result: Result<URL, any Error>, into player: PlayerController) {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ParametricProfile.maximumTextSize else {
                importError = "That file is too large to be an AutoEQ profile."
                return
            }
            let profile = try ParametricProfile(parsing: String(contentsOf: url, encoding: .utf8))
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ParametricEQ", with: "")
            player.setEqualizer(EqualizerSettings(
                mode: .parametric, graphicGains: player.settings.equalizer.graphicGains,
                parametric: profile, parametricName: name
            ))
            importError = nil
        } catch {
            importError = "That file isn't an AutoEQ ParametricEQ profile."
        }
    }

    static func settings(_ equalizer: EqualizerSettings, mode: EqualizerMode) -> EqualizerSettings {
        EqualizerSettings(
            mode: mode, graphicGains: equalizer.graphicGains,
            parametric: equalizer.parametric, parametricName: equalizer.parametricName
        )
    }

    static func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}
