import XCTest
@testable import BsnsSSHCore

final class HostRoutesTests: XCTestCase {
    func testParseKeepsAddressesAndDropsTheRest() {
        let routes = HostRoutes.parse("studio.local, Studio.Local;  100.64.0.7 fd7a:115c::1 user@host https://x/ studio",
                                      excluding: "studio")
        XCTAssertEqual(routes, ["studio.local", "100.64.0.7", "fd7a:115c::1"])
    }

    func testParseCapsTheList() {
        let many = (1...20).map { "h\($0).example" }.joined(separator: ",")
        XCTAssertEqual(HostRoutes.parse(many, excluding: "x").count, HostRoutes.maxRoutes)
    }

    func testCandidatesPutThePrimaryFirst() {
        XCTAssertEqual(HostRoutes.candidates(primary: "studio", routes: ["studio.ts.example", "studio"]),
                       ["studio", "studio.ts.example"])
        XCTAssertEqual(HostRoutes.candidates(primary: "studio", routes: nil), ["studio"])
    }
}

final class RouteRaceTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    func testPreferredRouteWinsWhenBothAnswer() {
        let discarded = Counter()
        let result = RouteRace.first(["lan", "tailnet"], stagger: 0.2,
                                     connect: { route in Thread.sleep(forTimeInterval: 0.02); return route },
                                     discard: { discarded.add($0) })
        XCTAssertEqual(result?.route, "lan")
        XCTAssertEqual(discarded.all, [])
    }

    func testFailingRouteHandsOverWithoutWaitingOutTheStagger() {
        let started = Date()
        let result = RouteRace.first(["lan", "tailnet"], stagger: 5,
                                     connect: { $0 == "lan" ? nil : $0 }, discard: { _ in })
        XCTAssertEqual(result?.route, "tailnet")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testHangingRouteDoesNotHoldTheOthersBack() {
        let discarded = Counter()
        let started = Date()
        let result = RouteRace.first(["lan", "tailnet"], stagger: 0.1,
                                     connect: { route in
                                         if route == "lan" { Thread.sleep(forTimeInterval: 1.0) }
                                         return route
                                     },
                                     discard: { discarded.add($0) })
        XCTAssertEqual(result?.route, "tailnet")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
        // The slow route still completes later; its connection must be thrown away.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(discarded.all, ["lan"])
    }

    func testNothingAnswers() {
        XCTAssertNil(RouteRace.first(["a", "b", "c"], stagger: 0.05, connect: { _ -> String? in nil }, discard: { _ in }))
    }

    func testSingleRouteIsDialedDirectly() {
        XCTAssertEqual(RouteRace.first(["only"], connect: { $0 }, discard: { _ in })?.value, "only")
        XCTAssertNil(RouteRace.first([], connect: { $0 }, discard: { _ in }))
    }
}
