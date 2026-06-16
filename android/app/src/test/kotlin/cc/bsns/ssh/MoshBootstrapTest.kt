package cc.bsns.ssh

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

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
