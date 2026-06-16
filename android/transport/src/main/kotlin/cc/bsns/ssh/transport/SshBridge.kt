package cc.bsns.ssh.transport

/**
 * Thin Kotlin face over the libssh2 JNI bridge (`libsshbridge.so`). The sign
 * callback in native code calls back into a `signer` object's `sign([B): [B`,
 * so the private key stays in the Keystore — the transport never sees it.
 */
class SshBridge {
    /** Connect, password-auth, and append `authLine` to the server's authorized_keys. */
    external fun nativeInstallKey(host: String, port: Int, user: String, password: String, authLine: String, expectedHostKey: ByteArray?): Boolean

    /** Public-key auth where signing is delegated to `signer` (a Keystore-backed
     *  object exposing `fun sign(data: ByteArray): ByteArray`), then exec `cmd`. */
    external fun nativeAuthAndExec(host: String, port: Int, user: String, pubBlob: ByteArray, signer: Any, cmd: String, expectedHostKey: ByteArray?): String?

    /** Connect + handshake only; returns the server's host-key blob for TOFU. */
    external fun nativeHostKeyBlob(host: String, port: Int): ByteArray?

    /** Same, but reaches the target through a bastion (so TOFU works for hosts only
     *  reachable via ProxyJump). Authenticates to the bastion with `signer`. */
    external fun nativeHostKeyBlobVia(host: String, port: Int, jumpHost: String, jumpPort: Int, jumpUser: String, pubBlob: ByteArray, signer: Any, expectedBastionHostKey: ByteArray?): ByteArray?

    // Interactive PTY session — open returns an opaque handle (0 on failure); the
    // caller drives it from a single owner thread (libssh2 isn't thread-safe).
    // expectedHostKey (if non-null) must match the server's host key, or open fails.
    // jumpHost (if non-null) routes the connection through that bastion (ProxyJump).
    external fun nativeOpenShell(host: String, port: Int, user: String, pubBlob: ByteArray, signer: Any, cols: Int, rows: Int, expectedHostKey: ByteArray?, jumpHost: String?, jumpPort: Int, jumpUser: String?, expectedBastionHostKey: ByteArray?): Long
    external fun nativeWrite(handle: Long, data: ByteArray)
    /** Bytes read (>0), 0 if none available now, or -1 on EOF/error. */
    external fun nativeRead(handle: Long, buf: ByteArray): Int
    external fun nativeResize(handle: Long, cols: Int, rows: Int)
    external fun nativeClose(handle: Long)

    // SFTP — its own authenticated session (handle, 0 on failure). Serialise all
    // calls onto one thread (libssh2 isn't thread-safe).
    external fun nativeSftpOpen(host: String, port: Int, user: String, pubBlob: ByteArray, signer: Any, expectedHostKey: ByteArray?): Long
    /** Each row is "d\t<size>\t<name>" or "f\t<size>\t<name>"; null if path unreadable. */
    external fun nativeSftpList(handle: Long, path: String): Array<String>?
    external fun nativeSftpRead(handle: Long, path: String): ByteArray?
    external fun nativeSftpWrite(handle: Long, path: String, data: ByteArray): Boolean
    // Streaming transfer: open a remote file → read/write chunks → close, so a
    // large file flows through a fixed buffer instead of buffering entirely.
    external fun nativeSftpOpenRead(handle: Long, path: String): Long
    external fun nativeSftpOpenWrite(handle: Long, path: String): Long
    /** Bytes read (>0), 0 at EOF, -1 on error. */
    external fun nativeSftpReadChunk(fileHandle: Long, buf: ByteArray): Int
    external fun nativeSftpWriteChunk(fileHandle: Long, buf: ByteArray, len: Int): Boolean
    external fun nativeSftpCloseFile(fileHandle: Long)
    external fun nativeSftpMkdir(handle: Long, path: String): Boolean
    external fun nativeSftpRemove(handle: Long, path: String, isDir: Boolean): Boolean
    external fun nativeSftpClose(handle: Long)

    // Local (-L) port forwarding — one connection hosts several forwards. open()
    // returns a handle; service() must run on one owner thread; add/remove are
    // safe from any thread. add returns 0 or an errno (e.g. 98 = EADDRINUSE).
    external fun nativeForwardOpen(host: String, port: Int, user: String, pubBlob: ByteArray, signer: Any, expectedHostKey: ByteArray?): Long
    external fun nativeForwardAdd(handle: Long, listenPort: Int, destHost: String, destPort: Int): Int
    external fun nativeForwardRemove(handle: Long, listenPort: Int)
    /** Accept + pump; returns active connection count, or -1 if the session died. */
    external fun nativeForwardService(handle: Long, timeoutMs: Int): Int
    external fun nativeForwardClose(handle: Long)

    companion object {
        init { System.loadLibrary("sshbridge") }
    }
}
