package cc.bsns.ssh.transport

/**
 * Thin Kotlin face over the mosh JNI bridge (in the same `libsshbridge.so`).
 * mosh's transport isn't thread-safe — every native call here must come from
 * the single owner thread in [MoshSession]; only [nativeMoshWake] is safe to
 * call from any thread.
 */
class MoshBridge {
    /** Open the UDP mosh transport (handle, 0 on failure). */
    external fun nativeMoshOpen(ip: String, port: String, key: String, cols: Int, rows: Int): Long
    /** Poll up to maxMs, recv if readable, tick; returns a new ANSI frame or null. */
    external fun nativeMoshService(handle: Long, maxMs: Int): ByteArray?
    external fun nativeMoshPush(handle: Long, data: ByteArray)
    external fun nativeMoshResize(handle: Long, cols: Int, rows: Int)
    /** Interrupt a blocked nativeMoshService (any thread). */
    external fun nativeMoshWake(handle: Long)
    external fun nativeMoshLastError(handle: Long): String?
    external fun nativeMoshClose(handle: Long)

    companion object {
        init { System.loadLibrary("sshbridge") }
    }
}
