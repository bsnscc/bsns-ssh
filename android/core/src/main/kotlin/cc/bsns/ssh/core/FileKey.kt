package cc.bsns.ssh.core

import org.bouncycastle.crypto.generators.ECKeyPairGenerator
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.ECDomainParameters
import org.bouncycastle.crypto.params.ECKeyGenerationParameters
import org.bouncycastle.crypto.params.ECPrivateKeyParameters
import org.bouncycastle.crypto.params.ECPublicKeyParameters
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.ParametersWithRandom
import org.bouncycastle.crypto.signers.ECDSASigner
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.crypto.ec.CustomNamedCurves
import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * A software key — private material held in memory, exportable, syncable.
 * Kotlin port of the Swift `FileKey`, on the BouncyCastle key API.
 *
 * The Ed25519 raw 64-byte signature and the ECDSA `mpint(r)||mpint(s)` body
 * match CryptoKit's, and the exported material is the raw scalar/seed (same as
 * iOS), so keys and signatures are byte-compatible across platforms — a key
 * synced from iOS reconstructs here, including its public key, via `from`.
 */
class FileKey private constructor(
    override val id: String,
    override val algorithm: KeyAlgorithm,
    override val publicKey: SshPublicKey,
    private val material: ByteArray,   // ed25519: 32-byte seed; ecdsa: 32-byte scalar
) : KeyBackend {
    override val canExport: Boolean get() = true
    override val requiresUserPresence: Boolean get() = false

    /** Raw private material, for the encrypted-at-rest / sync layer to wrap. */
    fun exportPrivateKeyMaterial(): ByteArray = material

    override fun sign(data: ByteArray): ByteArray = when (algorithm) {
        KeyAlgorithm.ED25519 -> {
            val signer = Ed25519Signer()
            signer.init(true, Ed25519PrivateKeyParameters(material, 0))
            signer.update(data, 0, data.size)
            SshKeyFormat.signatureBlob("ssh-ed25519", signer.generateSignature())
        }
        KeyAlgorithm.ECDSA_P256 -> {
            val priv = ECPrivateKeyParameters(BigInteger(1, material), p256)
            val signer = ECDSASigner()
            signer.init(true, ParametersWithRandom(priv, SecureRandom()))
            val rs = signer.generateSignature(MessageDigest.getInstance("SHA-256").digest(data))
            val rawRS = fixed32(rs[0]) + fixed32(rs[1])
            SshKeyFormat.signatureBlob("ecdsa-sha2-nistp256", SshKeyFormat.ecdsaSignatureBody(rawRS))
        }
        else -> throw KeyBackendException("unsupported algorithm: ${algorithm.wireName}")
    }

    companion object {
        private val p256: ECDomainParameters by lazy {
            val x9 = CustomNamedCurves.getByName("secp256r1")
            ECDomainParameters(x9.curve, x9.g, x9.n, x9.h)
        }

        /** Generate a fresh key. Only Ed25519 / ECDSA P-256 — `sk-` types are token-only. */
        fun generate(algorithm: KeyAlgorithm, comment: String = ""): FileKey = when (algorithm) {
            KeyAlgorithm.ED25519 -> {
                val gen = Ed25519KeyPairGenerator()
                gen.init(Ed25519KeyGenerationParameters(SecureRandom()))
                val pair = gen.generateKeyPair()
                val priv = pair.private as Ed25519PrivateKeyParameters
                val pub = pair.public as Ed25519PublicKeyParameters
                make(KeyAlgorithm.ED25519, SshKeyFormat.ed25519PublicBlob(pub.encoded), priv.encoded, comment)
            }
            KeyAlgorithm.ECDSA_P256 -> {
                val gen = ECKeyPairGenerator()
                gen.init(ECKeyGenerationParameters(p256, SecureRandom()))
                val pair = gen.generateKeyPair()
                val priv = pair.private as ECPrivateKeyParameters
                val pub = pair.public as ECPublicKeyParameters
                make(KeyAlgorithm.ECDSA_P256, SshKeyFormat.ecdsaP256PublicBlob(pub.q.getEncoded(false)),
                     fixed32(priv.d), comment)
            }
            else -> throw KeyBackendException("unsupported algorithm: ${algorithm.wireName}")
        }

        /** Reconstruct from raw private material (e.g. after the sync layer decrypts it),
         *  deriving the public key from the private scalar/seed. */
        fun from(algorithm: KeyAlgorithm, privateKeyMaterial: ByteArray, comment: String = ""): FileKey = when (algorithm) {
            KeyAlgorithm.ED25519 -> {
                val priv = Ed25519PrivateKeyParameters(privateKeyMaterial, 0)
                make(KeyAlgorithm.ED25519, SshKeyFormat.ed25519PublicBlob(priv.generatePublicKey().encoded),
                     privateKeyMaterial, comment)
            }
            KeyAlgorithm.ECDSA_P256 -> {
                val d = BigInteger(1, privateKeyMaterial)
                val q = p256.g.multiply(d).normalize()
                make(KeyAlgorithm.ECDSA_P256, SshKeyFormat.ecdsaP256PublicBlob(q.getEncoded(false)),
                     fixed32(d), comment)
            }
            else -> throw KeyBackendException("unsupported algorithm: ${algorithm.wireName}")
        }

        private fun make(algorithm: KeyAlgorithm, blob: ByteArray, material: ByteArray, comment: String) =
            FileKey(SshKeyFormat.fingerprintOfPublicKeyBlob(blob), algorithm,
                    SshPublicKey(blob, algorithm, comment), material)

        /** A BigInteger as a fixed 32-byte big-endian value (drop sign pad / left-pad). */
        private fun fixed32(n: BigInteger): ByteArray {
            var b = n.toByteArray()
            if (b.size > 32) b = b.copyOfRange(b.size - 32, b.size)
            if (b.size < 32) b = ByteArray(32 - b.size) + b
            return b
        }
    }
}
