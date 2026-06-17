package cc.bsns.ssh.core

import java.security.SecureRandom
import java.util.Base64

/**
 * Builds an `openssh-key-v1` private-key file for a FIDO2 security key
 * (`sk-ecdsa-sha2-nistp256@openssh.com`). The "private" half of an sk key holds
 * no secret scalar — the private key lives on the authenticator — only the
 * credential's *key handle*, flags, and application. But libssh2's
 * `libssh2_userauth_publickey_sk` insists on a full OpenSSH-format private key as
 * its `privatekeydata`: it parses the curve, public point, application, flags,
 * and key handle out of this blob and hands them to the sign callback. So we
 * hand-assemble the exact bytes it expects.
 *
 * Cross-platform contract: the public blob embedded here must match
 * [SshKeyFormat.skEcdsaPublicBlob] (what the server stored), or auth fails.
 *
 * Container (RFC-less, but `PROTOCOL.key` in OpenSSH defines it):
 * ```
 * "openssh-key-v1\0"
 * string ciphername  = "none"
 * string kdfname     = "none"
 * string kdfoptions  = ""
 * uint32 nkeys       = 1
 * string publickey   = skEcdsaPublicBlob(point, application)
 * string privatekeys = pad8(
 *     uint32 check  uint32 check          (equal — "decryption" sanity)
 *     string "sk-ecdsa-sha2-nistp256@openssh.com"
 *     string "nistp256"
 *     string point                        (uncompressed 0x04||X||Y)
 *     string application                  ("ssh:bsns")
 *     byte   flags
 *     string key_handle                   (FIDO credential id)
 *     string reserved = ""
 *     string comment
 *     1,2,3,…                             padding to an 8-byte multiple
 * )
 * ```
 */
object OpenSshSkKey {
    private const val MAGIC = "openssh-key-v1\u0000"   // 14 ASCII chars + NUL terminator
    const val SK_ECDSA_TYPE = "sk-ecdsa-sha2-nistp256@openssh.com"

    /** PEM text for an sk-ecdsa credential. `point` is the uncompressed P-256
     *  point (0x04||X||Y); `keyHandle` is the FIDO credential id; `flags` is the
     *  authenticator policy byte (e.g. presence-required). */
    fun ecdsaSkPem(
        point: ByteArray,
        application: String,
        keyHandle: ByteArray,
        flags: Int,
        comment: String = "bsns",
    ): String {
        val pub = SshKeyFormat.skEcdsaPublicBlob(point, application)
        val check = SecureRandom().nextInt().toLong() and 0xFFFFFFFFL

        val privSection = SshEncoder.build {
            it.writeUInt32(check)
            it.writeUInt32(check)
            it.writeString(SK_ECDSA_TYPE)
            it.writeString("nistp256")
            it.writeString(point)
            it.writeString(application)
            it.writeByte(flags)
            it.writeString(keyHandle)
            it.writeString(ByteArray(0))   // reserved
            it.writeString(comment)
        }
        // Pad with 1,2,3,… to an 8-byte boundary (cipher "none" block size).
        val padded = privSection.toMutableList()
        var pad = 1
        while (padded.size % 8 != 0) padded.add((pad++).toByte())

        val body = SshEncoder.build {
            it.writeBytes(MAGIC.toByteArray(Charsets.UTF_8))
            it.writeString("none")
            it.writeString("none")
            it.writeString(ByteArray(0))   // kdfoptions
            it.writeUInt32(1)
            it.writeString(pub)
            it.writeString(padded.toByteArray())
        }

        val b64 = Base64.getEncoder().encodeToString(body)
        val wrapped = b64.chunked(70).joinToString("\n")
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n$wrapped\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
