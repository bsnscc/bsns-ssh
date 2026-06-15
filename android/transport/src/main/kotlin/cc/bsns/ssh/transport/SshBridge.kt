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

    // Interactive PTY session — open returns an opaque handle (0 on failure); the
    // caller drives it from a single owner thread (libssh2 isn't thread-safe).
    external fun nativeOpenShell(host: String, port: Int, user: String, pubBlob: ByteArray, signer: Any, cols: Int, rows: Int): Long
    external fun nativeWrite(handle: Long, data: ByteArray)
    /** Bytes read (>0), 0 if none available now, or -1 on EOF/error. */
    external fun nativeRead(handle: Long, buf: ByteArray): Int
    external fun nativeResize(handle: Long, cols: Int, rows: Int)
    external fun nativeClose(handle: Long)

    companion object {
        init { System.loadLibrary("sshbridge") }
    }
}
