import XCTest
@testable import BsnsSSHCore

final class PasteGuardTests: XCTestCase {
    func testSingleLineNeverConfirms() {
        XCTAssertFalse(PasteGuard.needsConfirmation("ls -la", bracketedPaste: false))
        // Copying a whole line often brings its line break along.
        XCTAssertFalse(PasteGuard.needsConfirmation("ls -la\n", bracketedPaste: false))
        XCTAssertFalse(PasteGuard.needsConfirmation("ls -la\r\n", bracketedPaste: false))
        XCTAssertFalse(PasteGuard.needsConfirmation("", bracketedPaste: false))
    }

    func testMultiLineConfirmsOnlyWithoutBracketedPaste() {
        let block = "cd /tmp\nrm -rf build\n"
        XCTAssertTrue(PasteGuard.needsConfirmation(block, bracketedPaste: false))
        // The program takes the block as one unit and decides for itself.
        XCTAssertFalse(PasteGuard.needsConfirmation(block, bracketedPaste: true))
        XCTAssertTrue(PasteGuard.needsConfirmation("a\rb", bracketedPaste: false))
    }

    func testPolicies() {
        let block = "one\ntwo"
        XCTAssertFalse(PasteGuard.needsConfirmation(block, bracketedPaste: false, policy: .never))
        // Inside a multiplexer the terminal always sees bracketed paste on, so
        // only `always` can catch a risky paste there.
        XCTAssertFalse(PasteGuard.needsConfirmation(block, bracketedPaste: true, policy: .whenRisky))
        XCTAssertTrue(PasteGuard.needsConfirmation(block, bracketedPaste: true, policy: .always))
        XCTAssertFalse(PasteGuard.needsConfirmation("one\n", bracketedPaste: false, policy: .always))
    }

    func testLineCount() {
        XCTAssertEqual(PasteGuard.lineCount("a"), 1)
        XCTAssertEqual(PasteGuard.lineCount("a\nb\n"), 2)
        XCTAssertEqual(PasteGuard.lineCount("a\r\nb\r\nc"), 3)
        XCTAssertEqual(PasteGuard.lineCount("a\n\nb"), 3)
        XCTAssertEqual(PasteGuard.lineCount("\n"), 0)
    }

    func testPreviewIsBounded() {
        let text = (1...10).map { "line \($0) " + String(repeating: "x", count: 100) }.joined(separator: "\n")
        let preview = PasteGuard.preview(text, maxLines: 3, maxWidth: 12)
        XCTAssertEqual(preview, "line 1 xxxxx…\nline 2 xxxxx…\nline 3 xxxxx…\n…")
    }
}

final class LoopbackURLTests: XCTestCase {
    private func loopback(_ s: String) -> LoopbackURL? { URL(string: s).flatMap(LoopbackURL.init) }

    func testRecognisesTheServersLoopback() {
        XCTAssertEqual(loopback("http://localhost:3000")?.remotePort, 3000)
        XCTAssertEqual(loopback("http://localhost:3000")?.remoteHost, "localhost")
        XCTAssertEqual(loopback("http://127.0.0.1:8080/")?.remoteHost, "127.0.0.1")
        // "Every interface" on the server includes its loopback.
        XCTAssertEqual(loopback("http://0.0.0.0:5173/")?.remoteHost, "localhost")
        XCTAssertEqual(loopback("http://[::1]:9000/x")?.remoteHost, "::1")
        XCTAssertEqual(loopback("HTTP://LOCALHOST:3000")?.remotePort, 3000)
    }

    func testIgnoresEverythingElse() {
        XCTAssertNil(loopback("https://example.com:3000/"))
        XCTAssertNil(loopback("http://localhost.example.com:3000/"))
        XCTAssertNil(loopback("http://127.example.com/"))
        XCTAssertNil(loopback("ssh://localhost:22"))
        XCTAssertNil(loopback("http://10.0.0.5:3000/"))
    }

    func testDefaultPortsFollowTheScheme() {
        XCTAssertEqual(loopback("http://localhost/")?.remotePort, 80)
        XCTAssertEqual(loopback("https://localhost/")?.remotePort, 443)
    }

    func testLocalURLKeepsPathQueryAndFragment() {
        let url = loopback("http://localhost:3000/app/page?x=1&y=2#top")
        XCTAssertEqual(url?.localURL(port: 3001)?.absoluteString, "http://127.0.0.1:3001/app/page?x=1&y=2#top")
        XCTAssertEqual(loopback("https://localhost:8443")?.localURL(port: 8443)?.absoluteString, "https://127.0.0.1:8443")
    }

    func testLocalPortCandidates() {
        XCTAssertEqual(loopback("http://localhost:3000")?.localPortCandidates.prefix(3), [3000, 3001, 3002])
        // A phone can't bind a privileged port.
        XCTAssertEqual(loopback("http://localhost/")?.localPortCandidates.first, 8080)
        XCTAssertEqual(loopback("https://localhost/")?.localPortCandidates.first, 8443)
        // Never runs past the top of the port range.
        XCTAssertEqual(loopback("http://localhost:65534")?.localPortCandidates, [65534, 65535])
    }
}

final class PromptScanTests: XCTestCase {
    private let scan = PromptScan(pattern: PromptScan.defaultPattern)!
    private func lines(_ text: String) -> [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    func testDefaultPatternMatchesCommonPrompts() {
        XCTAssertTrue(scan.isPrompt("graham@Mac-Studio-2 ~ % ls -la"))
        XCTAssertTrue(scan.isPrompt("graham@Mac-Studio-2 ~ %"))
        XCTAssertTrue(scan.isPrompt("deploy@web-1:~/app$ git status"))
        XCTAssertTrue(scan.isPrompt("root@db:/var/log# tail syslog"))
        XCTAssertFalse(scan.isPrompt("total 48"))
        XCTAssertFalse(scan.isPrompt("  graham@host ~ % indented, so not a prompt"))
        XCTAssertFalse(scan.isPrompt("drwxr-xr-x  5 graham staff 160 Oct  4 08:00 src"))
    }

    func testLastOutputIsBetweenTheLastTwoPromptsWithContent() {
        let text = lines("""
        me@host ~ % echo one
        one
        me@host ~ % seq 1 3
        1
        2
        3
        me@host ~ %
        """)
        XCTAssertEqual(scan.promptLines(in: text), [0, 2, 6])
        XCTAssertEqual(scan.lastOutput(in: text), 3...5)
    }

    func testLastOutputSkipsCommandsThatPrintedNothing() {
        let text = lines("""
        me@host ~ % echo one
        one
        me@host ~ % cd /tmp
        me@host /tmp % true

        me@host /tmp %
        """)
        XCTAssertEqual(scan.lastOutput(in: text), 1...1)
    }

    func testLongCommandRowsAreNotOutput() {
        // At 20 columns the command wraps onto a second row, which the line
        // editor draws itself — it arrives as a separate line, exactly as wide
        // as the screen.
        let text = lines("""
        me@host ~ % for i in
        1 2; do echo; done
        1
        2
        3
        me@host ~ %
        """)
        XCTAssertEqual(text[0].count, 20)
        XCTAssertEqual(scan.lastOutput(in: text, width: 20), 2...4)
        // Without the width there is no way to tell; the row counts as output.
        XCTAssertEqual(scan.lastOutput(in: text), 1...4)
    }

    func testNoOutputWithoutTwoPrompts() {
        XCTAssertNil(scan.lastOutput(in: lines("just\nsome\noutput")))
        XCTAssertNil(scan.lastOutput(in: lines("me@host ~ % ls\nfile")))
    }

    func testInvalidPatternIsRejected() {
        XCTAssertNil(PromptScan(pattern: "("))
        XCTAssertNil(PromptScan(pattern: ""))
    }
}
