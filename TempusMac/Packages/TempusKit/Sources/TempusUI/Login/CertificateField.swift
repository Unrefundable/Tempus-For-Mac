import AppCore
import DesignSystem
import os
import SwiftUI
import UniformTypeIdentifiers

/// Picks a `.p12` client certificate and asks for its passphrase. The file is checked by importing
/// it in memory; its bytes and passphrase are then saved to the Keychain with the server.
struct CertificateField: View {
    @Binding var certificate: CertificateFile?

    /// Client identities are a few kilobytes; anything this large isn't one.
    private static let maxFileSize = 1024 * 1024
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Certificates")

    @State private var choosing = false
    @State private var pending: Data?
    @State private var passphrase = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack {
                if let certificate {
                    Label(certificate.subject, systemImage: "checkmark.seal")
                } else {
                    Text("No certificate chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button(certificate == nil ? "Choose…" : "Replace…") { choosing = true }
                if certificate != nil {
                    Button("Remove", role: .destructive) { certificate = nil }
                }
            }
            if let message {
                Text(message).font(.inter(.caption)).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pkcs12]) { result in
            read(result)
        }
        .alert("Certificate passphrase", isPresented: Binding(
            get: { pending != nil },
            set: {
                if !$0 {
                    clearPending()
                }
            }
        )) {
            SecureField("Passphrase", text: $passphrase)
            Button("Import") { Task { await importPending() } }
            Button("Cancel", role: .cancel) { clearPending() }
        } message: {
            Text("Enter the passphrase this .p12 file was exported with.")
        }
    }

    private func read(_ result: Result<URL, any Error>) {
        message = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maxFileSize else {
                message = ClientCertificateImportError.unreadable.userMessage
                return
            }
            pending = try Data(contentsOf: url)
        } catch {
            Self.logger.error("Couldn't read the certificate file: \(error)")
            message = "The file couldn't be read."
        }
    }

    private func importPending() async {
        guard let data = pending else { return }
        let entered = passphrase
        clearPending()
        do {
            let imported = try await ClientCertificateImporter.importIdentityInBackground(
                pkcs12: data,
                passphrase: entered
            )
            certificate = CertificateFile(data: data, passphrase: entered, subject: imported.subject)
            message = nil
        } catch {
            message = error.userMessage
        }
    }

    private func clearPending() {
        pending = nil
        passphrase = ""
    }
}
