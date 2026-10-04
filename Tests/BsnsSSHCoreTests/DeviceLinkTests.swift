import XCTest
import CryptoKit
@testable import BsnsSSHCore

final class DeviceLinkTests: XCTestCase {
    private func pair(_ mac: LinkIdentity, _ phone: LinkIdentity) throws -> (mac: PairingOutcome, phone: PairingOutcome) {
        let initiator = PairingInitiator(identity: mac, name: "Studio")
        var responder = PairingResponder(identity: phone, name: "Phone")
        let response = try responder.respond(toHello: initiator.hello())
        let (reveal, macView) = try initiator.reveal(afterResponse: response)
        return (macView, try responder.finish(reveal: reveal))
    }

    func testPairingGivesBothSidesTheSameCodeAndEachOthersKey() throws {
        let mac = LinkIdentity(), phone = LinkIdentity()
        let result = try pair(mac, phone)
        XCTAssertEqual(result.mac.code, result.phone.code)
        XCTAssertEqual(result.mac.code.count, 6)
        XCTAssertEqual(result.mac.peer.publicKey, phone.publicKey)
        XCTAssertEqual(result.phone.peer.publicKey, mac.publicKey)
        XCTAssertEqual(result.mac.peer.name, "Phone")
        XCTAssertEqual(result.phone.peer.name, "Studio")
    }

    func testTheHelloDoesNotRevealTheKey() {
        let mac = LinkIdentity()
        let hello = PairingInitiator(identity: mac, name: "Studio").hello()
        XCTAssertNil(hello.range(of: mac.publicKey))
    }

    func testAManInTheMiddleChangesTheCode() throws {
        // The attacker answers the computer with its own key, and pairs with the
        // phone as itself. Each device ends up paired with the attacker — and
        // shows a different code, which is what the user is asked to compare.
        let mac = LinkIdentity(), phone = LinkIdentity(), attacker = LinkIdentity()
        let macSide = try pair(mac, attacker).mac
        let phoneSide = try pair(attacker, phone).phone
        XCTAssertNotEqual(macSide.code, phoneSide.code)
    }

    func testARevealThatDoesNotMatchTheCommitmentIsRejected() throws {
        let mac = LinkIdentity(), phone = LinkIdentity(), other = LinkIdentity()
        let committed = PairingInitiator(identity: mac, name: "Studio")
        var responder = PairingResponder(identity: phone, name: "Phone")
        let response = try responder.respond(toHello: committed.hello())
        // Reveal a different key than the one committed to — what an attacker
        // would do to steer the code after seeing the phone's key.
        let swapped = try PairingInitiator(identity: other, name: "Studio").reveal(afterResponse: response).reveal
        XCTAssertThrowsError(try responder.finish(reveal: swapped)) {
            XCTAssertEqual($0 as? DeviceLink.LinkError, .commitmentMismatch)
        }
    }

    func testNamesAreBoundIntoTheCode() throws {
        let mac = LinkIdentity(), phone = LinkIdentity()
        let initiator = PairingInitiator(identity: mac, name: "Studio")
        var a = PairingResponder(identity: phone, name: "Phone")
        let codeA = try initiator.reveal(afterResponse: a.respond(toHello: initiator.hello())).outcome.code
        // Same keys and nonce on the initiator side, different responder name.
        var b = PairingResponder(identity: phone, name: "Someone else")
        let codeB = try initiator.reveal(afterResponse: b.respond(toHello: initiator.hello())).outcome.code
        XCTAssertNotEqual(codeA, codeB)
    }

    private func session(_ mac: LinkIdentity, _ phone: LinkIdentity,
                         paired: Bool = true) throws -> (mac: LinkSession, phone: LinkSession) {
        let initiator = SessionInitiator(identity: mac, peer: LinkPeer(publicKey: phone.publicKey, name: "Phone"))
        let accepted = try SessionResponder.accept(hello: initiator.hello(), identity: phone) { _ in paired }
        XCTAssertEqual(accepted.peerPublicKey, mac.publicKey)
        return (try initiator.finish(response: accepted.response), accepted.session)
    }

    func testSessionCarriesMessagesBothWays() throws {
        var (mac, phone) = try session(LinkIdentity(), LinkIdentity())
        let request = try mac.seal(Data("sign this".utf8))
        XCTAssertNil(request.range(of: Data("sign this".utf8)))
        XCTAssertEqual(try phone.open(request), Data("sign this".utf8))
        XCTAssertEqual(try mac.open(try phone.seal(Data("signed".utf8))), Data("signed".utf8))
        XCTAssertEqual(try phone.open(try mac.seal(Data("again".utf8))), Data("again".utf8))
    }

    func testAnUnpairedDeviceIsRefused() {
        XCTAssertThrowsError(try session(LinkIdentity(), LinkIdentity(), paired: false)) {
            XCTAssertEqual($0 as? DeviceLink.LinkError, .unknownPeer)
        }
    }

    func testClaimingAPairedKeyWithoutHoldingItFails() throws {
        // The attacker knows the computer's PUBLIC key (it is sent in the clear)
        // and claims it. The phone accepts the hello — the key is on its list —
        // but the attacker can't derive the session keys, so nothing it sends opens.
        let mac = LinkIdentity(), phone = LinkIdentity(), attacker = LinkIdentity()
        let genuineHello = SessionInitiator(identity: mac, peer: LinkPeer(publicKey: phone.publicKey, name: "")).hello()
        var accepted = try SessionResponder.accept(hello: genuineHello, identity: phone) { $0 == mac.publicKey }
        // The attacker completes "its" side with its own key in place of the computer's.
        var forged = try SessionInitiator(identity: attacker, peer: LinkPeer(publicKey: phone.publicKey, name: ""))
            .finish(response: accepted.response)
        XCTAssertThrowsError(try accepted.session.open(try forged.seal(Data("list keys".utf8)))) {
            XCTAssertEqual($0 as? DeviceLink.LinkError, .authenticationFailed)
        }
    }

    func testAPhoneImpersonatorCannotAnswer() throws {
        // Someone else answers the computer's hello. Without the phone's
        // long-term key its replies don't open on the computer.
        let mac = LinkIdentity(), phone = LinkIdentity(), impostor = LinkIdentity()
        let initiator = SessionInitiator(identity: mac, peer: LinkPeer(publicKey: phone.publicKey, name: "Phone"))
        var fake = try SessionResponder.accept(hello: initiator.hello(), identity: impostor) { _ in true }
        var macSession = try initiator.finish(response: fake.response)
        XCTAssertThrowsError(try macSession.open(try fake.session.seal(Data("fake signature".utf8))))
    }

    func testReplayedReorderedAndTamperedMessagesAreRejected() throws {
        var (mac, phone) = try session(LinkIdentity(), LinkIdentity())
        let first = try mac.seal(Data("one".utf8))
        let second = try mac.seal(Data("two".utf8))
        XCTAssertThrowsError(try phone.open(second))          // out of order
        XCTAssertEqual(try phone.open(first), Data("one".utf8))
        XCTAssertThrowsError(try phone.open(first))           // replay
        var tampered = second
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try phone.open(tampered))
        XCTAssertEqual(try phone.open(second), Data("two".utf8))
        // A message can't be bounced back at its sender either.
        XCTAssertThrowsError(try mac.open(try mac.seal(Data("echo".utf8))))
    }

    func testEachSessionHasItsOwnKeys() throws {
        let mac = LinkIdentity(), phone = LinkIdentity()
        var (firstMac, _) = try session(mac, phone)
        var (_, secondPhone) = try session(mac, phone)
        XCTAssertThrowsError(try secondPhone.open(try firstMac.seal(Data("old session".utf8))))
    }

    func testLowOrderKeysAreRefused() {
        let phone = LinkIdentity()
        let zeroKey = Data(repeating: 0, count: 32)
        let hello = SSHEncoder.build {
            $0.writeByte(0x53); $0.writeByte(DeviceLink.version)
            $0.writeString(zeroKey); $0.writeString(zeroKey)
        }
        XCTAssertThrowsError(try SessionResponder.accept(hello: hello, identity: phone) { _ in true }) {
            XCTAssertEqual($0 as? DeviceLink.LinkError, .weakKey)
        }
    }

    func testIdentityRoundTripsAndHasAStableID() throws {
        let identity = LinkIdentity()
        let restored = try LinkIdentity(privateKeyData: identity.privateKeyData)
        XCTAssertEqual(restored.publicKey, identity.publicKey)
        XCTAssertEqual(restored.deviceID, identity.deviceID)
        XCTAssertEqual(identity.deviceID.count, 12)
        XCTAssertNotEqual(identity.deviceID, LinkIdentity().deviceID)
    }

    func testRequestRoundTripsAndStripsControlCharacters() throws {
        let request = LinkRequest(agentPayload: Data([13, 1, 2]), requester: "ssh (git)", host: "box", user: "me")
        XCTAssertEqual(try LinkRequest(decoding: request.encoded()), request)
        let hostile = LinkRequest(agentPayload: Data([11]), requester: "ssh\nApprove everything", host: "", user: nil)
        let decoded = try LinkRequest(decoding: hostile.encoded())
        XCTAssertEqual(decoded.requester, "sshApprove everything")
        XCTAssertNil(decoded.host)
        XCTAssertThrowsError(try LinkRequest(decoding: Data([1, 2, 3])))
    }
}

final class RemoteAgentKeyTests: XCTestCase {
    /// A computer's agent using a key held by a phone's agent, with the device
    /// link's encryption in between — everything but the socket.
    func testSigningThroughAPairedDevice() async throws {
        let phoneAgent = Agent()
        let phoneKey = try FileKey.generate(algorithm: .ed25519, comment: "phone key")
        await phoneAgent.add(phoneKey)
        let seen = ContextBox()

        let macIdentity = LinkIdentity(), phoneIdentity = LinkIdentity()
        let transport: @Sendable (LinkRequest) async throws -> Data = { request in
            let initiator = SessionInitiator(identity: macIdentity, peer: LinkPeer(publicKey: phoneIdentity.publicKey, name: "Phone"))
            var accepted = try SessionResponder.accept(hello: initiator.hello(), identity: phoneIdentity) { $0 == macIdentity.publicKey }
            var macSession = try initiator.finish(response: accepted.response)
            let received = try LinkRequest(decoding: try accepted.session.open(try macSession.seal(request.encoded())))
            seen.set(received)
            let context = SignContext(host: received.host, purpose: .remoteAgent, requester: received.requester, user: received.user)
            let answer = await phoneAgent.handleAgentMessage(received.agentPayload, context: context)
            return try macSession.open(try accepted.session.seal(answer))
        }

        let listing = try await transport(LinkRequest(agentPayload: Data([SSHAgentMessageType.requestIdentities.rawValue])))
        let identities = RemoteAgentKey.identities(inAnswer: listing)
        XCTAssertEqual(identities.map(\.blob), [phoneKey.publicKey.blob])
        XCTAssertEqual(identities.first?.comment, "phone key")

        let macAgent = Agent()
        let remote = RemoteAgentKey(publicKey: identities[0], transport: transport)
        await macAgent.add(remote)
        XCTAssertTrue(remote.requiresUserPresence)

        let data = Data("challenge".utf8)
        let context = SignContext(host: "build-box", purpose: .remoteAgent, requester: "ssh", user: "graham")
        let viaLink = try await macAgent.sign(keyID: remote.id, data: data, context: context)
        // The signature that came back over the link verifies under the phone's key.
        var signature = SSHDecoder(viaLink.blob)
        XCTAssertEqual(try signature.readStringUTF8(), "ssh-ed25519")
        let raw = try signature.readString()
        var blob = SSHDecoder(phoneKey.publicKey.blob)
        _ = try blob.readString()
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: try blob.readString())
        XCTAssertTrue(verifier.isValidSignature(raw, for: data))
        XCTAssertEqual(seen.value?.host, "build-box")
        XCTAssertEqual(seen.value?.requester, "ssh")
        XCTAssertEqual(seen.value?.user, "graham")
    }

    func testADeclineOnTheOtherDeviceIsACancel() async {
        let key = SSHPublicKey(blob: Data([0, 0, 0, 1, 65]), algorithm: .ed25519)
        let declined = RemoteAgentKey(publicKey: key) { _ in Data([SSHAgentMessageType.failure.rawValue]) }
        do {
            _ = try await declined.sign(Data([1]), context: SignContext(purpose: .remoteAgent))
            XCTFail("expected a cancel")
        } catch KeyBackendError.userCancelled {
        } catch { XCTFail("unexpected \(error)") }

        struct Offline: Error {}
        let unreachable = RemoteAgentKey(publicKey: key) { _ in throw Offline() }
        do {
            _ = try await unreachable.sign(Data([1]), context: SignContext(purpose: .remoteAgent))
            XCTFail("expected a failure")
        } catch KeyBackendError.signingFailed {
        } catch { XCTFail("unexpected \(error)") }
    }
}

private final class ContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: LinkRequest?
    func set(_ r: LinkRequest) { lock.withLock { request = r } }
    var value: LinkRequest? { lock.withLock { request } }
}
