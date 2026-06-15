package cc.bsns.ssh.core

import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.EdECPrivateKey

/**
 * A software key — private material held in memory, exportable, syncable.
 * Kotlin port of the Swift `FileKey` (ed25519 path). The Ed25519 signature is a
 * raw 64-byte R||S, identical to CryptoKit's, so the SSH signature blob matches
 * iOS byte-for-byte.
 *
 * ECDSA P-256 and reconstruct-from-material (`from`) are follow-ups; this
 * increment covers generation + signing + the agent protocol.
 */
class FileKey private constructor(
    override val id: String,
    override val algorithm: KeyAlgorithm,
    override val publicKey: SshPublicKey,
    private val privateKey: PrivateKey,
    private val material: ByteArray,
) : KeyBackend {
    override val canExport: Boolean get() = true
    override val requiresUserPresence: Boolean get() = false

    /** Raw private material, for the encrypted-at-rest / sync layer to wrap. */
    fun exportPrivateKeyMaterial(): ByteArray = material

    override fun sign(data: ByteArray): ByteArray = when (algorithm) {
        KeyAlgorithm.ED25519 -> {
            val sig = Signature.getInstance("Ed25519")
            sig.initSign(privateKey)
            sig.update(data)
            SshKeyFormat.signatureBlob("ssh-ed25519", sig.sign())   // raw 64-byte R||S
        }
        else -> throw KeyBackendException("unsupported algorithm: ${algorithm.wireName}")
    }

    companion object {
        fun generate(algorithm: KeyAlgorithm, comment: String = ""): FileKey = when (algorithm) {
            KeyAlgorithm.ED25519 -> {
                val kp = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
                // The 32-byte raw public key is the tail of the X.509 SPKI encoding
                // (fixed 12-byte header for Ed25519).
                val enc = kp.public.encoded
                val rawPublic = enc.copyOfRange(enc.size - 32, enc.size)
                val seed = (kp.private as EdECPrivateKey).bytes.orElseThrow { KeyBackendException("no seed") }
                val blob = SshKeyFormat.ed25519PublicBlob(rawPublic)
                FileKey(
                    id = SshKeyFormat.fingerprintOfPublicKeyBlob(blob),
                    algorithm = KeyAlgorithm.ED25519,
                    publicKey = SshPublicKey(blob, KeyAlgorithm.ED25519, comment),
                    privateKey = kp.private,
                    material = seed,
                )
            }
            else -> throw KeyBackendException("unsupported algorithm: ${algorithm.wireName}")
        }
    }
}
