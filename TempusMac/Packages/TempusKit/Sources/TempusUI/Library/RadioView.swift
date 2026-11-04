import AppCore
import AppKit
import DesignSystem
import SubsonicAPI
import SwiftUI

// MARK: Radio

struct RadioView: View {
    @Environment(ServerSession.self) private var session
    @State private var stations: [RadioStation] = []
    @State private var serverError: SubsonicError?
    @State private var editing: RadioEditor.Mode?
    @State private var errorMessage: String?
    @State private var isLoaded = false

    var body: some View {
        Group {
            if stations.isEmpty, isLoaded {
                EmptyState(
                    art: .illustration(.emptyRadioStation),
                    title: "No radio stations",
                    message: Text("Add a station by its stream address, or look one up on radio-browser.info.")
                ) {
                    Button("Add a New Radio…") { editing = .add }
                }
            } else {
                List(stations) { station in
                    Button { play(station) } label: { StationRow(station: station) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play") { play(station) }
                            Button("Edit…") { editing = .edit(station) }
                            if let homePage = station.homePageURL
                                .flatMap({ RadioStationForm.webURL($0.absoluteString) })
                            {
                                Button("Open Home Page") { NSWorkspace.shared.open(homePage) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) { Task { await delete(station) } }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error).padding(Theme.Spacing.small)
            }
        }
        .toolbar { Button("Add a New Radio", tempus: .add) { editing = .add } }
        .sheet(item: $editing) { mode in
            RadioEditor(mode: mode, serverHasRadio: serverError == nil) { Task { await reload() } }
        }
        .task { await reload() }
    }

    private func reload() async {
        (stations, serverError) = await session.radio.stations()
        isLoaded = true
    }

    private func play(_ station: RadioStation) {
        errorMessage = station.isCleartext
            ? "Plain http streams may be refused by macOS. Use the station's https address if it has one."
            : nil
        session.player.play([station.song])
    }

    private func delete(_ station: RadioStation) async {
        do {
            try await session.radio.delete(station)
            await reload()
        } catch let error as SubsonicError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn't delete the station."
        }
    }
}

private struct StationRow: View {
    let station: RadioStation

    @Environment(ServerSession.self) private var session

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .frame(width: Theme.Size.trackCover, height: Theme.Size.trackCover)
                .background(.quaternary, in: .rect(cornerRadius: Theme.Radius.artworkSmall))
            VStack(alignment: .leading) {
                Text(station.name).font(.inter(.callout, weight: .medium))
                Text(station.streamURL.host() ?? "").font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
            }
            if station.origin == .local {
                Text("LOCAL").font(.inter(.caption2, weight: .bold)).padding(.horizontal, 4)
                    .background(Theme.accent.opacity(0.2), in: .capsule)
            }
            Spacer()
            if session.player.queue.current?.song.id == station.song.id {
                TempusIconImage(.equalizer, accessibilityName: Text("Now playing")).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(.rect)
    }
}

/// Upstream's add/edit station dialog, with the radio-browser lookup and Save to Server or Local.
private struct RadioEditor: View {
    enum Mode: Identifiable {
        case add
        case edit(RadioStation)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(station): station.id
            }
        }
    }

    let mode: Mode
    let serverHasRadio: Bool
    let onSaved: () -> Void

    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form = RadioStationForm()
    @State private var origin = RadioStation.Origin.server
    @State private var errorMessage: String?
    @State private var searchName = ""
    @State private var searchCountry = ""
    @State private var results: [RadioBrowserStation] = []
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(isEditing ? "Edit Radio Station" : "Add a New Radio").font(.inter(.headline))
            Form {
                TextField("Name", text: $form.name)
                TextField("Stream address", text: $form.streamAddress)
                TextField("Home page (optional)", text: $form.homePageAddress)
                if !isEditing {
                    Picker("Save to", selection: $origin) {
                        Text("Server").tag(RadioStation.Origin.server)
                        Text("Local").tag(RadioStation.Origin.local)
                    }
                    .pickerStyle(.segmented)
                }
            }
            if !isEditing {
                lookup
            }
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 520)
        .onAppear {
            if case let .edit(station) = mode {
                form = RadioStationForm(station: station)
            } else if !serverHasRadio {
                origin = .local
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode {
            true
        } else {
            false
        }
    }

    private var lookup: some View {
        GroupBox("Look up on radio-browser.info") {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Name", text: $searchName)
                    TextField("Country", text: $searchCountry).frame(width: 140)
                    Button("Search") { Task { await search() } }
                        .disabled(searchName.isEmpty && searchCountry.isEmpty)
                    if isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                if !results.isEmpty {
                    List(results) { station in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(station.name)
                                Text([station.country, station.codec, station.bitrate.map { "\($0) kbps" }]
                                    .compactMap(\.self).joined(separator: " • "))
                                    .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button("Use") { form = station.form }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await RadioBrowser().search(name: searchName, country: searchCountry)
            errorMessage = results.isEmpty ? "No stations found." : nil
        } catch {
            errorMessage = "radio-browser.info couldn't be reached."
        }
    }

    @State private var isSaving = false

    private func save() {
        guard !isSaving else { return }
        let valid: RadioStationForm.Valid
        switch form.validated() {
        case let .success(value): valid = value
        case let .failure(problem):
            errorMessage = problem.message
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                switch mode {
                case .add: try await session.radio.add(valid, origin: origin)
                case let .edit(station): try await session.radio.update(station, with: valid)
                }
                onSaved()
                dismiss()
            } catch let error as SubsonicError {
                // Upstream keeps the dialog open so the user can switch to Local.
                errorMessage = error.userMessage + (origin == .server ? " You can save it as Local instead." : "")
            } catch {
                errorMessage = "Couldn't save the station."
            }
        }
    }
}
