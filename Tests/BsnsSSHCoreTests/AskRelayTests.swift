import XCTest
@testable import BsnsSSHCore

final class AskRelayTests: XCTestCase {
    private func pair() throws -> (mac: RelayChannel, phone: RelayChannel, stranger: RelayChannel) {
        let mac = LinkIdentity(), phone = LinkIdentity(), other = LinkIdentity()
        return (try RelayChannel(identity: mac, peer: LinkPeer(publicKey: phone.publicKey, name: "phone")),
                try RelayChannel(identity: phone, peer: LinkPeer(publicKey: mac.publicKey, name: "mac")),
                try RelayChannel(identity: other, peer: LinkPeer(publicKey: mac.publicKey, name: "mac")))
    }

    func testAskAndAnswerRoundTrip() throws {
        let (mac, phone, _) = try pair()
        let ask = Ask(text: "Deploy integration to prod?", options: ["approve", "rollback"], machine: "studio", source: "deploy")
        let received: Ask = try phone.open(try mac.seal(ask, as: .ask), as: .ask)
        XCTAssertEqual(received, ask)
        let answer = AskAnswer(askID: ask.id, choice: "approve")
        let back: AskAnswer = try mac.open(try phone.seal(answer, as: .answer), as: .answer)
        XCTAssertTrue(ask.accepts(back))
    }

    func testOnlyThePairedDeviceCanReadOrAnswer() throws {
        let (mac, _, stranger) = try pair()
        let sealed = try mac.seal(Ask(text: "x", options: ["y"], machine: "m"), as: .ask)
        XCTAssertThrowsError(try stranger.open(sealed, as: .ask, Ask.self))
        // A device that isn't the paired phone can't produce an answer the Mac accepts.
        let forged = try stranger.seal(AskAnswer(askID: UUID(), choice: "y"), as: .answer)
        XCTAssertThrowsError(try mac.open(forged, as: .answer, AskAnswer.self))
    }

    func testMessagesCannotBeAlteredRelabelledOrTurnedAround() throws {
        let (mac, phone, _) = try pair()
        let ask = Ask(text: "x", options: ["approve"], machine: "m")
        let sealed = try mac.seal(ask, as: .ask)
        var tampered = sealed
        tampered[tampered.count - 20] ^= 1
        XCTAssertThrowsError(try phone.open(tampered, as: .ask, Ask.self))
        var relabelled = sealed
        relabelled[1] = RelayChannel.Kind.answer.rawValue
        XCTAssertThrowsError(try phone.open(relabelled, as: .answer, AskAnswer.self))
        XCTAssertThrowsError(try phone.open(sealed, as: .answer, AskAnswer.self)) { XCTAssertEqual($0 as? RelayChannel.RelayError, .wrongKind) }
        // The author's own message, sent back to it, doesn't open either.
        XCTAssertThrowsError(try mac.open(sealed, as: .ask, Ask.self))
        XCTAssertThrowsError(try phone.open(Data([1, 1, 2, 3]), as: .ask, Ask.self))
    }

    func testAnAnswerMustPickAnOfferedOptionInTime() {
        let ask = Ask(text: "Deploy?", options: ["approve", "rollback"], machine: "m", created: Date(timeIntervalSince1970: 1000), lifetime: 60)
        let at = Date(timeIntervalSince1970: 1030)
        XCTAssertTrue(ask.accepts(AskAnswer(askID: ask.id, choice: "rollback"), now: at))
        XCTAssertFalse(ask.accepts(AskAnswer(askID: ask.id, choice: "rm -rf /"), now: at))
        XCTAssertFalse(ask.accepts(AskAnswer(askID: UUID(), choice: "approve"), now: at))
        XCTAssertFalse(ask.accepts(AskAnswer(askID: ask.id, choice: "approve"), now: Date(timeIntervalSince1970: 1061)))
    }

    func testLimitsAndRecordNames() {
        let ask = Ask(text: String(repeating: "x", count: 5000), options: (1...9).map { "option-\($0)-" + String(repeating: "y", count: 80) }, machine: "m")
        XCTAssertEqual(ask.text.count, Ask.maxText)
        XCTAssertEqual(ask.options.count, Ask.maxOptions)
        XCTAssertTrue(ask.options.allSatisfy { $0.count <= Ask.maxOptionLength })
        XCTAssertFalse(Ask(text: "done", machine: "m").isQuestion)
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(RelayChannel.recordName(.answer, askID: id, to: "abc123"), "answer-11111111-2222-3333-4444-555555555555-abc123")
    }
}
