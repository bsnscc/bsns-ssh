package cc.bsns.ssh.core

import java.security.MessageDigest
import java.util.Base64

/**
 * SSH public-key blob, signature blob, and fingerprint construction — Kotlin
 * port of the Swift `SSHKeyFormat`. The blob layouts are cross-platform
 * contracts: the same key must produce the same blob (and fingerprint) on iOS
 * and Android, or a key enrolled on one won't be recognized on the other.
 */
object SshKeyFormat {
    /** OpenSSH-style fingerprint: `SHA256:` + unpadded base64 of SHA-256(blob). */
    fun fingerprintOfPublicKeyBlob(blob: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(blob)
        val b64 = Base64.getEncoder().withoutPadding().encodeToString(digest)
        return "SHA256:$b64"
    }

    /** `ssh-ed25519` blob: string("ssh-ed25519") || string(A). */
    fun ed25519PublicBlob(rawPublicKey: ByteArray): ByteArray = SshEncoder.build {
        it.writeString("ssh-ed25519")
        it.writeString(rawPublicKey)
    }

    /** `ecdsa-sha2-nistp256` blob: string(type) || string("nistp256") || string(Q). */
    fun ecdsaP256PublicBlob(x963Point: ByteArray): ByteArray = SshEncoder.build {
        it.writeString("ecdsa-sha2-nistp256")
        it.writeString("nistp256")
        it.writeString(x963Point)
    }

    /** `ssh-rsa` blob: string("ssh-rsa") || mpint(e) || mpint(n) (RFC 4253 §6.6
     *  — exponent before modulus). `exponent`/`modulus` are unsigned big-endian
     *  magnitudes (a leading sign byte is fine; writeMPInt normalizes). */
    fun rsaPublicBlob(exponent: ByteArray, modulus: ByteArray): ByteArray = SshEncoder.build {
        it.writeString("ssh-rsa")
        it.writeMPInt(exponent)
        it.writeMPInt(modulus)
    }

    /** `sk-ecdsa-sha2-nistp256@openssh.com` (FIDO2 security-key) public-key blob:
     *  string(type) || string("nistp256") || string(Q) || string(application).
     *  `x963Point` is the uncompressed EC point (0x04||X||Y); `application` is the
     *  FIDO rp/credential scope (we use "ssh:bsns"), baked into the key. */
    fun skEcdsaPublicBlob(x963Point: ByteArray, application: String): ByteArray = SshEncoder.build {
        it.writeString("sk-ecdsa-sha2-nistp256@openssh.com")
        it.writeString("nistp256")
        it.writeString(x963Point)
        it.writeString(application)
    }

    /** Canonical SSH signature blob: string(format) || string(body). */
    fun signatureBlob(format: String, body: ByteArray): ByteArray = SshEncoder.build {
        it.writeString(format)
        it.writeString(body)
    }

    /** ECDSA signature body from a 64-byte r||s: mpint(r) || mpint(s). */
    fun ecdsaSignatureBody(rawRS: ByteArray): ByteArray = SshEncoder.build {
        it.writeMPInt(rawRS.copyOfRange(0, 32))
        it.writeMPInt(rawRS.copyOfRange(32, 64))
    }
}
