package cc.bsns.ssh.core

/**
 * SSH public-key / signature algorithm name — the string on the wire and in
 * `authorized_keys`. Mirrors the Swift `KeyAlgorithm`.
 */
enum class KeyAlgorithm(val wireName: String) {
    ED25519("ssh-ed25519"),
    ECDSA_P256("ecdsa-sha2-nistp256"),
    // RSA — compatibility path for legacy gear (older network equipment) that
    // can't do Ed25519/ECDSA. "ssh-rsa" is the key-blob type; the signature hash
    // is negotiated separately (see RsaSignatureAlgorithm).
    RSA("ssh-rsa"),
    // FIDO2-backed types — later (declared so codecs are shaped for them).
    ECDSA_SK("sk-ecdsa-sha2-nistp256@openssh.com"),
    ED25519_SK("sk-ssh-ed25519@openssh.com");

    val isSecurityKey: Boolean get() = this == ECDSA_SK || this == ED25519_SK

    companion object {
        fun fromWire(name: String): KeyAlgorithm? = entries.firstOrNull { it.wireName == name }
    }
}

/**
 * The signature hash for an `ssh-rsa` key. The public-key blob is always
 * "ssh-rsa", but RFC 8332 allows SHA-256/512 signatures; legacy gear usually
 * expects the original SHA-1 ("ssh-rsa"), which is the default. Mirrors the
 * Swift `RSASignatureAlgorithm`.
 */
enum class RsaSignatureAlgorithm(val wireName: String) {
    SHA1("ssh-rsa"),
    SHA256("rsa-sha2-256"),
    SHA512("rsa-sha2-512"),
}

/** A public key in SSH wire format plus its human comment. `blob` is exactly
 *  what appears (base64-encoded) in an `authorized_keys` line. */
class SshPublicKey(val blob: ByteArray, val algorithm: KeyAlgorithm, val comment: String = "") {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SshPublicKey) return false
        return algorithm == other.algorithm && comment == other.comment && blob.contentEquals(other.blob)
    }
    override fun hashCode(): Int = (31 * algorithm.hashCode() + comment.hashCode()) * 31 + blob.contentHashCode()
}

class KeyBackendException(message: String) : Exception(message)

/**
 * The uniform interface every key implementation satisfies — the agent talks
 * only to this and doesn't care whether a key lives in the Keystore, a file, or
 * on a token. Kotlin port of the Swift `KeyBackend` protocol. (SignContext is
 * added with the hardware backends; software signing doesn't need it.)
 */
interface KeyBackend {
    val id: String
    val publicKey: SshPublicKey
    val algorithm: KeyAlgorithm
    val canExport: Boolean
    val requiresUserPresence: Boolean

    /** Sign `data` and return a complete SSH signature blob:
     *  string(format) || string(body). Must not expose private-key material.
     *  For RSA this uses SHA-1 (ssh-rsa) — the method libssh2 advertises for an
     *  ssh-rsa blob on its userauth callback, and what legacy gear expects. */
    fun sign(data: ByteArray): ByteArray

    /** Sign with an explicit RSA hash (from the agent's rsa-sha2 flags). Ignored
     *  by non-RSA backends, which sign exactly as `sign(data)`. */
    fun sign(data: ByteArray, rsaAlgorithm: RsaSignatureAlgorithm): ByteArray = sign(data)
}
