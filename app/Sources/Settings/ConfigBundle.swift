import Foundation
import CryptoKit
import CommonCrypto
import BsnsSSHCore

/// A portable snapshot of the app's configuration. Hosts, settings and trusted
/// host keys are always included; software private keys only when the user opts
/// in (and only inside an encrypted bundle).
struct ConfigBundle: Codable {
    var version = 1
    var hosts: [SavedHost]
    var knownHosts: KnownHosts
    var settings: SettingsSnapshot
    var keys: [ExportedKey]?
    var snippets: [Snippet]?
}

struct ExportedKey: Codable {
    var algorithm: String   // KeyAlgorithm raw value
    var material: Data       // private key material (JSON-encoded as base64)
    var comment: String
}

struct SettingsSnapshot: Codable {
    var theme, fontFamily, cursorStyle, bellMode, terminalType: String
    var fontSize: Double
    var scrollback, keepAliveInterval: Int
    var cursorBlink, keepAwake, optionAsMeta, pinchZoom, showKeyBar: Bool

    static func capture() -> SettingsSnapshot {
        let d = UserDefaults.standard
        return .init(
            theme: d.string(forKey: SettingsKey.theme) ?? TerminalTheme.bsnsDark.id,
            fontFamily: d.string(forKey: SettingsKey.fontFamily) ?? TerminalFont.families[0],
            cursorStyle: d.string(forKey: SettingsKey.cursorStyle) ?? "block",
            bellMode: d.string(forKey: SettingsKey.bellMode) ?? "haptic",
            terminalType: d.string(forKey: SettingsKey.terminalType) ?? "xterm-256color",
            fontSize: d.double(forKey: SettingsKey.fontSize),
            scrollback: d.integer(forKey: SettingsKey.scrollback),
            keepAliveInterval: d.integer(forKey: SettingsKey.keepAliveInterval),
            cursorBlink: d.bool(forKey: SettingsKey.cursorBlink),
            keepAwake: d.bool(forKey: SettingsKey.keepAwake),
            optionAsMeta: d.bool(forKey: SettingsKey.optionAsMeta),
            pinchZoom: d.bool(forKey: SettingsKey.pinchZoom),
            showKeyBar: d.bool(forKey: SettingsKey.showKeyBar))
    }

    /// Apply to UserDefaults. Deliberately does NOT carry the app-lock setting —
    /// a security toggle shouldn't transfer silently between devices.
    func apply() {
        let d = UserDefaults.standard
        d.set(theme, forKey: SettingsKey.theme)
        d.set(fontFamily, forKey: SettingsKey.fontFamily)
        d.set(cursorStyle, forKey: SettingsKey.cursorStyle)
        d.set(bellMode, forKey: SettingsKey.bellMode)
        d.set(terminalType, forKey: SettingsKey.terminalType)
        d.set(fontSize, forKey: SettingsKey.fontSize)
        d.set(scrollback, forKey: SettingsKey.scrollback)
        d.set(keepAliveInterval, forKey: SettingsKey.keepAliveInterval)
        d.set(cursorBlink, forKey: SettingsKey.cursorBlink)
        d.set(keepAwake, forKey: SettingsKey.keepAwake)
        d.set(optionAsMeta, forKey: SettingsKey.optionAsMeta)
        d.set(pinchZoom, forKey: SettingsKey.pinchZoom)
        d.set(showKeyBar, forKey: SettingsKey.showKeyBar)
    }
}

// MARK: - Cross-platform tolerant decoding
//
// The encrypted envelope is byte-compatible across iOS and Android, but the JSON
// *inside* it isn't written identically by both apps. So the import/sync decoder
// is deliberately lenient: it accepts the other platform's shape without losing
// data, while iOS keeps writing its own (richer) native shape on export.
//
// Divergences this absorbs (Android → iOS):
//   - hosts omit `id` and `label` (iOS requires both) and spell the key id
//     `keyId` rather than iOS's `keyID`.
//   - trusted host keys are a flat `{ id: base64Blob }` map, not iOS's nested
//     `{ entries: { id: { keyType, blob } } }`.
//   - settings carry only a subset of the fields iOS writes.
// Golden fixtures in ConfigBundleCrossPlatformTests lock this both ways.

extension SettingsSnapshot {
    /// App defaults for any field a bundle (e.g. an Android export) didn't carry.
    static func defaults() -> SettingsSnapshot {
        .init(theme: TerminalTheme.bsnsDark.id, fontFamily: TerminalFont.families[0],
              cursorStyle: "block", bellMode: "haptic", terminalType: "xterm-256color",
              fontSize: 13, scrollback: 1000, keepAliveInterval: 0,
              cursorBlink: true, keepAwake: false, optionAsMeta: true,
              pinchZoom: true, showKeyBar: true)
    }

    enum CodingKeys: String, CodingKey {
        case theme, fontFamily, cursorStyle, bellMode, terminalType, fontSize
        case scrollback, keepAliveInterval, cursorBlink, keepAwake, optionAsMeta, pinchZoom, showKeyBar
    }

    /// Per-field tolerant decode: a missing key falls back to the app default
    /// instead of failing the whole bundle (Android only writes a subset).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsSnapshot.defaults()
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? d.theme
        fontFamily = (try? c.decodeIfPresent(String.self, forKey: .fontFamily)) ?? d.fontFamily
        cursorStyle = (try? c.decodeIfPresent(String.self, forKey: .cursorStyle)) ?? d.cursorStyle
        bellMode = (try? c.decodeIfPresent(String.self, forKey: .bellMode)) ?? d.bellMode
        terminalType = (try? c.decodeIfPresent(String.self, forKey: .terminalType)) ?? d.terminalType
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        scrollback = (try? c.decodeIfPresent(Int.self, forKey: .scrollback)) ?? d.scrollback
        keepAliveInterval = (try? c.decodeIfPresent(Int.self, forKey: .keepAliveInterval)) ?? d.keepAliveInterval
        cursorBlink = (try? c.decodeIfPresent(Bool.self, forKey: .cursorBlink)) ?? d.cursorBlink
        keepAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwake)) ?? d.keepAwake
        optionAsMeta = (try? c.decodeIfPresent(Bool.self, forKey: .optionAsMeta)) ?? d.optionAsMeta
        pinchZoom = (try? c.decodeIfPresent(Bool.self, forKey: .pinchZoom)) ?? d.pinchZoom
        showKeyBar = (try? c.decodeIfPresent(Bool.self, forKey: .showKeyBar)) ?? d.showKeyBar
    }
}

extension ConfigBundle {
    enum CodingKeys: String, CodingKey { case version, hosts, knownHosts, settings, keys, snippets }

    /// A host as it may appear in *either* platform's bundle: iOS writes
    /// `id`/`label`/`keyID`; Android omits id/label and writes `keyId`.
    private struct HostWire: Decodable {
        var id: UUID?
        var label: String?
        var host: String
        var port: Int
        var user: String
        var useMosh: Bool?
        var jump: String?
        var group: String?
        var keyID: String?
        var keyId: String?   // Android spelling
        var saved: SavedHost {
            SavedHost(id: id ?? UUID(), label: label ?? host, host: host, port: port,
                      user: user, useMosh: useMosh, jump: jump, group: group, keyID: keyID ?? keyId)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        hosts = ((try? c.decodeIfPresent([HostWire].self, forKey: .hosts)) ?? [])?.map(\.saved) ?? []
        // Trusted host keys: try iOS's native nested shape first, then Android's
        // flat `{ id: base64 }` map.
        if let native = try? c.decodeIfPresent(KnownHosts.self, forKey: .knownHosts), native.allEntries.isEmpty == false {
            knownHosts = native
        } else if let flat = Self.decodeFlatKnownHosts(c) {
            knownHosts = flat
        } else {
            knownHosts = (try? c.decodeIfPresent(KnownHosts.self, forKey: .knownHosts)) ?? KnownHosts()
        }
        settings = (try? c.decodeIfPresent(SettingsSnapshot.self, forKey: .settings)) ?? .defaults()
        keys = try? c.decodeIfPresent([ExportedKey].self, forKey: .keys) ?? nil
        snippets = try? c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? nil
    }

    /// Decode Android's flat `{ id: base64Blob }` trusted-key map. The key type
    /// is recovered from the blob's leading SSH `string` field.
    private static func decodeFlatKnownHosts(_ c: KeyedDecodingContainer<CodingKeys>) -> KnownHosts? {
        guard let flat = try? c.decodeIfPresent([String: String].self, forKey: .knownHosts) else { return nil }
        var entries: [String: HostKey] = [:]
        for (id, b64) in flat {
            guard !id.isEmpty, let blob = Data(base64Encoded: b64) else { continue }
            entries[id] = HostKey(keyType: leadingSSHString(blob) ?? "ssh", blob: blob)
        }
        return entries.isEmpty ? nil : KnownHosts(entries: entries)
    }

    /// Read the leading SSH `string` (uint32 length ‖ bytes) from a host-key blob,
    /// which for any SSH public key is its algorithm name.
    private static func leadingSSHString(_ blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let b = [UInt8](blob)
        let len = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        guard len > 0, len <= 64, blob.count >= 4 + Int(len) else { return nil }
        return String(decoding: b[4 ..< 4 + Int(len)], as: UTF8.self)
    }
}

enum ConfigCryptoError: Error { case badPassphrase, badFormat }

/// Passphrase-based encryption for config bundles: PBKDF2-SHA256 (key derivation)
/// + AES-256-GCM (authenticated encryption), all from the system crypto libraries.
enum ConfigCrypto {
    private static let iterations = 210_000

    struct Envelope: Codable {
        var format = "bsns-config-aesgcm-v1"
        var iterations: Int
        var salt: Data
        var combined: Data   // AES.GCM sealed box: nonce ‖ ciphertext ‖ tag
    }

    static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        try salt.withUnsafeMutableBytes {
            guard SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) == errSecSuccess
            else { throw ConfigCryptoError.badFormat }
        }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw ConfigCryptoError.badFormat }
        return try JSONEncoder().encode(Envelope(iterations: iterations, salt: salt, combined: combined))
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ConfigCryptoError.badFormat
        }
        // Validate the untrusted envelope before any expensive KDF work: a
        // malicious import/sync file must not be able to force huge PBKDF2 work,
        // trap on UInt32(iterations), or supply an undersized box.
        guard env.format == "bsns-config-aesgcm-v1",
              env.salt.count == 16,
              (1...10_000_000).contains(env.iterations),
              env.combined.count >= 28 else {   // 12-byte nonce + 16-byte tag minimum
            throw ConfigCryptoError.badFormat
        }
        let key = try deriveKey(passphrase: passphrase, salt: env.salt, iterations: env.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: env.combined),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            throw ConfigCryptoError.badPassphrase
        }
        return plaintext
    }

    /// True if `data` is an encrypted envelope (vs. plain JSON).
    static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data)) != nil
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passphrase.withCString { pw in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw, strlen(pw),
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived, derived.count)
            }
        }
        // Don't proceed with a zeroed key if the KDF failed.
        guard Int(status) == kCCSuccess else { throw ConfigCryptoError.badFormat }
        return SymmetricKey(data: Data(derived))
    }
}
