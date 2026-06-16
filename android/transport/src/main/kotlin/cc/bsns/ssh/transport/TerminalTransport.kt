package cc.bsns.ssh.transport

/**
 * What the terminal UI needs from a live connection, regardless of whether it's
 * an SSH PTY or a mosh UDP session. Both [SshSession] and [MoshSession] satisfy
 * it, so the terminal widget binds to the transport, not a concrete type — the
 * Android analogue of the iOS `TerminalTransport` boundary.
 */
interface TerminalTransport {
    var onOutput: ((ByteArray) -> Unit)?
    fun write(data: ByteArray)
    fun resize(cols: Int, rows: Int)
    fun close()
}
