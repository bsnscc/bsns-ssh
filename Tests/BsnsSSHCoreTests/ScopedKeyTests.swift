import XCTest
@testable import BsnsSSHCore

final class ScopedKeyTests: XCTestCase {
    private func scoped() throws -> ScopedKey {
        let key = try FileKey.from(algorithm: .ed25519, privateKeyMaterial: Data(repeating: 7, count: 32), comment: "peer")
        return ScopedKey(key, allowedHosts: ["Studio", "[laptop.local]:2222"])
    }

    func testSignsForAnAllowedHostFromTheAppItself() async throws {
        let key = try scoped()
        _ = try await key.sign(Data("x".utf8), context: SignContext(host: "studio", purpose: .sshUserAuth))
        _ = try await key.sign(Data("x".utf8), context: SignContext(host: "LAPTOP.local", purpose: .sshUserAuth))
    }

    func testRefusesOtherHostsUnprovenHostsAndNonLogins() async throws {
        let key = try scoped()
        let refused: [SignContext] = [
            SignContext(host: "elsewhere.example", purpose: .sshUserAuth),
            SignContext(host: nil, purpose: .sshUserAuth),
            SignContext(host: "studio", purpose: .remoteAgent, requester: "ssh", hostProven: false),
            SignContext(host: "studio", purpose: .detachedSign),
        ]
        for context in refused {
            do {
                _ = try await key.sign(Data("x".utf8), context: context)
                XCTFail("signed for \(String(describing: context.host)) \(context.purpose)")
            } catch KeyBackendError.notPermitted {}
        }
    }

    /// Through the agent socket path: only a request whose signed data names
    /// the server's key counts, and only when that key is an allowed host's.
    func testOutsideProgramsNeedAHostBoundRequest() async throws {
        let agent = Agent()
        let key = try scoped()
        await agent.add(key)
        let audit = AuditBox()
        await agent.setAuditor { audit.add($0) }
        let studioKey = Data("studio-host-key".utf8), otherKey = Data("other-host-key".utf8)
        let connection = AgentClientConnection(agent: agent, requester: "ssh",
                                               hostName: { $0 == studioKey ? "studio" : nil })
        let session = Data(repeating: 9, count: 32)

        func signRequest(method: String, hostKey: Data?) -> Data {
            let signed = SSHEncoder.build {
                $0.writeString(session); $0.writeByte(50)
                $0.writeString(Data("dev".utf8)); $0.writeString(Data("ssh-connection".utf8))
                $0.writeString(Data(method.utf8)); $0.writeByte(1)
                $0.writeString(Data("ssh-ed25519".utf8)); $0.writeString(key.publicKey.blob)
                if let hostKey { $0.writeString(hostKey) }
            }
            return SSHEncoder.build {
                $0.writeByte(SSHAgentMessageType.signRequest.rawValue)
                $0.writeString(key.publicKey.blob); $0.writeString(signed); $0.writeUInt32(0)
            }
        }
        func answer(_ payload: Data) async -> UInt8 { await connection.respond(to: payload).first ?? 0 }
        let signed = SSHAgentMessageType.signResponse.rawValue, failure = SSHAgentMessageType.failure.rawValue

        // Bound to the allowed host inside the request itself: signed.
        let bound = await answer(signRequest(method: "publickey-hostbound-v00@openssh.com", hostKey: studioKey))
        XCTAssertEqual(bound, signed)
        // Bound to some other server: refused.
        let elsewhere = await answer(signRequest(method: "publickey-hostbound-v00@openssh.com", hostKey: otherKey))
        XCTAssertEqual(elsewhere, failure)
        // The program merely announces the allowed host, then asks for a
        // signature that would be valid anywhere: refused.
        let announce = SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.extension.rawValue)
            $0.writeString(Data("session-bind@openssh.com".utf8))
            $0.writeString(studioKey); $0.writeString(session); $0.writeString(Data()); $0.writeByte(0)
        }
        _ = await answer(announce)
        let claimed = await answer(signRequest(method: "publickey", hostKey: nil))
        XCTAssertEqual(claimed, failure)
        // Arbitrary data (not a login at all): refused.
        let raw = SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.signRequest.rawValue)
            $0.writeString(key.publicKey.blob); $0.writeString(Data("sign this".utf8)); $0.writeUInt32(0)
        }
        let arbitrary = await answer(raw)
        XCTAssertEqual(arbitrary, failure)
        XCTAssertEqual(audit.outcomes, [.signed, .refused, .refused, .refused])
    }

    func testHostNamesFromKnownHostsIdentifiers() {
        XCTAssertEqual(ScopedKey.hostName("[Studio.Local]:2222"), "studio.local")
        XCTAssertEqual(ScopedKey.hostName("Studio"), "studio")
    }
}

private final class AuditBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentAuditEvent] = []
    func add(_ event: AgentAuditEvent) { lock.withLock { events.append(event) } }
    var outcomes: [AgentAuditEvent.Outcome] { lock.withLock { events.map(\.outcome) } }
}
