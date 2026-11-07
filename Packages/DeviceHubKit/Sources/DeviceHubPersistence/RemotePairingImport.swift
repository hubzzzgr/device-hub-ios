import CryptoKit
import DeviceHubCore
import Foundation

/// Import failures contain field names only, never file contents or key bytes.
public enum RemotePairingImportError: Error, Equatable, LocalizedError {
    case invalidPlist
    case invalidField(String)
    case missingField(String)
    case mismatchedPublicKey
    case existingPairings
    case targetAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .invalidPlist:
            "Choose an XML or binary remote pairing plist smaller than 128 KB."
        case let .invalidField(field):
            "The remote pairing file has an invalid \(field) field."
        case let .missingField(field):
            "This file is missing \(field). Export a complete remote pairing record including the controller identity and target verification keys."
        case .mismatchedPublicKey:
            "The controller public key does not match its private key."
        case .existingPairings:
            "This file uses a different controller identity. Importing it would invalidate your existing pairings, so nothing was changed."
        case .targetAlreadyExists:
            "A pairing for this device already exists. Nothing was changed."
        }
    }
}

/// A complete imported trust relationship. Parsing never changes live state.
/// Minimal controller-only plists cannot supply the peer pin required by
/// authenticated pair-verify and are deliberately rejected.
public struct RemotePairingImport: Sendable {
    public static let maximumByteCount = 128 * 1024
    public let controller: ControllerIdentity
    public let target: TargetPairingRecord

    public init(data: Data, now: Date = Date()) throws {
        guard data.count <= Self.maximumByteCount,
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let fields = root as? [String: Any]
        else { throw RemotePairingImportError.invalidPlist }

        func text(_ key: String) throws -> String {
            guard let value = fields[key] else {
                throw RemotePairingImportError.missingField(key)
            }
            guard let value = value as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 256,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw RemotePairingImportError.invalidField(key) }
            return value
        }
        func bytes(_ key: String, count: Int) throws -> Data {
            guard let value = fields[key] else {
                throw RemotePairingImportError.missingField(key)
            }
            guard let value = value as? Data, value.count == count,
                  value.contains(where: { $0 != 0 })
            else { throw RemotePairingImportError.invalidField(key) }
            return value
        }

        let hostIdentifier = try text("host_identifier")
        guard let uuid = UUID(uuidString: hostIdentifier),
              uuid.uuidString.lowercased() == hostIdentifier.lowercased()
        else { throw RemotePairingImportError.invalidField("host_identifier") }
        let secret = try bytes("private_key", count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        guard try key.publicKey.rawRepresentation == bytes("public_key", count: 32) else {
            throw RemotePairingImportError.mismatchedPublicKey
        }
        let peerKey = try bytes("peer_public_key", count: 32)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: peerKey)
        controller = try ControllerIdentity(
            identifier: ControllerIdentifier(rawValue: uuid),
            udid: ControllerUDID(rawValue: fields["host_udid"] == nil ? hostIdentifier : text("host_udid")),
            longTermSecretKey: Ed25519SecretKey(data: secret),
            alternateIRK: HostAlternateIRK(data: bytes("host_alt_irk", count: 16)),
            createdAt: now,
            wireIdentifier: hostIdentifier
        )
        let peerIdentifier = try text("peer_identifier")
        target = try TargetPairingRecord(
            deviceID: DeviceID(rawValue: text("peer_udid")),
            accountIdentifier: PairingAccountIdentifier(rawValue: peerIdentifier),
            peerIdentifier: PeerPairingIdentifier(rawValue: peerIdentifier),
            peerPublicKey: Ed25519PublicKey(data: peerKey),
            peerAlternateIRK: PeerAlternateIRK(data: bytes("peer_alt_irk", count: 16)),
            hostIdentityFingerprint: controller.fingerprint(),
            displayName: fields["peer_name"] == nil ? "Imported Device" : text("peer_name"),
            productType: text("peer_model"),
            operatingSystemVersion: nil,
            // Imported data has not been authenticated in this installation.
            // Normal pair-verify must succeed before the record is promoted.
            completion: .provisionalAfterVerifiedM5(verifiedAt: now)
        )
    }
}
