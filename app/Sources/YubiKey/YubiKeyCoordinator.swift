import Foundation
import UIKit
import CoreNFC
import CryptoKit
import CryptoTokenKit
import CommonCrypto
import YubiKit
import BsnsSSHCore

enum YubiKeyError: LocalizedError {
    case locked, unsupportedKey, noConnection
    /// A specific stage failed (connect / applet-select / PIN / sign). Carries the
    /// underlying error detail so the UI shows something diagnosable instead of
    /// Foundation's useless generic "the operation couldn't be completed."
    case stageFailed(stage: String, detail: String)
    /// The card has a non-default PIV management key and none was supplied — minting
    /// a key in a slot needs it.
    case managementKeyRequired
    /// A supplied management key wasn't valid hex (or the wrong length).
    case badManagementKey
    var errorDescription: String? {
        switch self {
        case .locked: return "Enter your YubiKey PIN first (Keys → Unlock YubiKey)."
        case .unsupportedKey: return "That slot doesn't hold a P-256 key."
        case .noConnection:
            return "Couldn't reach a YubiKey. On iPad, plug it into USB-C; on iPhone, plug it in or hold it to the top to tap over NFC."
        case .managementKeyRequired:
            return "This YubiKey has a custom PIV management key. Enter it (hex) under Management key to create a new key."
        case .badManagementKey:
            return "The management key must be hexadecimal — 48 hex characters for the default 3DES/AES-192 key (or 32 / 64 for AES-128 / AES-256)."
        case let .stageFailed(stage, detail): return "YubiKey \(stage) failed — \(detail)"
        }
    }
}

/// Parse a hex string into bytes. Only spaces/colons are accepted as separators;
/// any other non-hex character makes the whole input invalid (rather than being
/// silently dropped), so malformed input is rejected up front.
private func hexToData(_ s: String) -> Data? {
    let stripped = s.filter { !$0.isWhitespace && $0 != ":" }
    guard !stripped.isEmpty, stripped.count % 2 == 0, stripped.allSatisfy(\.isHexDigit) else { return nil }
    var out = Data(capacity: stripped.count / 2)
    var idx = stripped.startIndex
    while idx < stripped.endIndex {
        let next = stripped.index(idx, offsetBy: 2)
        guard let byte = UInt8(stripped[idx..<next], radix: 16) else { return nil }
        out.append(byte)
        idx = next
    }
    return out
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
    /// `managementKeyHex` is used only when a key must be generated and the card's
    /// management key isn't the default (blank = use the default).
    func enroll(pin: String, managementKeyHex: String? = nil) async throws -> Data {
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
            // 0x6982 otherwise).
            try await authenticateManagementKey(conn, session, pin: pin, managementKeyHex: managementKeyHex)
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

    /// Authenticate the PIV management key. Order: an explicitly-entered hex key;
    /// else the PIN-protected management key read off the card (the common
    /// `ykman --protect` setup — the PIN, already verified, unlocks it); else the
    /// factory default; else, if the card says it's non-default and we couldn't
    /// recover it, ask for the hex rather than failing with a bare 0x6982.
    private func authenticateManagementKey(_ conn: SmartCardConnection, _ session: PIVSession,
                                           pin: String, managementKeyHex: String?) async throws {
        let key: Data
        let hex = (managementKeyHex ?? "").trimmingCharacters(in: .whitespaces)
        // A PIV management key is 16 (AES-128), 24 (3DES / AES-192), or 32 (AES-256)
        // bytes. A PIN-based key (protected/derived) takes priority over whatever is
        // in the field — so someone who (understandably) typed their PIN there still
        // gets in via the PIN rather than hitting "bad management key".
        if !hex.isEmpty, let parsed = hexToData(hex), [16, 24, 32].contains(parsed.count) {
            key = parsed                                       // an explicit, valid hex key
        } else if let stored = await readPinProtectedManagementKey(conn) {
            key = stored                                       // ykman --protect (key stored on-card)
        } else if let derived = await deriveManagementKey(conn, pin: pin) {
            key = derived                                      // ykman PIN-derived (key = PBKDF2(PIN, salt))
        } else if !hex.isEmpty {
            throw YubiKeyError.badManagementKey                // they typed something, and it isn't a valid key
        } else if let meta = try? await session.getManagementKeyMetadata(), !meta.isDefault {
            throw YubiKeyError.managementKeyRequired
        } else {
            key = Self.defaultManagementKey
        }
        do { try await session.authenticate(with: key) }
        catch {
            throw YubiKeyError.stageFailed(
                stage: "management-key auth",
                detail: "\(yubiDetail(error)) — wrong management key (or it isn't PIN-protected; enter it as hex)")
        }
    }

    /// Read the PIN-protected management key stored on the card (`ykman
    /// --protect`): GET DATA on the protected pivman object (0x5fff01), which
    /// holds the key as TLV 0x88 → 0x89. Only succeeds after PIN verification;
    /// returns nil if the card has no such object (i.e. not a PIN-protected setup).
    /// Built as raw APDU bytes since YubiKit's typed `send(apdu:)` isn't public.
    private func readPinProtectedManagementKey(_ conn: SmartCardConnection) async -> Data? {
        // 00 CB 3F FF  Lc=05  5C 03 5F FF 01  Le=00  (GET DATA, tag-list → object 0x5fff01)
        let apdu = Data([0x00, 0xCB, 0x3F, 0xFF, 0x05, 0x5C, 0x03, 0x5F, 0xFF, 0x01, 0x00])
        guard let resp = try? await conn.send(data: apdu) else { return nil }
        let bytes = [UInt8](resp)
        guard bytes.count >= 2 else { return nil }
        let sw = (UInt16(bytes[bytes.count - 2]) << 8) | UInt16(bytes[bytes.count - 1])
        guard sw == 0x9000 else { return nil }   // 0x6A82 etc. = no protected object
        let body = Data(bytes[0 ..< bytes.count - 2])
        func records(_ d: Data) -> [TKTLVRecord] { TKBERTLVRecord.sequenceOfRecords(from: d) ?? [] }
        guard let obj = records(body).first(where: { $0.tag == 0x53 }),
              let prot = records(obj.value).first(where: { $0.tag == 0x88 }),
              let keyRec = records(prot.value).first(where: { $0.tag == 0x89 })
        else { return nil }
        return keyRec.value
    }

    /// Derive the management key from the PIN (`ykman`'s PIN-derived mode): GET
    /// DATA on the admin pivman object (0x5fff00); if it carries a salt (TLV
    /// 0x80 → 0x82), the key is PBKDF2-HMAC-SHA1(PIN, salt, 10000, 24 bytes).
    /// Returns nil if there's no salt (not a PIN-derived setup).
    private func deriveManagementKey(_ conn: SmartCardConnection, pin: String) async -> Data? {
        // 00 CB 3F FF  Lc=05  5C 03 5F FF 00  Le=00  (GET DATA → object 0x5fff00)
        let apdu = Data([0x00, 0xCB, 0x3F, 0xFF, 0x05, 0x5C, 0x03, 0x5F, 0xFF, 0x00, 0x00])
        guard let resp = try? await conn.send(data: apdu) else { return nil }
        let bytes = [UInt8](resp)
        guard bytes.count >= 2 else { return nil }
        let sw = (UInt16(bytes[bytes.count - 2]) << 8) | UInt16(bytes[bytes.count - 1])
        guard sw == 0x9000 else { return nil }
        let body = Data(bytes[0 ..< bytes.count - 2])
        func records(_ d: Data) -> [TKTLVRecord] { TKBERTLVRecord.sequenceOfRecords(from: d) ?? [] }
        guard let obj = records(body).first(where: { $0.tag == 0x53 }),
              let admin = records(obj.value).first(where: { $0.tag == 0x80 }),
              let saltRec = records(admin.value).first(where: { $0.tag == 0x82 }),
              !saltRec.value.isEmpty
        else { return nil }
        return Self.pbkdf2SHA1(pin: pin, salt: saltRec.value, rounds: 10000, length: 24)
    }

    /// PBKDF2-HMAC-SHA1 (CommonCrypto) — matches ykman's PIN-derived management key.
    private static func pbkdf2SHA1(pin: String, salt: Data, rounds: Int, length: Int) -> Data {
        var derived = Data(count: length)
        let pinData = Data(pin.utf8)
        derived.withUnsafeMutableBytes { dk in
            pinData.withUnsafeBytes { pp in
                salt.withUnsafeBytes { sp in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pp.bindMemory(to: Int8.self).baseAddress, pinData.count,
                        sp.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(rounds),
                        dk.bindMemory(to: UInt8.self).baseAddress, length)
                }
            }
        }
        return derived
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
