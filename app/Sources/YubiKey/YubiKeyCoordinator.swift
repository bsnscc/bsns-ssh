import Foundation
import UIKit
import CoreNFC
import CryptoKit
import YubiKit
import BsnsSSHCore

enum YubiKeyError: LocalizedError {
    case locked, unsupportedKey, noConnection
    /// A specific stage failed (connect / applet-select / PIN / sign). Carries the
    /// underlying error detail so the UI shows something diagnosable instead of
    /// Foundation's useless generic "the operation couldn't be completed."
    case stageFailed(stage: String, detail: String)
    var errorDescription: String? {
        switch self {
        case .locked: return "Enter your YubiKey PIN first (Keys → Unlock YubiKey)."
        case .unsupportedKey: return "That slot doesn't hold a P-256 key."
        case .noConnection:
            return "Couldn't reach a YubiKey. On iPad, plug it into USB-C; on iPhone, plug it in or hold it to the top to tap over NFC."
        case let .stageFailed(stage, detail): return "YubiKey \(stage) failed — \(detail)"
        }
    }
}

/// Fully describe an error for the UI: a generic localizedDescription on its own
/// ("the operation couldn't be completed") tells us nothing, so always append the
/// domain + code and any underlying error.
private func yubiDetail(_ error: Error) -> String {
    // A PIV failure carries the card's APDU status — far more useful than the
    // bridged NSError code (e.g. 0x6982 = the operation needs an auth we skipped).
    if let piv = error as? PIVSessionError, let status = piv.responseStatus {
        return "card status \(status.status)"
    }
    let ns = error as NSError
    var parts: [String] = []
    let desc = ns.localizedDescription
    if !desc.isEmpty, !desc.lowercased().contains("couldn’t be completed"),
       !desc.lowercased().contains("couldn't be completed") {
        parts.append(desc)
    }
    parts.append("\(ns.domain) \(ns.code)")
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        parts.append("← \(underlying.domain) \(underlying.code)")
    }
    return parts.joined(separator: " · ")
}

/// Talks to a YubiKey's PIV applet over USB-C (preferred when plugged) or NFC.
/// The private key lives on the key; we only ever read its public key and ask it
/// to sign. The PIN is held in memory for the session after the first unlock.
@MainActor
@Observable
final class YubiKeyCoordinator {
    static let shared = YubiKeyCoordinator()
    private init() {
        // Forget the cached PIN whenever the app leaves the foreground.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
    }

    /// PIV authentication slot (9A) — the default for SSH.
    static let slot: UInt8 = 0x9a

    /// PIV default management key (24 bytes). Generating a key in a slot requires
    /// management-key auth — the PIN only gates *signing*. `authenticate(with:)`
    /// reads the card metadata to pick 3DES vs AES-192, and the factory-default
    /// value is these same 24 bytes for both, so this works on old and new keys.
    private static let defaultManagementKey = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ])

    private(set) var unlocked = false
    private var pin: String?

    var available: Bool {
        get async {
            if NFCReaderSession.readingAvailable { return true }
            return !(((try? await USBSmartCardConnection.availableDevices()) ?? []).isEmpty)
        }
    }

    private func open() async throws -> SmartCardConnection {
        // USB-C first (the only route on iPad — iPads have no NFC). If a device
        // is enumerated but the connection itself fails, surface that error
        // rather than silently falling through to a "no connection" on iPad.
        do {
            if let device = try await USBSmartCardConnection.availableDevices().first {
                do { return try await USBSmartCardConnection(slot: device) }
                catch { throw YubiKeyError.stageFailed(stage: "USB-C connection", detail: yubiDetail(error)) }
            }
        } catch let e as YubiKeyError {
            throw e
        } catch {
            throw YubiKeyError.stageFailed(stage: "USB-C enumeration", detail: yubiDetail(error))
        }
        guard NFCReaderSession.readingAvailable else { throw YubiKeyError.noConnection }
        do { return try await NFCSmartCardConnection(alertMessage: "Hold your YubiKey to the top of your phone") }
        catch { throw YubiKeyError.stageFailed(stage: "NFC connection", detail: yubiDetail(error)) }
    }

    /// Open a connection and select the PIV applet, wrapping each stage so a
    /// failure says *where* it failed.
    private func openPIV() async throws -> (SmartCardConnection, PIVSession) {
        let conn = try await open()
        do {
            let session = try await PIVSession.makeSession(connection: conn)
            return (conn, session)
        } catch {
            await conn.close(error: nil)
            throw YubiKeyError.stageFailed(stage: "PIV applet select", detail: yubiDetail(error))
        }
    }

    /// Read (or generate) the P-256 key in slot 9A; returns its SSH public blob.
    func enroll(pin: String) async throws -> Data {
        let (conn, session) = try await openPIV()
        defer { Task { await conn.close(error: nil) } }
        do { _ = try await session.verifyPin(pin) }
        catch { throw YubiKeyError.stageFailed(stage: "PIN verify", detail: yubiDetail(error)) }

        let pub: PublicKey
        if let meta = try? await session.getMetadata(in: .authentication) {
            pub = meta.publicKey
        } else {
            // Slot 9A is empty, so mint a key — which requires PIV management-key
            // auth (the PIN alone isn't enough; the card rejects generate with
            // 0x6982 otherwise). Use the default management key.
            do { try await session.authenticate(with: Self.defaultManagementKey) }
            catch {
                throw YubiKeyError.stageFailed(
                    stage: "management-key auth",
                    detail: "\(yubiDetail(error)) — if you've changed the PIV management key from the default, that's not supported yet")
            }
            do {
                pub = try await session.generateKey(in: .authentication, type: .ec(.secp256r1),
                                                    pinPolicy: .once, touchPolicy: .always)
            } catch { throw YubiKeyError.stageFailed(stage: "key generation", detail: yubiDetail(error)) }
        }
        guard case .ec(let ec) = pub, ec.curve == .secp256r1 else { throw YubiKeyError.unsupportedKey }
        self.pin = pin
        unlocked = true
        return SSHKeyFormat.ecdsaP256PublicBlob(x963Point: ec.x963)
    }

    /// Re-supply the PIN after an app restart (validated against the key).
    func unlock(pin: String) async throws {
        let (conn, session) = try await openPIV()
        defer { Task { await conn.close(error: nil) } }
        do { _ = try await session.verifyPin(pin) }
        catch { throw YubiKeyError.stageFailed(stage: "PIN verify", detail: yubiDetail(error)) }
        self.pin = pin
        unlocked = true
    }

    func lock() { pin = nil; unlocked = false }

    /// ECDSA-sign `data` with the slot key; returns the raw r‖s signature.
    func signRawRS(_ data: Data, slot: UInt8) async throws -> Data {
        guard let pin else { throw YubiKeyError.locked }
        let (conn, session) = try await openPIV()
        defer { Task { await conn.close(error: nil) } }
        do { _ = try await session.verifyPin(pin) }
        catch { throw YubiKeyError.stageFailed(stage: "PIN verify", detail: yubiDetail(error)) }
        let pivSlot: PIV.Slot = slot == 0x9c ? .signature : .authentication
        do {
            let der = try await session.sign(data, in: pivSlot, keyType: .ec(.secp256r1), using: .hash(.sha256))
            return try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
        } catch { throw YubiKeyError.stageFailed(stage: "signing", detail: yubiDetail(error)) }
    }
}
