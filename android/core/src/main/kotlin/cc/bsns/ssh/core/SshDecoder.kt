package cc.bsns.ssh.core

/**
 * Reader counterpart to [SshEncoder] for the SSH wire format (RFC 4251 §5).
 * Kotlin port of the Swift `SSHDecoder`; parses public-key blobs, signatures,
 * and SSH-agent messages.
 */
class SshDecoder(private val bytes: ByteArray) {
    class DecodeException(message: String) : Exception(message)

    private var offset = 0

    val isAtEnd: Boolean get() = offset >= bytes.size
    val remaining: Int get() = bytes.size - offset

    fun readByte(): Byte {
        if (offset >= bytes.size) throw DecodeException("truncated")
        return bytes[offset++]
    }

    /** Reads a 32-bit big-endian value into a Long (unsigned). */
    fun readUInt32(): Long {
        if (offset + 4 > bytes.size) throw DecodeException("truncated")
        val v = ((bytes[offset].toLong() and 0xFF) shl 24) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
            (bytes[offset + 3].toLong() and 0xFF)
        offset += 4
        return v
    }

    fun readBytes(count: Int): ByteArray {
        if (count < 0) throw DecodeException("invalidLength")
        if (offset + count > bytes.size) throw DecodeException("truncated")
        val out = bytes.copyOfRange(offset, offset + count)
        offset += count
        return out
    }

    /** SSH `string`: a uint32 length followed by that many bytes. */
    fun readString(): ByteArray = readBytes(readUInt32().toInt())

    fun readStringUtf8(): String = String(readString(), Charsets.UTF_8)
}
