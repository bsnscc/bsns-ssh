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
