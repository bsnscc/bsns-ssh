import XCTest
@testable import BsnsSSHCore

final class SessionHandoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ host: String = "dev.example", tmux: String? = "main", user: String = "me") -> HandoffSession {
        HandoffSession(id: UUID(), title: "\(user)@\(host)", host: host, port: 22, user: user,
                       useMosh: true, keyBlob: Data([1, 2, 3]), tmuxSession: tmux)
    }

    private func document(_ device: String, age: TimeInterval = 60, _ sessions: [HandoffSession]) -> HandoffDocument {
        HandoffDocument(deviceID: device, deviceName: "Device \(device)", updatedAt: now.addingTimeInterval(-age), sessions: sessions)
    }

    func testFileNamesRoundTripAndRejectStrangers() {
        let name = SessionHandoff.fileName(deviceID: "a1b2c3d4e5f6")
        XCTAssertEqual(SessionHandoff.deviceID(fromFileName: name), "a1b2c3d4e5f6")
        XCTAssertNil(SessionHandoff.deviceID(fromFileName: "bsns-ssh-sync.json"))
        XCTAssertNil(SessionHandoff.deviceID(fromFileName: "bsns-ssh-sessions-.json"))
        XCTAssertNil(SessionHandoff.deviceID(fromFileName: "bsns-ssh-sessions-../../x.json"))
        XCTAssertNil(SessionHandoff.deviceID(fromFileName: "bsns-ssh-sessions-ABCDEF.json"))
        XCTAssertNil(SessionHandoff.deviceID(fromFileName: "bsns-ssh-sessions-a1b2c3 (conflicted copy).json"))
    }

    func testDocumentRoundTrips() throws {
        let original = document("phone-01", [session(), session("db.example", tmux: nil)])
        XCTAssertEqual(try SessionHandoff.decode(try SessionHandoff.encode(original)), original)
    }

    func testNewerVersionAndBadDeviceAreRejected() throws {
        var future = document("phone-01", [])
        future.version = SessionHandoff.version + 1
        let data = try SessionHandoff.encode(future)
        XCTAssertThrowsError(try SessionHandoff.decode(data)) {
            XCTAssertEqual($0 as? SessionHandoff.HandoffError, .unsupportedVersion(SessionHandoff.version + 1))
        }
        XCTAssertThrowsError(try SessionHandoff.encode(document("../evil", [])))
    }

    func testOwnDeviceIsNeverOffered() {
        let offers = SessionHandoff.offers(from: [document("mac-0001", [session()])], thisDevice: "mac-0001", openHere: [], now: now)
        XCTAssertTrue(offers.isEmpty)
    }

    func testWorkAlreadyOpenHereIsLeftOut() {
        let theirs = session()
        let other = session("build.example")
        let offers = SessionHandoff.offers(from: [document("phone-01", [theirs, other])], thisDevice: "mac-0001",
                                           openHere: [session("DEV.example")], now: now)
        XCTAssertEqual(offers.map(\.session.host), ["build.example"])
    }

    func testShellsWithoutTmuxAreNeverTreatedAsTheSameWork() {
        let offers = SessionHandoff.offers(from: [document("phone-01", [session(tmux: nil)])], thisDevice: "mac-0001",
                                           openHere: [session(tmux: nil)], now: now)
        XCTAssertEqual(offers.count, 1)
        XCTAssertFalse(offers[0].continuesWork)
    }

    func testDifferentUserOrTmuxNameIsDifferentWork() {
        let offers = SessionHandoff.offers(from: [document("phone-01", [session(user: "root"), session(tmux: "other")])],
                                           thisDevice: "mac-0001", openHere: [session()], now: now)
        XCTAssertEqual(offers.count, 2)
    }

    func testSameWorkOnTwoDevicesIsOfferedOnceFromTheNewest() {
        let offers = SessionHandoff.offers(from: [document("phone-01", age: 3600, [session()]),
                                                  document("tablet-1", age: 60, [session()])],
                                           thisDevice: "mac-0001", openHere: [], now: now)
        XCTAssertEqual(offers.map(\.deviceID), ["tablet-1"])
    }

    func testDevicesLongOutOfUseAreDropped() {
        let offers = SessionHandoff.offers(from: [document("phone-01", age: SessionHandoff.maxAge + 1, [session()])],
                                           thisDevice: "mac-0001", openHere: [], now: now)
        XCTAssertTrue(offers.isEmpty)
    }
}
