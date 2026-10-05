import XCTest
@testable import BsnsSSHCore

final class TmuxOverviewTests: XCTestCase {
    private let f = TmuxCommand.fieldSeparator

    func testOverviewCommandIsOneQuotedScript() {
        let command = TmuxCommand.overview()
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2)
        XCTAssertTrue(command.contains("list-windows -a"))
    }

    func testParsesWindowsClockLoadAndCPUs() throws {
        let output = """
        Last login: banner noise
        w\(f)main\(f)0\(f)1\(f)0\(f)1800000090\(f)2\(f)editor\(f)nvim
        w\(f)main\(f)1\(f)0\(f)1\(f)1800000000\(f)2\(f)odd \(f) name\(f)claude
        w\(f)build\(f)3\(f)1\(f)0\(f)1799990000\(f)0\(f)\(f)zsh
        now\(f)1800000100
        load\(f) 52.31 48.02 40.77 
        cpus\(f)28
        """
        let overview = try XCTUnwrap(TmuxCommand.parseOverview(output))
        XCTAssertEqual(overview.now, 1_800_000_100)
        XCTAssertEqual(overview.load, [52.31, 48.02, 40.77])
        XCTAssertEqual(overview.cpus, 28)
        XCTAssertEqual(overview.sessions, ["main", "build"])
        XCTAssertEqual(overview.windows.map(\.id), ["main:0", "main:1", "build:3"])
        XCTAssertEqual(overview.windows[1].name, "odd \(f) name")
        XCTAssertTrue(overview.windows[1].bell)
        XCTAssertEqual(overview.windows[1].command, "claude")
        XCTAssertEqual(overview.windows[2].attached, 0)
    }

    func testLinuxLoadFormatAndNoTmux() throws {
        let overview = try XCTUnwrap(TmuxCommand.parseOverview("now\(f)100\nload\(f)0.52 0.40 0.33 2/1234 5678\ncpus\(f)8\n"))
        XCTAssertEqual(overview.windows, [])
        XCTAssertEqual(overview.load, [0.52, 0.40, 0.33])
    }

    func testTruncatedOutputIsNotAnOverview() {
        XCTAssertNil(TmuxCommand.parseOverview("w\(f)main\(f)0\(f)1\(f)0\(f)10\(f)1\(f)x\(f)zsh\n"))
    }
}

final class AttentionTrackerTests: XCTestCase {
    private func overview(now: Int, activity: Int, bell: Bool = false) -> TmuxOverview {
        TmuxOverview(now: now, windows: [.init(session: "main", index: 0, isActive: true, bell: bell,
                                               lastActivity: activity, attached: 1, name: "w", command: "claude")],
                     load: [], cpus: nil)
    }

    func testWorkThatStopsIsAnnouncedOnce() {
        var tracker = AttentionTracker()
        XCTAssertEqual(tracker.feed(overview(now: 100, activity: 50)).count, 0)
        // Output for 15 seconds…
        for t in stride(from: 103, through: 118, by: 3) {
            XCTAssertEqual(tracker.feed(overview(now: t, activity: t)).count, 0)
        }
        let window = overview(now: 118, activity: 118).windows[0]
        XCTAssertEqual(tracker.state(of: window, now: 118), .working)
        // …then silence.
        XCTAssertEqual(tracker.feed(overview(now: 121, activity: 118)).count, 0)
        XCTAssertEqual(tracker.feed(overview(now: 124, activity: 118)).map(\.id), ["main:0"])
        XCTAssertEqual(tracker.state(of: window, now: 124), .waiting(since: 118))
        XCTAssertEqual(tracker.feed(overview(now: 127, activity: 118)).count, 0)
        XCTAssertEqual(tracker.waitingCount, 1)
    }

    func testABriefBurstIsNotAnnounced() {
        var tracker = AttentionTracker()
        _ = tracker.feed(overview(now: 100, activity: 50))
        _ = tracker.feed(overview(now: 103, activity: 103))     // one keystroke's echo
        XCTAssertEqual(tracker.feed(overview(now: 112, activity: 103)).count, 0)
        XCTAssertEqual(tracker.state(of: overview(now: 112, activity: 103).windows[0], now: 112), .quiet)
    }

    func testNewOutputOrALookEndsTheWait() {
        var tracker = AttentionTracker()
        _ = tracker.feed(overview(now: 100, activity: 50))
        for t in stride(from: 103, through: 115, by: 3) { _ = tracker.feed(overview(now: t, activity: t)) }
        XCTAssertEqual(tracker.feed(overview(now: 124, activity: 115)).count, 1)
        tracker.acknowledge("main:0")
        XCTAssertEqual(tracker.waitingCount, 0)
        // A second run that stops waits again; output resuming clears it.
        for t in stride(from: 130, through: 142, by: 3) { _ = tracker.feed(overview(now: t, activity: t)) }
        XCTAssertEqual(tracker.feed(overview(now: 150, activity: 142)).count, 1)
        _ = tracker.feed(overview(now: 153, activity: 153))
        XCTAssertEqual(tracker.waitingCount, 0)
    }

    func testBellIsAnnouncedAndFirstLookIsOnlyABaseline() {
        var tracker = AttentionTracker()
        XCTAssertEqual(tracker.feed(overview(now: 100, activity: 50, bell: true)).count, 0)   // already ringing at first look
        var fresh = AttentionTracker()
        _ = fresh.feed(overview(now: 100, activity: 50))
        XCTAssertEqual(fresh.feed(overview(now: 103, activity: 50, bell: true)).map(\.id), ["main:0"])
        XCTAssertEqual(fresh.feed(overview(now: 106, activity: 50, bell: true)).count, 0)
    }

    func testClosedWindowsAreForgotten() {
        var tracker = AttentionTracker()
        _ = tracker.feed(overview(now: 100, activity: 50))
        for t in stride(from: 103, through: 115, by: 3) { _ = tracker.feed(overview(now: t, activity: t)) }
        _ = tracker.feed(overview(now: 124, activity: 115))
        _ = tracker.feed(TmuxOverview(now: 127, windows: [], load: [], cpus: nil))
        XCTAssertEqual(tracker.waitingCount, 0)
    }
}
