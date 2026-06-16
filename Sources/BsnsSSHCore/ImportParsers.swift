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
