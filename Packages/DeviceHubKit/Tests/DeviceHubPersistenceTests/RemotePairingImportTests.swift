import CryptoKit
import DeviceHubPersistence
import Foundation
import Testing

@Suite("Remote pairing import")
struct RemotePairingImportTests {
    @Test("XML and binary plists preserve credentials and signed identifier casing")
    func plistFormats() async throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let imported = try RemotePairingImport(data: data(format: format))
            #expect(imported.controller.wireIdentifier == "aabbccdd-0000-4000-8000-000000000001")
            #expect(imported.target.deviceID.rawValue == "synthetic-device")
            let driver = MemoryKeychainDriver()
            let store = KeychainPairingStore(driver: driver, generateControllerIdentity: { imported.controller })
            try await store.importRemotePairing(imported)
            let relaunched = KeychainPairingStore(driver: driver, generateControllerIdentity: { imported.controller })
            #expect(try await relaunched.loadOrCreateControllerIdentity() == imported.controller)
            #expect(try await relaunched.pairingRecords() == [imported.target])
            guard case .provisionalAfterVerifiedM5 = imported.target.completion else {
                Issue.record("Imported pairing must require pair-verify")
                return
            }
        }
    }

    @Test("Controller-only records report missing peer pins")
    func incompleteRecord() throws {
        var fields = try fields()
        fields.removeValue(forKey: "peer_public_key")
        #expect(throws: RemotePairingImportError.missingField("peer_public_key")) {
            try RemotePairingImport(data: encode(fields))
        }
    }

    @Test("Malformed input, oversized files, and mismatched keys are rejected")
    func malformedRecords() throws {
        #expect(throws: RemotePairingImportError.invalidPlist) {
            try RemotePairingImport(data: Data("not a plist".utf8))
        }
        #expect(throws: RemotePairingImportError.invalidPlist) {
            try RemotePairingImport(data: Data(repeating: 1, count: RemotePairingImport.maximumByteCount + 1))
        }
        var fields = try fields()
        fields["public_key"] = Data(repeating: 9, count: 32)
        #expect(throws: RemotePairingImportError.mismatchedPublicKey) {
            try RemotePairingImport(data: encode(fields))
        }
        fields = try self.fields()
        fields["peer_alt_irk"] = Data(repeating: 0, count: 16)
        #expect(throws: RemotePairingImportError.invalidField("peer_alt_irk")) {
            try RemotePairingImport(data: encode(fields))
        }
    }

    @Test("Existing trust relationships cannot be replaced by an import")
    func preservesExistingPairings() async throws {
        let imported = try RemotePairingImport(data: data())
        let driver = MemoryKeychainDriver()
        let store = KeychainPairingStore(driver: driver, generateControllerIdentity: { imported.controller })
        try await store.importRemotePairing(imported)
        let before = driver.storedData
        var fields = try fields(seed: 3)
        fields["peer_udid"] = "second-synthetic-device"
        let other = try RemotePairingImport(data: encode(fields))
        await #expect(throws: RemotePairingImportError.existingPairings) {
            try await store.importRemotePairing(other)
        }
        #expect(driver.storedData == before)
        await #expect(throws: RemotePairingImportError.targetAlreadyExists) {
            try await store.importRemotePairing(imported)
        }
        #expect(driver.storedData == before)
    }

    @Test("Failed Keychain writes leave the existing vault intact")
    func failedWriteIsAtomic() async throws {
        let imported = try RemotePairingImport(data: data())
        let driver = MemoryKeychainDriver()
        let store = KeychainPairingStore(driver: driver, generateControllerIdentity: { imported.controller })
        _ = try await store.loadOrCreateControllerIdentity()
        let before = driver.storedData
        let failure = KeychainDriverError.osStatus(operation: .update, status: -34018)
        driver.failNextUpdate(with: failure)
        await #expect(throws: failure) { try await store.importRemotePairing(imported) }
        #expect(driver.storedData == before)
        #expect(try await store.pairingRecords().isEmpty)
    }

    private func fields(seed: UInt8 = 1) throws -> [String: Any] {
        let secret = Data(repeating: seed, count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        let peer = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        return [
            "host_identifier": "aabbccdd-0000-4000-8000-000000000001",
            "host_udid": "synthetic-host",
            "private_key": secret,
            "public_key": key.publicKey.rawRepresentation,
            "host_alt_irk": Data(repeating: 3, count: 16),
            "peer_identifier": "synthetic-peer",
            "peer_udid": "synthetic-device",
            "peer_public_key": peer.publicKey.rawRepresentation,
            "peer_alt_irk": Data(repeating: 4, count: 16),
            "peer_name": "Fixture iPhone",
            "peer_model": "iPhone99,1"
        ]
    }

    private func encode(_ fields: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
    }

    private func data(format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: fields(), format: format, options: 0)
    }
}
