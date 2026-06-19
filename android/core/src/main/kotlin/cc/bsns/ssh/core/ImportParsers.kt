package cc.bsns.ssh.core

import org.bouncycastle.asn1.ASN1Primitive
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.asn1.pkcs.RSAPrivateKey as Asn1RSAPrivateKey
import java.math.BigInteger
import java.util.Base64

/**
 * Parsers for migrating an existing OpenSSH setup into the app: `ssh_config`
 * host blocks, `known_hosts` entries, and unencrypted OpenSSH private keys.
 * Pure functions over text/bytes so they unit-test without a device. The Swift
 * side mirrors these (same field names) so both platforms import identically.
 */

/** One concrete host resolved from an `ssh_config` `Host` block. */
data class SshConfigHost(
    val alias: String,
    val hostName: String,
    val port: Int,
    val user: String?,
    val identityFile: String?,
    val proxyJump: String?,
)

object SshConfigParser {
    // A block = its pattern list (source order) + its directives (source order;
    // for a repeated single-valued key within a block, the FIRST wins per OpenSSH).
    private data class Block(val patterns: List<String>, val directives: MutableList<Pair<String, String>> = mutableListOf())

    /** Parse `ssh_config` text into concrete hosts. One host per literal `Host`
     *  pattern; effective options are resolved with OpenSSH first-match-wins
     *  semantics — every block whose pattern list matches the alias contributes,
     *  in source order, and the first value seen for a key wins. */
    fun parse(text: String): List<SshConfigHost> {
        val blocks = mutableListOf<Block>()
        var current: Block? = null

        for (raw in text.lines()) {
            val line = raw.substringBefore('#').trim()
            if (line.isEmpty()) continue
            // "Keyword value" or "Keyword=value"; keywords are case-insensitive.
            val sep = line.indexOfFirst { it == ' ' || it == '\t' || it == '=' }
            if (sep < 0) continue
            val key = line.substring(0, sep).trim().lowercase()
            val value = line.substring(sep + 1).trim().trim('"')
            if (value.isEmpty()) continue

            when (key) {
                "host" -> {
                    current = Block(value.split(Regex("\\s+")))
                    blocks.add(current)
                }
                "match" -> current = null  // too dynamic to import; stops the current block
                else -> current?.directives?.add(key to value)
            }
        }

        // The importable aliases: every literal (non-wildcard, non-negated) pattern.
        val aliases = blocks.flatMap { b ->
            b.patterns.filter { !it.contains('*') && !it.contains('?') && !it.startsWith('!') }
        }

        val out = mutableListOf<SshConfigHost>()
        for (alias in aliases) {
            // First-value-wins across every applying block, in source order.
            val opts = mutableMapOf<String, String>()
            for (b in blocks) {
                if (!patternsApply(b.patterns, alias)) continue
                for ((k, v) in b.directives) opts.putIfAbsent(k, v)
            }
            out.add(
                SshConfigHost(
                    alias = alias,
                    hostName = opts["hostname"] ?: alias,
                    port = opts["port"]?.toIntOrNull() ?: 22,
                    user = opts["user"],
                    identityFile = opts["identityfile"],
                    proxyJump = opts["proxyjump"]?.takeUnless { it.equals("none", true) },
                ),
            )
        }
        return out
    }

    /** Does a block's pattern list apply to [alias], per OpenSSH precedence:
     *  a matching negated pattern (`!glob`) excludes the block; otherwise any
     *  matching positive pattern includes it. */
    private fun patternsApply(patterns: List<String>, alias: String): Boolean {
        var positive = false
        for (pat in patterns) {
            if (pat.startsWith('!')) {
                if (globMatches(pat.substring(1), alias)) return false
            } else if (globMatches(pat, alias)) {
                positive = true
            }
        }
        return positive
    }

    /** Anchored full-string glob: `*` = zero-or-more of any char, `?` = exactly
     *  one char. A small fnmatch, matching OpenSSH `match_pattern`. Classic
     *  linear-time backtracking wildcard match. */
    internal fun globMatches(pattern: String, name: String): Boolean {
        var pi = 0
        var si = 0
        var star = -1
        var mark = 0
        while (si < name.length) {
            when {
                pi < pattern.length && (pattern[pi] == '?' || pattern[pi] == name[si]) -> { pi++; si++ }
                pi < pattern.length && pattern[pi] == '*' -> { star = pi; mark = si; pi++ }
                star != -1 -> { pi = star + 1; mark++; si = mark }
                else -> return false
            }
        }
        while (pi < pattern.length && pattern[pi] == '*') pi++
        return pi == pattern.length
    }
}

/** A trusted host key recovered from a `known_hosts` line. */
data class KnownHostImport(val id: String, val blob: ByteArray)

object KnownHostsParser {
    /** Parse `known_hosts`. Hashed entries (`|1|…`) can't be reversed to a host,
     *  so they're skipped. Lines starting with a marker (`@cert-authority` /
     *  `@revoked`) are skipped entirely: `@revoked` keys are revoked (never to be
     *  trusted) and `@cert-authority` designates a CA, not a host key — importing
     *  either as a plain trusted host key would invert OpenSSH's semantics. */
    fun parse(text: String): List<KnownHostImport> {
        val out = mutableListOf<KnownHostImport>()
        for (raw in text.lines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith('#')) continue
            if (line.startsWith('@')) continue   // @revoked / @cert-authority — never a trusted host key
            val parts = line.split(Regex("\\s+"))
            if (parts.size < 3) continue
            val (hostList, _, b64) = parts
            if (hostList.startsWith("|")) continue        // hashed — unrecoverable
            val blob = runCatching { Base64.getDecoder().decode(b64) }.getOrNull() ?: continue
            // One line can list several comma-separated hosts; trust each.
            for (h in hostList.split(',')) {
                val id = h.trim()
                if (id.isNotEmpty()) out.add(KnownHostImport(id, blob))
            }
        }
        return out
    }
}

/** A private key recovered from an OpenSSH key file. */
data class ImportedKey(val algorithm: KeyAlgorithm, val material: ByteArray, val comment: String)

/** Reason an OpenSSH key couldn't be imported (surfaced to the user). */
class KeyImportException(message: String) : Exception(message)

object OpenSshPrivateKey {
    private const val MAGIC = "openssh-key-v1\u0000"

    /**
     * Parse an unencrypted `-----BEGIN OPENSSH PRIVATE KEY-----` file and return
     * the raw private material (ed25519 seed / ecdsa-p256 scalar). Encrypted keys
     * and unsupported types raise [KeyImportException] — the caller surfaces why.
     */
    fun parse(text: String): ImportedKey {
        val b64 = text.lineSequence()
            .dropWhile { !it.contains("BEGIN OPENSSH PRIVATE KEY") }
            .drop(1)
            .takeWhile { !it.contains("END OPENSSH PRIVATE KEY") }
            .joinToString("")
            .trim()
        if (b64.isEmpty()) throw KeyImportException("not an OpenSSH private key (only the OpenSSH format is supported)")

        val data = runCatching { Base64.getDecoder().decode(b64) }
            .getOrElse { throw KeyImportException("the key file is corrupt") }

        val d = SshDecoder(data)
        val magic = String(d.readBytes(MAGIC.length), Charsets.UTF_8)
        if (magic != MAGIC) throw KeyImportException("not an OpenSSH-format private key")

        val cipher = d.readStringUtf8()
        d.readStringUtf8()          // kdfname
        d.readString()              // kdfoptions
        if (cipher != "none") throw KeyImportException("the key is passphrase-encrypted — decrypt it first (ssh-keygen -p)")

        val count = d.readUInt32().toInt()
        if (count < 1) throw KeyImportException("the key file has no keys")
        repeat(count) { d.readString() }            // public keys (we re-derive from private)

        val priv = SshDecoder(d.readString())       // unencrypted private section
        if (priv.readUInt32() != priv.readUInt32()) throw KeyImportException("the key file is corrupt")

        val type = priv.readStringUtf8()
        return when (type) {
            "ssh-ed25519" -> {
                priv.readString()                   // public (32)
                val secret = priv.readString()      // seed(32) || public(32)
                if (secret.size < 32) throw KeyImportException("malformed ed25519 key")
                val comment = priv.readStringUtf8()
                ImportedKey(KeyAlgorithm.ED25519, secret.copyOfRange(0, 32), comment.ifEmpty { "imported" })
            }
            "ecdsa-sha2-nistp256" -> {
                priv.readStringUtf8()               // curve name
                priv.readString()                   // Q (point)
                val scalar = priv.readString()      // mpint d
                val comment = priv.readStringUtf8()
                ImportedKey(KeyAlgorithm.ECDSA_P256, p256Scalar(scalar), comment.ifEmpty { "imported" })
            }
            "ssh-rsa" -> {
                // OpenSSH RSA private: mpint n, e, d, iqmp, p, q. Recompute the CRT
                // exponents (dP/dQ, which the format omits) to build PKCS#1 DER.
                val n = BigInteger(1, priv.readString())
                val e = BigInteger(1, priv.readString())
                val d = BigInteger(1, priv.readString())
                val iqmp = BigInteger(1, priv.readString())
                val p = BigInteger(1, priv.readString())
                val q = BigInteger(1, priv.readString())
                val comment = priv.readStringUtf8()
                val dp = d.mod(p.subtract(BigInteger.ONE))
                val dq = d.mod(q.subtract(BigInteger.ONE))
                val material = Asn1RSAPrivateKey(n, e, d, p, q, dp, dq, iqmp).encoded
                ImportedKey(KeyAlgorithm.RSA, material, comment.ifEmpty { "imported" })
            }
            else -> throw KeyImportException("unsupported key type: $type (ed25519, ecdsa-p256, rsa are supported)")
        }
    }

    /** Normalize a P-256 private scalar mpint to exactly 32 big-endian bytes.
     *  A valid P-256 scalar is ≤32 bytes (left-pad), or exactly 33 with a leading
     *  0x00 sign byte (drop it). Anything longer would lose significant bytes if
     *  truncated, so it's rejected rather than silently mangled. An all-zero
     *  scalar is invalid and rejected too. */
    private fun p256Scalar(scalar: ByteArray): ByteArray {
        var b = scalar
        if (b.size == 33 && b[0].toInt() == 0x00) b = b.copyOfRange(1, b.size)  // strip sign byte
        if (b.size > 32) throw KeyImportException("the key file is corrupt")
        if (b.size < 32) b = ByteArray(32 - b.size) + b
        if (b.all { it.toInt() == 0 }) throw KeyImportException("the key file is corrupt")
        return b
    }
}

/**
 * Top-level private-key importer: detects the PEM container and dispatches.
 * Handles the formats people actually have for an existing key —
 * `OPENSSH PRIVATE KEY`, `RSA PRIVATE KEY` (PKCS#1, the classic id_rsa /
 * network-gear format), and `PRIVATE KEY` (PKCS#8) — so RSA import covers all
 * three. Mirrors the Swift `PrivateKeyImport`.
 */
object PrivateKeyImport {
    fun parse(text: String): ImportedKey {
        if (text.contains("BEGIN OPENSSH PRIVATE KEY")) return OpenSshPrivateKey.parse(text)
        if (text.contains("ENCRYPTED") && (text.contains("Proc-Type") || text.contains("DEK-Info")))
            throw KeyImportException("the key is passphrase-encrypted — decrypt it first (ssh-keygen -p)")
        if (text.contains("BEGIN RSA PRIVATE KEY"))
            // PKCS#1 RSAPrivateKey DER is exactly the material FileKey stores.
            return rsaImported(pemBody(text, "RSA PRIVATE KEY"))
        if (text.contains("BEGIN PRIVATE KEY")) {
            // PKCS#8 — unwrap to the inner PKCS#1 (RSA only).
            val pkcs8 = pemBody(text, "PRIVATE KEY")
            val pkcs1 = PrivateKeyInfo.getInstance(ASN1Primitive.fromByteArray(pkcs8))
                .parsePrivateKey().toASN1Primitive().encoded
            return rsaImported(pkcs1)
        }
        if (text.contains("BEGIN EC PRIVATE KEY"))
            throw KeyImportException("EC PEM keys aren't supported here — re-export with: ssh-keygen -p -f key")
        throw KeyImportException("not a recognized private key format")
    }

    /** Validate candidate PKCS#1 material, then wrap it as an RSA ImportedKey. */
    private fun rsaImported(material: ByteArray): ImportedKey {
        try { Asn1RSAPrivateKey.getInstance(ASN1Primitive.fromByteArray(material)) }
        catch (e: Exception) { throw KeyImportException("couldn't read the RSA key") }
        return ImportedKey(KeyAlgorithm.RSA, material, "imported")
    }

    /** Base64 between BEGIN/END markers, skipping RFC 1421 headers. */
    private fun pemBody(text: String, marker: String): ByteArray {
        val b64 = text.lineSequence()
            .dropWhile { !it.contains("BEGIN $marker") }.drop(1)
            .takeWhile { !it.contains("END $marker") }
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.contains(":") }
            .joinToString("")
        return runCatching { Base64.getDecoder().decode(b64) }
            .getOrElse { throw KeyImportException("the key file is corrupt") }
    }
}
