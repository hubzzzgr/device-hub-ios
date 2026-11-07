import DeviceHubLive
import DeviceHubPersistence
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// File access stays in the app shell; pairing secrets never enter feature state.
struct DeviceHubPairingImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsFilePicker = false
    @State private var pendingImport: RemotePairingImport?
    @State private var isImporting = false
    @State private var message: String?
    @State private var imported = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Import a remote pairing plist to reuse an existing trusted connection.")
                    Text("The file must include both the controller identity and target verification keys. Existing pairings are preserved.")
                        .foregroundStyle(.secondary)
                    Button("Choose Pairing File", systemImage: "doc.badge.plus") {
                        showsFilePicker = true
                    }
                    .disabled(isImporting || imported)
                }
                if pendingImport != nil {
                    Section {
                        Text("Import this pairing and its controller identity into this app’s Keychain?")
                        Button("Import Pairing", action: importPairing)
                            .disabled(isImporting)
                        Button("Cancel Import", role: .cancel) { pendingImport = nil }
                            .disabled(isImporting)
                    }
                }
                if isImporting { ProgressView("Importing Pairing…") }
                if let message {
                    Section {
                        Text(message)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pairing-import-result")
                    }
                }
            }
            .navigationTitle("Import Pairing")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isImporting)
                }
            }
            .fileImporter(
                isPresented: $showsFilePicker,
                allowedContentTypes: [.propertyList, .xml, .data]
            ) { result in
                pendingImport = nil
                message = nil
                switch result {
                case let .success(url):
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        let data = try file.read(upToCount: RemotePairingImport.maximumByteCount + 1) ?? Data()
                        pendingImport = try RemotePairingImport(data: data)
                    } catch {
                        showFailure(error)
                    }
                case .failure:
                    message = "The pairing file could not be opened. Choose a file available on this device."
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func importPairing() {
        guard let pendingImport, !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            defer {
                isImporting = false
                self.pendingImport = nil
            }
            do {
                let service = try DeviceHubPairingPersistenceProvisioning.keychainService()
                let store = KeychainPairingStore(
                    driver: SecurityKeychainDriver(),
                    descriptor: .pairingVault(service: service),
                    generateControllerIdentity: SystemControllerIdentityGenerator.generate
                )
                try await store.importRemotePairing(pendingImport)
                imported = true
                message = "Pairing imported. Close and reopen Device Hub to discover the device using this pairing."
            } catch {
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: any Error) {
        if let error = error as? RemotePairingImportError {
            message = error.errorDescription
        } else {
            message = "The pairing could not be imported. Check the file format and unlock this device, then try again."
        }
    }
}

#Preview("Import Pairing · iPhone", traits: .fixedLayout(width: 393, height: 852)) {
    DeviceHubPairingImportView()
}

#Preview("Import Pairing · iPad", traits: .fixedLayout(width: 1024, height: 1366)) {
    DeviceHubPairingImportView()
}
