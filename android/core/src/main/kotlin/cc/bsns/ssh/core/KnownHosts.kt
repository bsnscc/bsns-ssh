package cc.bsns.ssh.core

/** A server's host key as presented during the handshake. */
class HostKey(val keyType: String, val blob: ByteArray) {
    val fingerprint: String get() = SshKeyFormat.fingerprintOfPublicKeyBlob(blob)

    // Value equality (incl. blob bytes) to mirror the Swift Equatable HostKey.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HostKey) return false
        return keyType == other.keyType && blob.contentEquals(other.blob)
    }

    override fun hashCode(): Int = 31 * keyType.hashCode() + blob.contentHashCode()
}

/** Result of checking a presented host key against what we've stored. */
sealed interface HostVerification {
    /** Key matches a stored entry — proceed. */
    object Trusted : HostVerification
    /** No stored entry — first contact (TOFU). */
    data class Unknown(val fingerprint: String) : HostVerification
    /** A different key than stored — do not proceed without a loud override. */
    data class Mismatch(val stored: String, val presented: String) : HostVerification
}

/**
 * Trust-on-first-use host-key store — Kotlin port of the Swift `KnownHosts`.
 * Pure; the prompt UI and persistence live above it.
 */
class KnownHosts(entries: Map<String, HostKey> = emptyMap()) {
    private val entries = entries.toMutableMap()

    val allEntries: Map<String, HostKey> get() = entries.toMap()

    fun verify(host: String, port: Int, key: HostKey): HostVerification {
        val stored = entries[identifier(host, port)] ?: return HostVerification.Unknown(key.fingerprint)
        return if (stored.blob.contentEquals(key.blob)) HostVerification.Trusted
        else HostVerification.Mismatch(stored.fingerprint, key.fingerprint)
    }

    fun trust(host: String, port: Int, key: HostKey) {
        entries[identifier(host, port)] = key
    }

    fun storedKey(host: String, port: Int): HostKey? = entries[identifier(host, port)]

    fun forget(identifier: String) {
        entries.remove(identifier)
    }

    companion object {
        /** OpenSSH-style host identifier: bare host on port 22, else `[host]:port`. */
        fun identifier(host: String, port: Int): String = if (port == 22) host else "[$host]:$port"
    }
}
