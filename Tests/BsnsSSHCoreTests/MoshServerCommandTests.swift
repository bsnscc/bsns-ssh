import XCTest
@testable import BsnsSSHCore

final class MoshServerCommandTests: XCTestCase {
    func testSetsTimeoutsInTheServersOwnEnvironment() {
        let cmd = MoshServerCommand.build(tmux: nil, idleTimeoutSeconds: 3600)
        // The env prefix must come BEFORE mosh-server: these are read by
        // mosh-server itself, and `-l` (which we also pass) only reaches the
        // child shell. Getting this backwards silently disables the timeout.
        XCTAssertTrue(cmd.hasPrefix("env MOSH_SERVER_NETWORK_TMOUT=3600 MOSH_SERVER_SIGNAL_TMOUT=60 mosh-server new"))
    }

    func testIdleTimeoutOffStillKeepsTheSignalTimeout() {
        // "Never expire" must not also disarm the SIGUSR1 idle guard: without
        // MOSH_SERVER_SIGNAL_TMOUT set, SIGUSR1 shuts a server down even with a
        // live client attached.
        let cmd = MoshServerCommand.build(tmux: nil, idleTimeoutSeconds: 0)
        XCTAssertFalse(cmd.contains("MOSH_SERVER_NETWORK_TMOUT"))
        XCTAssertTrue(cmd.contains("MOSH_SERVER_SIGNAL_TMOUT=60"))
    }

    func testReapPrefixChecksTheProcessBeforeSignalling() {
        let prefix = MoshServerCommand.reapPrefix(pids: [123, 456])
        XCTAssertTrue(prefix.hasPrefix("sh -c 'for p in 123 456;"))
        XCTAssertTrue(prefix.contains("ps -p \"$p\" -o comm="))
        XCTAssertTrue(prefix.contains("*mosh-server*)"))
        XCTAssertTrue(prefix.contains("kill -USR1 \"$p\""))
        XCTAssertTrue(prefix.hasSuffix("; "))
        // The reaper is quoted for `sh -c '…'`; a stray quote would break the
        // whole bootstrap command, not just the cleanup.
        XCTAssertEqual(prefix.filter { $0 == "'" }.count, 2)
    }

    func testNoReapPrefixWithoutPIDs() {
        XCTAssertEqual(MoshServerCommand.reapPrefix(pids: []), "")
        // PID 0/1 are never a mosh-server we started; never signal them.
        XCTAssertEqual(MoshServerCommand.reapPrefix(pids: [0, 1]), "")
        XCTAssertTrue(MoshServerCommand.build(tmux: nil).hasPrefix("env "))
    }

    func testReapRunsBeforeTheNewServerStarts() {
        let cmd = MoshServerCommand.build(tmux: nil, idleTimeoutSeconds: 60, reapPIDs: [42])
        let reap = cmd.range(of: "kill -USR1")!
        let start = cmd.range(of: "mosh-server new")!
        XCTAssertTrue(reap.lowerBound < start.lowerBound)
    }

    func testTmuxSuffixIsAppendedAfterTheServerArguments() {
        let cmd = MoshServerCommand.build(tmux: "work")
        XCTAssertTrue(cmd.hasSuffix(" -- sh -c 'tmux new-session -A -s work || exec ${SHELL:-/bin/sh} -l'"))
    }

    func testTmuxNameIsSanitized() {
        XCTAssertEqual(MoshServerCommand.sanitizedTmuxName("wo rk; rm -rf /"), "workrm-rf")
        XCTAssertNil(MoshServerCommand.sanitizedTmuxName("!!!"))
        XCTAssertNil(MoshServerCommand.sanitizedTmuxName(nil))
        XCTAssertEqual(MoshServerCommand.tmuxSuffix("!!!"), "")
    }
}
