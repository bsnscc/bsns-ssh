import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class MacTerminalRenderingTests: XCTestCase {
    private final class DisplayProbe: MacTerminalView {
        var fullRedrawRequests = 0
        var regionRedrawRequests = 0
        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { fullRedrawRequests += 1 }
                super.needsDisplay = newValue
            }
        }
        override func setNeedsDisplay(_ invalidRect: NSRect) {
            regionRedrawRequests += 1
            super.setNeedsDisplay(invalidRect)
        }
    }
    private func terminal() -> MacTerminalView {
        MacTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
    }

    func testNarrowOutputInvalidatesTheWholeVisibleSurface() {
        let view = terminal()
        view.needsDisplay = false
        view.setNeedsDisplay(NSRect(x: 0, y: 200, width: 800, height: 16))
        XCTAssertTrue(view.needsToDraw(NSRect(x: 0, y: 440, width: 100, height: 16)))
        XCTAssertTrue(view.needsToDraw(NSRect(x: 0, y: 0, width: 100, height: 16)))
    }

    func testTmuxPartialUpdateRepaintsOtherRowsToo() {
        let view = terminal()
        view.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[Htop row\u{1b}[10;1Hmiddle row")
        view.updateDisplay()
        view.needsDisplay = false
        view.feed(text: "\u{1b}[10;1Hchanged row")
        view.updateDisplay()
        XCTAssertTrue(view.needsToDraw(NSRect(x: 0, y: 440, width: 100, height: 16)))
        XCTAssertTrue(view.needsToDraw(NSRect(x: 0, y: 0, width: 100, height: 16)))
    }

    func testReattachingCachedViewInvalidatesWithoutNewOutput() {
        let view = DisplayProbe(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let first = NSView(frame: view.frame)
        let second = NSView(frame: view.frame)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = first
        first.addSubview(view)
        view.feed(text: "\u{1b}[?1049h\u{1b}[Hexisting tmux content")
        view.updateDisplay()
        view.removeFromSuperview()
        window.contentView = second
        let before = view.fullRedrawRequests
        second.addSubview(view)
        XCTAssertGreaterThan(view.fullRedrawRequests, before)
    }

    func testDrawingDoesNotReenableLegacyLayerWorkaround() {
        let view = terminal()
        view.disableFullRedrawOnAnyChanges = true
        view.viewWillDraw()
        XCTAssertFalse(view.disableFullRedrawOnAnyChanges)
    }

    func testSynchronizedOutputEndSchedulesARepaint() async throws {
        let view = DisplayProbe(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.feed(text: "\u{1b}[?1049h\u{1b}[?2026h\u{1b}[Hfinished frame")
        view.updateDisplay()
        let before = view.regionRedrawRequests
        view.feed(text: "\u{1b}[?2026l")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(view.regionRedrawRequests, before)
        XCTAssertNil(view.getTerminal().getUpdateRange())
    }
}
