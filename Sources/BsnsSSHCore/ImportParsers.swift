import Foundation

/// Parsers for migrating an existing OpenSSH setup: `ssh_config` host blocks,
/// `known_hosts` entries, and unencrypted OpenSSH private keys. Pure functions
/// over text/bytes so they unit-test without a device. Mirrors the Android
/// `:core` parsers (same field names) so both platforms import identically.

/// One concrete host resolved from an `ssh_config` `Host` block.
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String
    public let port: Int
    public let user: String?
    public let identityFile: String?
    public let proxyJump: String?
}

public enum SSHConfigParser {
    /// Parse `ssh_config` text into concrete hosts. Wildcard blocks (`Host *`)
    /// supply defaults; only blocks whose patterns are all literal become hosts.
    public static func parse(_ text: String) -> [SSHConfigHost] {
        struct Block { let patterns: [String]; var opts: [String: String] = [:] }
        var blocks: [Block] = []
        var currentIndex: Int? = nil

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let sepIdx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            let key = line[line.startIndex..<sepIdx].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: sepIdx)...].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value.isEmpty { continue }

            switch key {
            case "host":
                blocks.append(Block(patterns: value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)))
                currentIndex = blocks.count - 1
            case "match":
                currentIndex = nil    // too dynamic to import
            default:
                if let i = currentIndex { blocks[i].opts[key] = value }
            }
        }

        // Wildcard-block directives become defaults (first value wins, per ssh).
        var defaults: [String: String] = [:]
        for b in blocks where b.patterns.contains(where: { $0.contains("*") || $0.contains("?") }) {
            for (k, v) in b.opts where defaults[k] == nil { defaults[k] = v }
        }

        var out: [SSHConfigHost] = []
        for b in blocks {
            for alias in b.patterns {
                if alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") { continue }
                func opt(_ k: String) -> String? { b.opts[k] ?? defaults[k] }
                let jump = opt("proxyjump").flatMap { $0.caseInsensitiveCompare("none") == .orderedSame ? nil : $0 }
                out.append(SSHConfigHost(
                    alias: alias,
                    hostName: opt("hostname") ?? alias,
                    port: opt("port").flatMap(Int.init) ?? 22,
                    user: opt("user"),
                    identityFile: opt("identityfile"),
                    proxyJump: jump))
            }
        }
        return out
    }
}

/// A trusted host key recovered from a `known_hosts` line.
public struct KnownHostImport: Equatable, Sendable {
    public let identifier: String
    public let blob: Data
}

public enum KnownHostsParser {
    /// Parse `known_hosts`. Hashed entries (`|1|…`) can't be reversed to a host,
    /// so they're skipped; `@cert-authority`/`@revoked` markers are ignored.
    public static func parse(_ text: String) -> [KnownHostImport] {
        var out: [KnownHostImport] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("@"), let sp = line.firstIndex(of: " ") {
                line = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count < 3 { continue }
            let hostList = parts[0]
            if hostList.hasPrefix("|") { continue }     // hashed — unrecoverable
            guard let blob = Data(base64Encoded: parts[2]) else { continue }
            for h in hostList.split(separator: ",") {
                let id = h.trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { out.append(KnownHostImport(identifier: id, blob: blob)) }
            }
        }
        return out
    }
}

/// A private key recovered from an OpenSSH key file.
public struct ImportedKey: Equatable, Sendable {
    public let algorithm: KeyAlgorithm
    public let material: Data
    public let comment: String
}

public enum KeyImportError: Error, Sendable {
    case notAnOpenSSHKey
    case corrupt
    case encrypted
    case unsupportedType(String)
}

public enum OpenSSHPrivateKey {
    private static let magic = "openssh-key-v1\u{0}"

    /// Parse an unencrypted `-----BEGIN OPENSSH PRIVATE KEY-----` file and return
    /// the raw private material (ed25519 seed / ecdsa-p256 scalar). Encrypted keys
    /// and unsupported types throw, so the caller can surface why.
    public static func parse(_ text: String) throws -> ImportedKey {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(where: { $0.contains("BEGIN OPENSSH PRIVATE KEY") }) else {
            throw KeyImportError.notAnOpenSSHKey
        }
        var b64 = ""
        for l in lines[(begin + 1)...] {
            if l.contains("END OPENSSH PRIVATE KEY") { break }
            b64 += l.trimmingCharacters(in: .whitespaces)
        }
        guard let data = Data(base64Encoded: b64) else { throw KeyImportError.corrupt }

        var d = SSHDecoder(data)
        guard let magicData = try? d.readBytes(magic.utf8.count),
              String(data: magicData, encoding: .utf8) == magic else { throw KeyImportError.notAnOpenSSHKey }
        do {
            let cipher = try d.readStringUTF8()
            _ = try d.readStringUTF8()        // kdfname
            _ = try d.readString()            // kdfoptions
            guard cipher == "none" else { throw KeyImportError.encrypted }

            let count = try d.readUInt32()
            guard count >= 1 else { throw KeyImportError.corrupt }
            for _ in 0..<count { _ = try d.readString() }   // public keys (re-derived from private)

            var priv = SSHDecoder(try d.readString())
            guard try priv.readUInt32() == priv.readUInt32() else { throw KeyImportError.corrupt }

            let type = try priv.readStringUTF8()
            switch type {
            case "ssh-ed25519":
                _ = try priv.readString()                  // public (32)
                let secret = try priv.readString()         // seed(32) || public(32)
                guard secret.count >= 32 else { throw KeyImportError.corrupt }
                let comment = (try? priv.readStringUTF8()) ?? ""
                return ImportedKey(algorithm: .ed25519, material: secret.prefix(32),
                                   comment: comment.isEmpty ? "imported" : comment)
            case "ecdsa-sha2-nistp256":
                _ = try priv.readStringUTF8()              // curve
                _ = try priv.readString()                  // Q
                let scalar = try priv.readString()         // mpint d
                let comment = (try? priv.readStringUTF8()) ?? ""
                return ImportedKey(algorithm: .ecdsaP256, material: fixed32(scalar),
                                   comment: comment.isEmpty ? "imported" : comment)
            case "ssh-rsa":
                // OpenSSH RSA private: mpint n, e, d, iqmp, p, q. dP/dQ are
                // recomputed when assembling the PKCS#1 DER that FileKey stores.
                let n = try priv.readString()
                let e = try priv.readString()
                let d = try priv.readString()
                let iqmp = try priv.readString()
                let p = try priv.readString()
                let q = try priv.readString()
                let comment = (try? priv.readStringUTF8()) ?? ""
                let pkcs1 = try RSAPrivateKeyDER.fromComponents(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp)
                return ImportedKey(algorithm: .rsa, material: pkcs1,
                                   comment: comment.isEmpty ? "imported" : comment)
            default:
                throw KeyImportError.unsupportedType(type)
            }
        } catch let e as KeyImportError {
            throw e
        } catch {
            throw KeyImportError.corrupt
        }
    }

    /// An mpint as fixed 32-byte big-endian (drop sign byte / left-pad).
    private static func fixed32(_ data: Data) -> Data {
        var b = [UInt8](data)
        if b.count > 32 { b = Array(b.suffix(32)) }
        if b.count < 32 { b = [UInt8](repeating: 0, count: 32 - b.count) + b }
        return Data(b)
    }
}

/// Top-level private-key importer: detects the PEM container and dispatches.
/// Handles the formats people actually have for an existing key —
/// `OPENSSH PRIVATE KEY` (modern ssh-keygen), `RSA PRIVATE KEY` (PKCS#1, the
/// classic id_rsa / network-gear format), and `PRIVATE KEY` (PKCS#8) — so RSA
/// import covers all three, not just the OpenSSH wrapper.
public enum PrivateKeyImport {
    public static func parse(_ text: String) throws -> ImportedKey {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try OpenSSHPrivateKey.parse(text)
        }
        // Legacy/openssl PEM bodies mark passphrase encryption in their headers.
        if text.contains("ENCRYPTED") && (text.contains("Proc-Type") || text.contains("DEK-Info")) {
            throw KeyImportError.encrypted
        }
        if text.contains("BEGIN RSA PRIVATE KEY") {
            // PKCS#1 RSAPrivateKey DER is exactly the material FileKey stores.
            let der = try pemBody(text, marker: "RSA PRIVATE KEY")
            return try rsaImported(material: der)
        }
        if text.contains("BEGIN PRIVATE KEY") {
            // PKCS#8 — unwrap to the inner PKCS#1 (RSA only; EC PKCS#8 isn't supported here).
            let pkcs8 = try pemBody(text, marker: "PRIVATE KEY")
            let der = try RSAPrivateKeyDER.unwrapPKCS8(pkcs8)
            return try rsaImported(material: der)
        }
        if text.contains("BEGIN EC PRIVATE KEY") {
            throw KeyImportError.unsupportedType("EC PEM (re-export with: ssh-keygen -p -f key)")
        }
        throw KeyImportError.notAnOpenSSHKey
    }

    /// Validate candidate PKCS#1 material by deriving its public blob, then wrap
    /// it as an RSA ImportedKey. A non-RSA / corrupt DER throws here.
    private static func rsaImported(material: Data) throws -> ImportedKey {
        do { _ = try RSAKeySupport.publicBlob(fromMaterial: material) }
        catch { throw KeyImportError.unsupportedType("RSA (couldn't read the key)") }
        return ImportedKey(algorithm: .rsa, material: material, comment: "imported")
    }

    /// Base64 between `-----BEGIN <marker>-----` and `-----END <marker>-----`.
    private static func pemBody(_ text: String, marker: String) throws -> Data {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(where: { $0.contains("BEGIN \(marker)") }) else {
            throw KeyImportError.notAnOpenSSHKey
        }
        var b64 = ""
        for l in lines[(begin + 1)...] {
            if l.contains("END \(marker)") { break }
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.contains(":") { continue }   // skip RFC 1421 headers (Proc-Type, DEK-Info)
            b64 += t
        }
        guard let der = Data(base64Encoded: b64) else { throw KeyImportError.corrupt }
        return der
    }
}
