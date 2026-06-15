import Foundation
import CoreNFC
import CryptoKit
import YubiKit
import BsnsSSHCore

enum YubiKeyError: LocalizedError {
    case locked, unsupportedKey, noConnection
    var errorDescription: String? {
        switch self {
        case .locked: return "Enter your YubiKey PIN first (Keys → Unlock YubiKey)."
        case .unsupportedKey: return "That slot doesn't hold a P-256 key."
        case .noConnection: return "Couldn't reach a YubiKey. Plug it in or tap it to the phone."
        }
    }
}

/// Talks to a YubiKey's PIV applet over USB-C (preferred when plugged) or NFC.
/// The private key lives on the key; we only ever read its public key and ask it
/// to sign. The PIN is held in memory for the session after the first unlock.
@MainActor
@Observable
final class YubiKeyCoordinator {
    static let shared = YubiKeyCoordinator()
    private init() {}

    /// PIV authentication slot (9A) — the default for SSH.
    static let slot: UInt8 = 0x9a

    private(set) var unlocked = false
    private var pin: String?

    var available: Bool {
        get async {
            if NFCReaderSession.readingAvailable { return true }
            return !(((try? await USBSmartCardConnection.availableDevices()) ?? []).isEmpty)
        }
    }

    private func open() async throws -> SmartCardConnection {
        if let device = try? await USBSmartCardConnection.availableDevices().first {
            return try await USBSmartCardConnection(slot: device)
        }
        guard NFCReaderSession.readingAvailable else { throw YubiKeyError.noConnection }
        return try await NFCSmartCardConnection(alertMessage: "Hold your YubiKey to the top of your phone")
    }

    /// Read (or generate) the P-256 key in slot 9A; returns its SSH public blob.
    func enroll(pin: String) async throws -> Data {
        let conn = try await open()
        defer { Task { await conn.close(error: nil) } }
        let session = try await PIVSession.makeSession(connection: conn)
        _ = try await session.verifyPin(pin)

        let pub: PublicKey
        if let meta = try? await session.getMetadata(in: .authentication) {
            pub = meta.publicKey
        } else {
            pub = try await session.generateKey(in: .authentication, type: .ec(.secp256r1),
                                                pinPolicy: .once, touchPolicy: .always)
        }
        guard case .ec(let ec) = pub, ec.curve == .secp256r1 else { throw YubiKeyError.unsupportedKey }
        self.pin = pin
        unlocked = true
        return SSHKeyFormat.ecdsaP256PublicBlob(x963Point: ec.x963)
    }

    /// Re-supply the PIN after an app restart (validated against the key).
    func unlock(pin: String) async throws {
        let conn = try await open()
        defer { Task { await conn.close(error: nil) } }
        let session = try await PIVSession.makeSession(connection: conn)
        _ = try await session.verifyPin(pin)
        self.pin = pin
        unlocked = true
    }

    func lock() { pin = nil; unlocked = false }

    /// ECDSA-sign `data` with the slot key; returns the raw r‖s signature.
    func signRawRS(_ data: Data, slot: UInt8) async throws -> Data {
        guard let pin else { throw YubiKeyError.locked }
        let conn = try await open()
        defer { Task { await conn.close(error: nil) } }
        let session = try await PIVSession.makeSession(connection: conn)
        _ = try await session.verifyPin(pin)
        let pivSlot: PIV.Slot = slot == 0x9c ? .signature : .authentication
        let der = try await session.sign(data, in: pivSlot, keyType: .ec(.secp256r1), using: .hash(.sha256))
        return try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
    }
}
