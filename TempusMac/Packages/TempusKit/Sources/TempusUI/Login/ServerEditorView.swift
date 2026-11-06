import AppCore
import DesignSystem
import Persistence
import SwiftUI

/// Upstream's server editor: name, user, password, public URL, plaintext-password switch, and
/// optional local URL, client certificate and custom headers behind switches. Save tests the
/// connection first and offers to save anyway when it fails.
struct ServerEditorView: View {
    let existing: ServerProfile?
    /// Nil when the editor is the login screen itself rather than a sheet.
    let onDone: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var form = ServerForm()
    @State private var loaded = false
    @State private var issue: ServerForm.Issue?
    @State private var isBusy = false
    @State private var outcome: Outcome?
    @State private var unreachable: Unreachable?
    /// A server with plain-http addresses waiting for the user to accept the risk.
    @State private var confirmingCleartext: ValidServer?
    @State private var confirmingDelete = false
    @State private var showsPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Form {
                accountSection
                optionsSection
                warningsSection
            }
            .formStyle(.grouped)
            .scrollDisabled(onDone == nil)
            .fixedSize(horizontal: false, vertical: onDone == nil)
            outcomeLabel
            buttons
        }
        .disabled(isBusy)
        .task { await load() }
        .alert("Couldn't connect", isPresented: Binding(
            get: { unreachable != nil },
            set: {
                if !$0 {
                    unreachable = nil
                }
            }
        ), presenting: unreachable) { pending in
            Button("Save Anyway") { Task { await commit(pending.server) } }
            Button("Cancel", role: .cancel) { unreachable = nil }
        } message: { pending in
            Text(pending.message)
        }
        .confirmationDialog("Delete \(existing?.name ?? "this server")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Its password, queue, history and cached library are removed from this Mac.")
        }
        .confirmationDialog("Send your password unencrypted?", isPresented: Binding(
            get: { confirmingCleartext != nil },
            set: {
                if !$0 {
                    confirmingCleartext = nil
                }
            }
        ), presenting: confirmingCleartext) { server in
            Button("Save Anyway") { Task { await save(server, acceptingCleartext: true) } }
            Button("Cancel", role: .cancel) { confirmingCleartext = nil }
        } message: { _ in
            Text(form.warnings.map(\.message).joined(separator: "\n\n"))
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section {
            field("Server name", $form.name, .name)
            field("User name", $form.username, .username)
            HStack {
                Group {
                    if showsPassword {
                        TextField("Password", text: $form.password)
                    } else {
                        SecureField("Password", text: $form.password)
                    }
                }
                .textContentType(.password)
                Button(
                    showsPassword ? "Hide password" : "Show password",
                    systemImage: showsPassword ? "eye.slash" : "eye"
                ) { showsPassword.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.tempusBorderless)
            }
            issueText(for: .password)
            field("Public URL", $form.address, .address, hint: "https://music.example.com")
            Toggle("Plaintext password (legacy servers)", isOn: $form.usesPlaintextPassword)
                .help("For servers that don't accept token sign-in. The password is sent with every request.")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Set a local URL", isOn: $form.usesLocalAddress)
            if form.usesLocalAddress {
                field("Local URL", $form.localAddress, .localAddress, hint: "http://192.168.1.10:4533")
            }
            Toggle("Client certificate (mTLS)", isOn: $form.usesClientCertificate)
            if form.usesClientCertificate {
                CertificateField(certificate: $form.clientCertificate)
                issueText(for: .clientCertificate)
            }
            Toggle("Custom HTTP headers", isOn: $form.usesCustomHeaders)
            if form.usesCustomHeaders {
                TextEditor(text: $form.customHeaders)
                    .font(.body.monospaced())
                    .frame(minHeight: 48)
                    .autocorrectionDisabled()
                Text("One per line, e.g. CF-Access-Client-Id: value")
                    .font(.inter(.caption))
                    .foregroundStyle(Theme.secondaryText)
                issueText(for: .customHeaders)
            }
        }
    }

    @ViewBuilder private var warningsSection: some View {
        let warnings = form.warnings
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning.message, systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                        .font(.inter(.callout))
                }
            }
        }
    }

    @ViewBuilder private var outcomeLabel: some View {
        if let outcome {
            Label(outcome.message, tempus: outcome.isSuccess ? .checkCircle : .error)
                .foregroundStyle(outcome.isSuccess ? Theme.success : Theme.error)
                .tempusIconKeepsForeground()
                .padding(.horizontal, Theme.Spacing.small)
        }
    }

    private var buttons: some View {
        HStack {
            if existing != nil {
                Button("Delete", role: .destructive) { confirmingDelete = true }
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Test") { Task { await test() } }
            if let onDone {
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            Button(existing == nil ? "Add Server" : "Save") {
                guard let server = validServer() else { return }
                Task { await save(server, acceptingCleartext: false) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Spacing.small)
    }

    // MARK: Fields

    private func field(
        _ title: String,
        _ text: Binding<String>,
        _ field: ServerForm.Field,
        hint: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            TextField(title, text: text, prompt: hint.map { Text($0) })
                .autocorrectionDisabled()
            issueText(for: field)
        }
    }

    @ViewBuilder
    private func issueText(for field: ServerForm.Field) -> some View {
        if let issue, issue.field == field {
            Text(issue.message).font(.inter(.caption)).foregroundStyle(Theme.error)
        }
    }

    // MARK: Actions

    private func load() async {
        guard !loaded else { return }
        loaded = true
        if let existing {
            form = await model.accounts.formForEditing(existing)
        }
    }

    private func validServer() -> ValidServer? {
        outcome = nil
        switch form.validated() {
        case let .success(server):
            issue = nil
            return server
        case let .failure(problem):
            issue = problem
            return nil
        }
    }

    private func test() async {
        guard let server = validServer() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await model.accounts.test(server)
            outcome = Outcome(message: "Connected Successfully!", isSuccess: true)
        } catch {
            outcome = Outcome(message: error.userMessage, isSuccess: false)
        }
    }

    /// Asks before saving an address that sends credentials unencrypted, then tests the connection.
    private func save(_ server: ValidServer, acceptingCleartext: Bool) async {
        confirmingCleartext = nil
        guard acceptingCleartext || form.warnings.isEmpty else {
            confirmingCleartext = server
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await model.accounts.test(server)
        } catch {
            unreachable = Unreachable(server: server, message: error.userMessage)
            return
        }
        await commit(server)
    }

    private func commit(_ server: ValidServer) async {
        unreachable = nil
        do {
            try await model.save(server, replacing: existing)
            onDone?()
        } catch {
            outcome = Outcome(message: error.userMessage, isSuccess: false)
        }
    }

    private func delete() async {
        guard let existing else { return }
        do {
            try await model.delete(existing)
            onDone?()
        } catch {
            outcome = Outcome(message: error.userMessage, isSuccess: false)
        }
    }
}

private struct Outcome {
    let message: String
    let isSuccess: Bool
}

private struct Unreachable {
    let server: ValidServer
    let message: String
}

#Preview {
    ServerEditorView(existing: nil, onDone: {})
        .environment(PreviewSupport.model(signedIn: false))
        .frame(width: 480)
        .padding()
}
