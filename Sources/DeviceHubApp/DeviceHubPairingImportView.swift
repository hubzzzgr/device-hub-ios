import DeviceHubPersistence
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// File access stays in the app shell; pairing secrets never enter feature state.
struct DeviceHubPairingImportView: View {
    let pairingPersistence: PairingPersistenceClient

    @Environment(\.dismiss) private var dismiss
    @State private var showsFilePicker = false
    @State private var pendingImport: RemotePairingImport?
    @State private var isReadingFile = false
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
                        pendingImport = nil
                        message = nil
                        showsFilePicker = true
                    }
                    .disabled(isReadingFile || isImporting || imported)
                } footer: {
                    Text("If iCloud stays on ‘Waiting…’, download the file in Files first or choose a copy under On My iPhone.")
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
                if isReadingFile { ProgressView("Reading Pairing File…") }
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
                        .disabled(isReadingFile || isImporting)
                }
            }
        }
        .sheet(isPresented: $showsFilePicker) {
            PairingDocumentPicker(
                selected: { url in
                    showsFilePicker = false
                    readPairingFile(at: url)
                },
                cancelled: { showsFilePicker = false }
            )
            .ignoresSafeArea()
        }
        .interactiveDismissDisabled(isReadingFile || isImporting)
    }

    private func readPairingFile(at url: URL) {
        isReadingFile = true
        Task { @MainActor in
            defer { isReadingFile = false }
            do {
                // File-provider I/O must not block picker dismissal or the UI.
                pendingImport = try await Task.detached(priority: .userInitiated) {
                    try Self.loadPairingFile(at: url)
                }.value
            } catch {
                showFailure(error)
            }
        }
    }

    nonisolated private static func loadPairingFile(at url: URL) throws -> RemotePairingImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            // asCopy supplies a staged file. Only clean up app-owned staging
            // directories; never delete a file in the user's provider storage.
            let stagingDirectories = [FileManager.default.temporaryDirectory]
                + FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    .map { $0.appendingPathComponent("Inbox", isDirectory: true) }
            let path = url.resolvingSymlinksInPath().path
            if stagingDirectories.contains(where: {
                path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
            }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: RemotePairingImport.maximumByteCount + 1) ?? Data()
        return try RemotePairingImport(data: data)
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
                try await pairingPersistence.importRemotePairing(pendingImport)
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

/// Import mode materializes an app-owned local copy before reporting selection.
/// Accept all file types because providers can report a plist as generic data;
/// the bounded plist parser, rather than a provider's UTI, validates the file.
private struct PairingDocumentPicker: UIViewControllerRepresentable {
    let selected: (URL) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selected: selected, cancelled: cancelled)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let selected: (URL) -> Void
        private let cancelled: () -> Void

        init(selected: @escaping (URL) -> Void, cancelled: @escaping () -> Void) {
            self.selected = selected
            self.cancelled = cancelled
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                cancelled()
                return
            }
            selected(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            cancelled()
        }
    }
}

#Preview("Import Pairing · iPhone", traits: .fixedLayout(width: 393, height: 852)) {
    DeviceHubPairingImportView(pairingPersistence: .testValue)
}

#Preview("Import Pairing · iPad", traits: .fixedLayout(width: 1024, height: 1366)) {
    DeviceHubPairingImportView(pairingPersistence: .testValue)
}
