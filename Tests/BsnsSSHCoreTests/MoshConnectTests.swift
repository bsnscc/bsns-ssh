import XCTest
@testable import BsnsSSHCore

final class MoshConnectTests: XCTestCase {
    func testParsesRealServerOutput() {
        // The exact shape `mosh-server new` prints: connect line, blank, banner.
        let out = """
        MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg

        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        """
        let c = MoshConnect.parse(out)
        XCTAssertEqual(c, MoshConnect(port: "60001", key: "iX0Cr6iwnGdazeAKfSEzQg"))
    }

    func testCapturesTheDetachedServerPID() {
        // The pid line goes to STDERR, so the bootstrap must capture both streams;
        // it's how we later reap a server we can no longer reach.
        let out = """
        MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg

        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        [mosh-server detached, pid = 31337]
        """
        XCTAssertEqual(MoshConnect.parse(out)?.pid, 31337)
        XCTAssertEqual(MoshConnect.parsePID("[mosh-server detached, pid=42]"), 42)
    }

    func testMissingPIDLineStillConnects() {
        // No pid (stderr not captured, or a server that words the line
        // differently) must never fail the connect — we just lose the targeted
        // reap and fall back to the idle timeout.
        let c = MoshConnect.parse("MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg\n")
        XCTAssertEqual(c?.port, "60001")
        XCTAssertNil(c?.pid)
        XCTAssertNil(MoshConnect.parsePID("[mosh-server detached, pid = nope]"))
        XCTAssertNil(MoshConnect.parsePID("[mosh-server detached, pid = 0]"))
    }

    func testIgnoresLeadingNoise() {
        let out = "Warning: Permanently added host\nMOSH CONNECT 1234 abcdefghijklmnopqrstuv\n"
        XCTAssertEqual(MoshConnect.parse(out)?.port, "1234")
    }

    func testRejectsConnectMarkerBuriedMidLine() {
        // The marker must START the (trimmed) line — a "MOSH CONNECT …" substring
        // inside a larger line must NOT match. Keeps Android's parser in parity.
        XCTAssertNil(MoshConnect.parse("note: MOSH CONNECT 60001 iX0Cr6iwnGdazeAKfSEzQg\n"))
    }

    func testRejectsMissingConnectLine() {
        XCTAssertNil(MoshConnect.parse("bash: mosh-server: command not found\n"))
        XCTAssertNil(MoshConnect.parse(""))
    }

    func testRejectsMalformedFields() {
        // Bad port.
        XCTAssertNil(MoshConnect.parse("MOSH CONNECT 0 abcdefghijklmnopqrstuv\n"))
        XCTAssertNil(MoshConnect.parse("MOSH CONNECT 99999 abcdefghijklmnopqrstuv\n"))
        // Key wrong length.
        XCTAssertNil(MoshConnect.parse("MOSH CONNECT 60001 tooshort\n"))
        // Missing key field.
        XCTAssertNil(MoshConnect.parse("MOSH CONNECT 60001\n"))
    }
}
