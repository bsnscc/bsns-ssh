package cc.bsns.ssh.diag

import org.slf4j.ILoggerFactory
import org.slf4j.Logger
import org.slf4j.Marker
import org.slf4j.event.Level
import org.slf4j.helpers.BasicMarkerFactory
import org.slf4j.helpers.LegacyAbstractLogger
import org.slf4j.helpers.NOPMDCAdapter
import org.slf4j.spi.MDCAdapter
import org.slf4j.spi.SLF4JServiceProvider

/**
 * Minimal in-memory SLF4J sink. YubiKit logs its USB/CTAP transport through SLF4J,
 * but the app ships no binding, so those logs are normally discarded. This captures
 * them into a bounded ring buffer that the FIDO diagnostic surfaces — the only way
 * to see the real CTAPHID exchange on a device without a cabled debugger.
 */
object LogBuffer {
    private val sb = StringBuilder()

    @Synchronized
    fun append(line: String) {
        sb.append(line).append('\n')
        if (sb.length > 120_000) sb.delete(0, sb.length - 90_000)
    }

    @Synchronized fun snapshot(): String = sb.toString()
    @Synchronized fun clear() { sb.setLength(0) }
}

class BufferLogger(private val n: String) : LegacyAbstractLogger() {
    override fun getName() = n
    override fun isTraceEnabled() = true
    override fun isDebugEnabled() = true
    override fun isInfoEnabled() = true
    override fun isWarnEnabled() = true
    override fun isErrorEnabled() = true
    override fun getFullyQualifiedCallerName(): String? = null
    override fun handleNormalizedLoggingCall(
        level: Level?, marker: Marker?, msg: String?, args: Array<out Any>?, t: Throwable?,
    ) {
        var m = msg ?: ""
        args?.forEach { a ->
            val i = m.indexOf("{}")
            if (i >= 0) m = m.substring(0, i) + a + m.substring(i + 2)
        }
        val tag = n.substringAfterLast('.')
        LogBuffer.append(
            "${level?.name?.take(1) ?: "?"} $tag: $m" +
                (t?.let { " | ${it.javaClass.simpleName}: ${it.message}" } ?: ""),
        )
    }
}

class BufferLoggerFactory : ILoggerFactory {
    override fun getLogger(name: String): Logger = BufferLogger(name)
}

/** Registered via META-INF/services/org.slf4j.spi.SLF4JServiceProvider. */
class BsnsSlf4jProvider : SLF4JServiceProvider {
    private val factory = BufferLoggerFactory()
    private val markers = BasicMarkerFactory()
    private val mdc = NOPMDCAdapter()
    override fun getLoggerFactory(): ILoggerFactory = factory
    override fun getMarkerFactory() = markers
    override fun getMDCAdapter(): MDCAdapter = mdc
    override fun getRequestedApiVersion() = "2.0.99"
    override fun initialize() {}
}
