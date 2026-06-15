package cc.bsns.ssh.core

/** SSH-agent protocol message numbers (draft-miller-ssh-agent). */
enum class SshAgentMessageType(val code: Int) {
    FAILURE(5),
    SUCCESS(6),
    REQUEST_IDENTITIES(11),
    IDENTITIES_ANSWER(12),
    SIGN_REQUEST(13),
    SIGN_RESPONSE(14);

    companion object {
        fun from(code: Int): SshAgentMessageType? = entries.firstOrNull { it.code == code }
    }
}

/**
 * The heart of the app — holds the available keys and answers signing requests,
 * not caring where a key lives. Every SSH connection authenticates *through*
 * here, and `handleAgentMessage` is the same surface the network exposure
 * (phone-as-hardware-key) will feed bytes into. Kotlin port of the Swift `Agent`.
 *
 * Not an actor: Kotlin callers serialize access at the transport layer (as the
 * iOS app does off the main thread). The wire protocol here is pure.
 */
class Agent {
    // LinkedHashMap preserves insertion order; re-adding the same id updates the
    // backend in place without moving it (matches the Swift order semantics).
    private val backends = LinkedHashMap<String, KeyBackend>()

    fun add(backend: KeyBackend) { backends[backend.id] = backend }
    fun remove(id: String) { backends.remove(id) }
    fun identities(): List<SshPublicKey> = backends.values.map { it.publicKey }

    /** Sign for the key identified by its public-key blob. */
    fun sign(publicKeyBlob: ByteArray, data: ByteArray): ByteArray {
        val backend = backends.values.firstOrNull { it.publicKey.blob.contentEquals(publicKeyBlob) }
            ?: throw KeyBackendException("unknown key")
        return backend.sign(data)
    }

    /** Process one agent request payload (without the outer uint32 length frame)
     *  and return the response payload. */
    fun handleAgentMessage(payload: ByteArray): ByteArray = try {
        val dec = SshDecoder(payload)
        when (SshAgentMessageType.from(dec.readByte().toInt() and 0xFF)) {
            SshAgentMessageType.REQUEST_IDENTITIES -> identitiesAnswer()
            SshAgentMessageType.SIGN_REQUEST -> {
                val keyBlob = dec.readString()
                val data = dec.readString()
                dec.readUInt32()   // flags (rsa-sha2 selection) — handled later
                val signature = sign(keyBlob, data)
                SshEncoder.build {
                    it.writeByte(SshAgentMessageType.SIGN_RESPONSE.code)
                    it.writeString(signature)
                }
            }
            else -> failure()
        }
    } catch (e: Exception) {
        failure()
    }

    private fun identitiesAnswer(): ByteArray {
        val keys = identities()
        return SshEncoder.build { e ->
            e.writeByte(SshAgentMessageType.IDENTITIES_ANSWER.code)
            e.writeUInt32(keys.size.toLong())
            for (key in keys) {
                e.writeString(key.blob)
                e.writeString(key.comment)
            }
        }
    }

    private fun failure(): ByteArray = byteArrayOf(SshAgentMessageType.FAILURE.code.toByte())
}
