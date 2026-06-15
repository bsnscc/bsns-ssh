package cc.bsns.ssh.transport

/**
 * Thin Kotlin face over the libssh2 JNI bridge (`libsshbridge.so`). The sign
 * callback in native code calls back into a `signer` object's `sign([B): [B`,
 * so the private key stays in the Keystore — the transport never sees it.
 */
class SshBridge {
    /** Connect, password-auth, and append `authLine` to the server's authorized_keys. */
    external fun nativeInstallKey(host: String, port: Int, user: String, password: String, authLine: String): Boolean

    /** Public-key auth where signing is delegated to `signer` (a Keystore-backed
     *  object exposing `fun sign(data: ByteArray): ByteArray`), then exec `cmd`. */
    external fun nativeAuthAndExec(host: String, port: Int, user: String, pubBlob: ByteArray, signer: Any, cmd: String): String?

    companion object {
        init { System.loadLibrary("sshbridge") }
    }
}
