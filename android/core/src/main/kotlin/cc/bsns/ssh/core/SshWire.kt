package cc.bsns.ssh.core

/**
 * Minimal SSH wire-format encoder (RFC 4251 §5) — the Kotlin port of the Swift
 * `SSHEncoder`. Only the pieces the agent and signature framing need: `uint32`,
 * `string`, and the sign-padded `mpint`.
 *
 * This MUST stay byte-identical to the Swift implementation; the parity test
 * vectors (shared with the iOS `SSHWireTests`) are the contract. `mpint` is the
 * footgun: a non-negative big-endian magnitude stored as a string, leading zero
 * bytes stripped, a single 0x00 prepended when the high bit of the leading byte
 * is set, and zero encoded as an empty string.
 */
class SshEncoder {
    private val buf = ArrayList<Byte>()

    val data: ByteArray get() = buf.toByteArray()

    fun writeByte(value: Int) {
        buf.add(value.toByte())
    }

    /** 32-bit big-endian. Takes a Long so the full unsigned range is expressible. */
    fun writeUInt32(value: Long) {
        buf.add(((value ushr 24) and 0xFF).toByte())
        buf.add(((value ushr 16) and 0xFF).toByte())
        buf.add(((value ushr 8) and 0xFF).toByte())
        buf.add((value and 0xFF).toByte())
    }

    fun writeBytes(bytes: ByteArray) {
        for (b in bytes) buf.add(b)
    }

    /** SSH `string`: a uint32 length followed by that many bytes. */
    fun writeString(bytes: ByteArray) {
        writeUInt32(bytes.size.toLong())
        writeBytes(bytes)
    }

    fun writeString(text: String) = writeString(text.toByteArray(Charsets.UTF_8))

    /** SSH `mpint` — see the class doc for the sign-padding rule. */
    fun writeMPInt(magnitude: ByteArray) {
        var start = 0
        while (start < magnitude.size && magnitude[start] == 0x00.toByte()) start++
        if (start == magnitude.size) {           // empty or all-zero → zero
            writeUInt32(0)
            return
        }
        val stripped = magnitude.copyOfRange(start, magnitude.size)
        val out = if (stripped[0].toInt() and 0x80 != 0) byteArrayOf(0x00) + stripped else stripped
        writeString(out)
    }

    companion object {
        /** Build a blob inline and return its bytes. */
        fun build(body: (SshEncoder) -> Unit): ByteArray {
            val e = SshEncoder()
            body(e)
            return e.data
        }
    }
}
