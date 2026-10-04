import XCTest
@testable import BsnsSSHCore

final class TmuxCommandTests: XCTestCase {
    private let named = TmuxCommand.Target(session: "work")

    func testEveryCommandIsOneSingleQuotedScript() {
        // The remote login shell may be fish or csh: a single-quoted POSIX
        // script is the one form they all hand to `sh` untouched, and a stray
        // quote inside it would end the script early.
        let targets = [named, TmuxCommand.Target(moshServerPID: 4242), TmuxCommand.Target()]
        for target in targets {
            let commands = [
                TmuxCommand.captureHistory(target, lines: 500),
                TmuxCommand.listWindows(target),
                TmuxCommand.selectWindow(target, index: 3),
                TmuxCommand.newWindow(target),
            ]
            for command in commands {
                XCTAssertTrue(command.hasPrefix("sh -c '"), command)
                XCTAssertTrue(command.hasSuffix("'"), command)
                XCTAssertEqual(command.filter { $0 == "'" }.count, 2, command)
            }
        }
    }

    func testNamedSessionIsAddressedExactly() {
        // `=name` is an exact match; a bare name is a prefix match and could
        // land on `work2`.
        let cmd = TmuxCommand.captureHistory(named, lines: 2000)
        XCTAssertTrue(cmd.contains("s=\"=work\"; p=\"=work:\"; "))
        XCTAssertTrue(cmd.contains("tmux -u capture-pane -p -J -S -2000 -t \"$p\""))
        XCTAssertFalse(cmd.contains("list-clients"))
    }

    func testSessionNameIsSanitized() {
        let target = TmuxCommand.Target(session: "wo rk'; rm -rf /")
        XCTAssertEqual(target.session, "workrm-rf")
        XCTAssertNil(TmuxCommand.Target(session: "';").session)
    }

    func testUnnamedTargetFindsTheClientByMoshAncestryThenByActivity() {
        let cmd = TmuxCommand.listWindows(TmuxCommand.Target(moshServerPID: 4242))
        let ancestry = cmd.range(of: "if [ \"$a\" = \"4242\" ]")
        let activity = cmd.range(of: "#{client_activity} #{client_tty}")
        XCTAssertNotNil(ancestry)
        XCTAssertNotNil(activity)
        XCTAssertTrue(ancestry!.lowerBound < activity!.lowerBound)
        // The activity fallback only applies when ancestry found nothing.
        XCTAssertTrue(cmd.contains("[ -n \"$c\" ] || c=$("))
        XCTAssertTrue(cmd.contains("exit 3"))
    }

    func testNoAncestryWalkWithoutAUsablePID() {
        for pid: Int32? in [nil, 0, 1, -5] {
            let cmd = TmuxCommand.listWindows(TmuxCommand.Target(moshServerPID: pid))
            XCTAssertFalse(cmd.contains("ps -o ppid="))
            XCTAssertTrue(cmd.contains("#{client_activity}"))
        }
    }

    func testHistoryCarriesThePaneWidth() {
        let cmd = TmuxCommand.captureHistory(named, lines: 100)
        let width = cmd.range(of: "display-message -p -t \"$p\" \"#{pane_width}\"")
        let capture = cmd.range(of: "capture-pane")
        XCTAssertNotNil(width)
        XCTAssertTrue(width!.lowerBound < capture!.lowerBound)

        let parsed = TmuxCommand.parseHistory("48\nline one\nline two\n")
        XCTAssertEqual(parsed.width, 48)
        XCTAssertEqual(parsed.text, "line one\nline two\n")
        // Output that doesn't start with a width (an older server, a banner) is
        // passed through whole.
        XCTAssertNil(TmuxCommand.parseHistory("hello\nworld").width)
        XCTAssertEqual(TmuxCommand.parseHistory("hello\nworld").text, "hello\nworld")
        XCTAssertNil(TmuxCommand.parseHistory("").width)
    }

    func testHistoryLineCountIsClamped() {
        XCTAssertTrue(TmuxCommand.captureHistory(named, lines: 0).contains("-S -1 "))
        XCTAssertTrue(TmuxCommand.captureHistory(named, lines: 9_999_999).contains("-S -50000 "))
    }

    func testWindowCommandsTargetTheSession() {
        XCTAssertTrue(TmuxCommand.selectWindow(named, index: 4).hasSuffix("tmux -u select-window -t \"$s:4\"'"))
        XCTAssertTrue(TmuxCommand.selectWindow(named, index: -2).hasSuffix("-t \"$s:0\"'"))
        XCTAssertTrue(TmuxCommand.newWindow(named).hasSuffix("tmux -u new-window -t \"$s:\"'"))
    }

    func testParsesWindowRowsAndSkipsNoise() {
        let f = TmuxCommand.fieldSeparator
        let output = """
        Last login: Sun Oct  4 on ttys001
        0\(f)0\(f)zsh\(f)zsh
        1\(f)1\(f)build: api\(f)make
        garbage\(f)row
        12\(f)0\(f)\(f)vim
        3\(f)0\(f)odd\(f)name\(f)top
        """
        XCTAssertEqual(TmuxCommand.parseWindows(output), [
            .init(index: 0, isActive: false, name: "zsh", command: "zsh"),
            .init(index: 1, isActive: true, name: "build: api", command: "make"),
            .init(index: 12, isActive: false, name: "", command: "vim"),
            // A name that happens to contain the separator keeps it.
            .init(index: 3, isActive: false, name: "odd\(f)name", command: "top"),
        ])
    }

    func testTmuxIsForcedToUTF8() {
        // An SSH exec session has no locale; without -u tmux prints every
        // non-ASCII character in the history as an underscore.
        for command in [TmuxCommand.captureHistory(named, lines: 10),
                        TmuxCommand.listWindows(TmuxCommand.Target(moshServerPID: 77))] {
            for subcommand in ["list-", "display-", "capture-", "select-", "new-"] {
                XCTAssertFalse(command.contains("tmux \(subcommand)"), command)
            }
            XCTAssertTrue(command.contains("tmux -u "), command)
        }
    }
}

extension MoshServerCommandTests {
    func testClipboardSetupRunsInTheSameCommandAsTheAttach() {
        let cmd = MoshServerCommand.build(tmux: "work", tmuxClipboard: true)
        // Overrides are read when the client's terminal is opened, so the `set`
        // has to precede `new-session` in ONE tmux invocation; a separate
        // `tmux set` would start a server that exits again with nothing in it.
        XCTAssertTrue(cmd.contains(#"tmux start-server \; set -as terminal-overrides ",xterm*:Ms=\\E]52;c%p1%.0s;%p2%s\\007" \; new-session -A -s work; fi"#))
        // Already configured: attach without appending a duplicate entry.
        XCTAssertTrue(cmd.contains(#"if tmux show -s terminal-overrides 2>/dev/null | grep -q "52;c%p1"; then tmux new-session -A -s work; else"#))
        XCTAssertTrue(cmd.hasSuffix(" || exec ${SHELL:-/bin/sh} -l'"))
        XCTAssertEqual(cmd.filter { $0 == "'" }.count, 2)
    }

    func testClipboardSetupIsOffByDefaultAndNeedsATmuxSession() {
        XCTAssertFalse(MoshServerCommand.build(tmux: "work").contains("terminal-overrides"))
        XCTAssertFalse(MoshServerCommand.build(tmux: nil, tmuxClipboard: true).contains("tmux"))
    }
}
