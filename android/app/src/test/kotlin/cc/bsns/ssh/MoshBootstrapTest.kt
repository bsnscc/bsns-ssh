package cc.bsns.ssh

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Parity with the iOS `MoshConnectTests`: the `MOSH CONNECT <port> <key>` parser
 * must accept and reject exactly the same inputs on both platforms.
 */
class MoshBootstrapTest {

    @Test fun parsesRealServerOutput() {
        // The exact shape `mosh-server new` prints: connect line, blank, banner.
        val out = """
            MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg

            mosh-server (mosh 1.4.0) [build mosh 1.4.0]
            Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        """.trimIndent()
        assertEquals(MoshBootstrap.Connect(60001, "iX0Cr6iwnGdazeAKfSEzQg"), MoshBootstrap.parse(out))
    }

    @Test fun capturesTheDetachedServerPid() {
        // The pid line goes to STDERR, so the exec capture must include that
        // stream; it's how a server we can no longer reach is later reaped.
        val out = """
            MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg

            mosh-server (mosh 1.4.0) [build mosh 1.4.0]
            [mosh-server detached, pid = 31337]
        """.trimIndent()
        assertEquals(31337, MoshBootstrap.parse(out)?.pid)
        assertEquals(42, MoshBootstrap.parsePid("[mosh-server detached, pid=42]"))
        // No pid must never fail the connect — we just lose the targeted reap.
        assertEquals(0, MoshBootstrap.parsePid("MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg"))
        assertEquals(0, MoshBootstrap.parsePid("[mosh-server detached, pid = nope]"))
        assertEquals(0, MoshBootstrap.parsePid(null))
    }

    @Test fun setsTimeoutsInTheServersOwnEnvironment() {
        // The env prefix must come BEFORE mosh-server: these are read by
        // mosh-server itself, and `-l` (which we also pass) only reaches the
        // child shell. Getting this backwards silently disables the timeout.
        val cmd = MoshBootstrap.serverCommand(3600)
        assertTrue(cmd.startsWith("env MOSH_SERVER_NETWORK_TMOUT=3600 MOSH_SERVER_SIGNAL_TMOUT=60 mosh-server new"))
        // "Never expire" must not also disarm the SIGUSR1 idle guard: without
        // MOSH_SERVER_SIGNAL_TMOUT, SIGUSR1 shuts a server down even with a live
        // client attached.
        val noTimeout = MoshBootstrap.serverCommand(0)
        assertFalse(noTimeout.contains("MOSH_SERVER_NETWORK_TMOUT"))
        assertTrue(noTimeout.contains("MOSH_SERVER_SIGNAL_TMOUT=60"))
    }

    @Test fun reapPrefixChecksTheProcessBeforeSignalling() {
        val prefix = MoshBootstrap.reapPrefix(listOf(123, 456))
        assertTrue(prefix.startsWith("sh -c 'for p in 123 456;"))
        assertTrue(prefix.contains("ps -p \"\$p\" -o comm="))
        assertTrue(prefix.contains("*mosh-server*)"))
        assertTrue(prefix.contains("kill -USR1 \"\$p\""))
        // Quoted for `sh -c '…'`; a stray quote would break the whole bootstrap.
        assertEquals(2, prefix.count { it == '\'' })
        // Nothing to reap ⇒ no prefix at all; PID 0/1 are never ours.
        assertEquals("", MoshBootstrap.reapPrefix(emptyList()))
        assertEquals("", MoshBootstrap.reapPrefix(listOf(0, 1)))
        // The reap has to run before the replacement server starts.
        val cmd = MoshBootstrap.serverCommand(60, listOf(42))
        assertTrue(cmd.indexOf("kill -USR1") < cmd.indexOf("mosh-server new"))
    }

    @Test fun ignoresLeadingNoise() {
        val out = "Warning: Permanently added host\nMOSH CONNECT 1234 abcdefghijklmnopqrstuv\n"
        assertEquals(1234, MoshBootstrap.parse(out)?.port)
    }

    @Test fun rejectsConnectMarkerBuriedMidLine() {
        // The marker must START the (trimmed) line — a "MOSH CONNECT …" substring
        // inside a larger line must NOT match (the bug this parser fix closed).
        assertNull(MoshBootstrap.parse("note: MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg\n"))
    }

    @Test fun rejectsMissingConnectLine() {
        assertNull(MoshBootstrap.parse("bash: mosh-server: command not found\n"))
        assertNull(MoshBootstrap.parse(""))
        assertNull(MoshBootstrap.parse(null))
    }

    @Test fun rejectsMalformedFields() {
        // Bad port.
        assertNull(MoshBootstrap.parse("MOSH CONNECT 0 abcdefghijklmnopqrstuv\n"))
        assertNull(MoshBootstrap.parse("MOSH CONNECT 99999 abcdefghijklmnopqrstuv\n"))
        // Key wrong length.
        assertNull(MoshBootstrap.parse("MOSH CONNECT 60001 tooshort\n"))
        assertNull(MoshBootstrap.parse("MOSH CONNECT 60001 thiskeyiswaytoolongtobevalid\n"))
        // Missing key field.
        assertNull(MoshBootstrap.parse("MOSH CONNECT 60001\n"))
    }
}
