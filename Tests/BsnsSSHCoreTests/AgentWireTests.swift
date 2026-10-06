import XCTest
@testable import BsnsSSHCore

final class AgentWireTests: XCTestCase {
    private func userAuthData(sessionID: Data, user: String) -> Data {
        SSHEncoder.build {
            $0.writeString(sessionID)
            $0.writeByte(50)
            $0.writeString(user)
            $0.writeString("ssh-connection")
            $0.writeString("publickey")
            $0.writeByte(1)
            $0.writeString("ssh-ed25519")
            $0.writeString(Data([1, 2, 3]))
        }
    }

    private func signRequest(key: Data, data: Data) -> Data {
        SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.signRequest.rawValue)
            $0.writeString(key)
            $0.writeString(data)
            $0.writeUInt32(0)
        }
    }

    private func sessionBind(hostKey: Data, sessionID: Data) -> Data {
        SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.extension.rawValue)
            $0.writeString("session-bind@openssh.com")
            $0.writeString(hostKey)
            $0.writeString(sessionID)
            $0.writeString(Data([9, 9]))   // signature
            $0.writeByte(0)                // is_forwarding
        }
    }

    func testFrameReaderSplitsAndReassembles() throws {
        var reader = AgentFrameReader()
        let a = AgentFrameReader.frame(Data([11]))
        let b = AgentFrameReader.frame(Data([13, 1, 2, 3]))
        let stream = a + b
        reader.append(stream.prefix(3))
        XCTAssertNil(try reader.next())
        reader.append(stream.dropFirst(3).prefix(4))
        XCTAssertEqual(try reader.next(), Data([11]))
        XCTAssertNil(try reader.next())
        reader.append(stream.dropFirst(7))
        XCTAssertEqual(try reader.next(), Data([13, 1, 2, 3]))
        XCTAssertNil(try reader.next())
    }

    func testFrameReaderRejectsOversizeFrames() {
        var reader = AgentFrameReader()
        reader.append(Data([0x7f, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try reader.next()) { XCTAssertEqual($0 as? AgentFrameReader.FrameError, .tooLarge) }
    }

    func testParsesUserAuthRequests() {
        let sid = Data(repeating: 7, count: 32)
        let parsed = AgentWire.userAuthRequest(signedData: userAuthData(sessionID: sid, user: "dev"))
        XCTAssertEqual(parsed?.sessionID, sid)
        XCTAssertEqual(parsed?.user, "dev")
        // A signature request that isn't a login (an SSH signature over a file).
        XCTAssertNil(AgentWire.userAuthRequest(signedData: Data("SSHSIG...".utf8)))
    }

    func testConnectionAttachesHostUserAndRequester() async throws {
        let agent = Agent()
        let key = try FileKey.generate(algorithm: .ed25519, comment: "test")
        await agent.add(key)
        let events = EventBox()
        await agent.setAuditor { events.append($0) }

        let hostKey = Data("host-key-blob".utf8)
        let sid = Data(repeating: 3, count: 32)
        let connection = AgentClientConnection(agent: agent, requester: "ssh",
                                               hostName: { $0 == hostKey ? "build-box" : nil })
        let bound = await connection.respond(to: sessionBind(hostKey: hostKey, sessionID: sid))
        XCTAssertEqual(bound, Data([SSHAgentMessageType.success.rawValue]))

        let response = await connection.respond(to: signRequest(key: key.publicKey.blob,
                                                                data: userAuthData(sessionID: sid, user: "dev")))
        XCTAssertEqual(response.first, SSHAgentMessageType.signResponse.rawValue)
        XCTAssertEqual(events.all.count, 1)
        XCTAssertEqual(events.all.first?.host, "build-box")
        XCTAssertEqual(events.all.first?.user, "dev")
        XCTAssertEqual(events.all.first?.requester, "ssh")
        XCTAssertEqual(events.all.first?.outcome, .signed)
        XCTAssertEqual(events.all.first?.keyFingerprint, key.id.rawValue)
    }

    func testUnboundSessionHasNoHostAndUnknownHostFallsBackToFingerprint() async throws {
        let agent = Agent()
        let key = try FileKey.generate(algorithm: .ed25519)
        await agent.add(key)
        let events = EventBox()
        await agent.setAuditor { events.append($0) }
        let connection = AgentClientConnection(agent: agent, requester: "git")

        let sid = Data(repeating: 5, count: 32)
        _ = await connection.respond(to: signRequest(key: key.publicKey.blob, data: userAuthData(sessionID: sid, user: "git")))
        XCTAssertNil(events.all.last?.host)

        let hostKey = Data("another-host-key".utf8)
        _ = await connection.respond(to: sessionBind(hostKey: hostKey, sessionID: sid))
        _ = await connection.respond(to: signRequest(key: key.publicKey.blob, data: userAuthData(sessionID: sid, user: "git")))
        XCTAssertEqual(events.all.last?.host, SSHKeyFormat.fingerprint(ofPublicKeyBlob: hostKey))
    }

    func testExposureFilterHidesAndRefusesKeys() async throws {
        let agent = Agent()
        let visible = try FileKey.generate(algorithm: .ed25519, comment: "visible")
        let hidden = try FileKey.generate(algorithm: .ed25519, comment: "hidden")
        await agent.add(visible)
        await agent.add(hidden)
        let connection = AgentClientConnection(agent: agent, requester: "ssh",
                                               exposing: { $0.publicKey.comment == "visible" })

        let listing = await connection.respond(to: Data([SSHAgentMessageType.requestIdentities.rawValue]))
        var decoder = SSHDecoder(listing)
        XCTAssertEqual(try decoder.readByte(), SSHAgentMessageType.identitiesAnswer.rawValue)
        XCTAssertEqual(try decoder.readUInt32(), 1)
        XCTAssertEqual(try decoder.readString(), visible.publicKey.blob)

        // Naming a key that wasn't offered must not work either.
        let refused = await connection.respond(to: signRequest(key: hidden.publicKey.blob, data: Data([1])))
        XCTAssertEqual(refused, Data([SSHAgentMessageType.failure.rawValue]))
        let allowed = await connection.respond(to: signRequest(key: visible.publicKey.blob, data: Data([1])))
        XCTAssertEqual(allowed.first, SSHAgentMessageType.signResponse.rawValue)
    }

    func testHostBoundRequestNamesTheHostWithoutASessionBind() async throws {
        let agent = Agent()
        let key = try FileKey.generate(algorithm: .ed25519)
        await agent.add(key)
        let events = EventBox()
        await agent.setAuditor { events.append($0) }
        let hostKey = Data("bound-host-key".utf8)
        let connection = AgentClientConnection(agent: agent, requester: "ssh", hostName: { $0 == hostKey ? "db-1" : nil })
        // What current OpenSSH signs: the usual request with the host key appended.
        let data = SSHEncoder.build {
            $0.writeString(Data(repeating: 1, count: 32))
            $0.writeByte(50)
            $0.writeString("deploy")
            $0.writeString("ssh-connection")
            $0.writeString("publickey-hostbound-v00@openssh.com")
            $0.writeByte(1)
            $0.writeString("ssh-ed25519")
            $0.writeString(key.publicKey.blob)
            $0.writeString(hostKey)
        }
        _ = await connection.respond(to: signRequest(key: key.publicKey.blob, data: data))
        XCTAssertEqual(events.all.last?.host, "db-1")
        XCTAssertEqual(events.all.last?.user, "deploy")
    }

    func testUnknownExtensionFails() async {
        let connection = AgentClientConnection(agent: Agent(), requester: nil)
        let payload = SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.extension.rawValue)
            $0.writeString("something-else@example.com")
        }
        let response = await connection.respond(to: payload)
        XCTAssertEqual(response, Data([SSHAgentMessageType.failure.rawValue]))
    }

    func testPromptReason() {
        XCTAssertEqual(SignContext(host: "box", purpose: .remoteAgent, requester: "ssh", user: "me").promptReason,
                       "ssh wants to sign in to me@box")
        XCTAssertEqual(SignContext(purpose: .remoteAgent, requester: "git").promptReason, "git wants to use this key")
        XCTAssertEqual(SignContext(host: "box", purpose: .sshUserAuth).promptReason, "Sign in to box")
        XCTAssertEqual(SignContext(purpose: .sshUserAuth).promptReason, "Authorize SSH sign-in")
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentAuditEvent] = []
    func append(_ event: AgentAuditEvent) { lock.withLock { events.append(event) } }
    var all: [AgentAuditEvent] { lock.withLock { events } }
}
