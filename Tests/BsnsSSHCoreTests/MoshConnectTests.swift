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

    func testIgnoresLeadingNoise() {
        let out = "Warning: Permanently added host\nMOSH CONNECT 1234 abcdefghijklmnopqrstuv\n"
        XCTAssertEqual(MoshConnect.parse(out)?.port, "1234")
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
