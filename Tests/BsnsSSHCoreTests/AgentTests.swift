import Foundation
import CryptoKit
import Testing
@testable import BsnsSSHCore

@Suite("Agent + SSH-agent protocol")
struct AgentTests {

    @Test("lists added identities in insertion order")
    func identities() async throws {
        let agent = Agent()
        await agent.add(try FileKey.generate(algorithm: .ed25519, comment: "a"))
        await agent.add(try FileKey.generate(algorithm: .ecdsaP256, comment: "b"))
        let ids = await agent.identities()
        #expect(ids.count == 2)
        #expect(ids[0].comment == "a")
        #expect(ids[1].comment == "b")
    }

    @Test("REQUEST_IDENTITIES answer lists the keys")
    func requestIdentities() async throws {
        let agent = Agent()
        let key = try FileKey.generate(algorithm: .ed25519, comment: "me@host")
        await agent.add(key)

        let request = Data([SSHAgentMessageType.requestIdentities.rawValue])
        let response = await agent.handleAgentMessage(request, context: SignContext(purpose: .sshUserAuth))

        var dec = SSHDecoder(response)
        #expect(try dec.readByte() == SSHAgentMessageType.identitiesAnswer.rawValue)
        #expect(try dec.readUInt32() == 1)
        #expect(try dec.readString() == key.publicKey.blob)
        #expect(try dec.readStringUTF8() == "me@host")
    }

    @Test("SIGN_REQUEST returns a verifiable signature")
    func signRequest() async throws {
        let agent = Agent()
        let key = try FileKey.generate(algorithm: .ed25519)
        await agent.add(key)

        let message = Data("challenge".utf8)
        let request = SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.signRequest.rawValue)
            $0.writeString(key.publicKey.blob)
            $0.writeString(message)
            $0.writeUInt32(0)
        }
        let response = await agent.handleAgentMessage(request, context: SignContext(purpose: .sshUserAuth))

        var dec = SSHDecoder(response)
        #expect(try dec.readByte() == SSHAgentMessageType.signResponse.rawValue)
        var sigDec = SSHDecoder(try dec.readString())
        #expect(try sigDec.readStringUTF8() == "ssh-ed25519")
        let body = try sigDec.readString()

        let publicKey = try FileKeyTests.ed25519PublicKey(from: key.publicKey.blob)
        #expect(publicKey.isValidSignature(body, for: message))
    }

    @Test("SIGN_REQUEST for an unknown key returns FAILURE")
    func signUnknownKey() async throws {
        let agent = Agent()
        await agent.add(try FileKey.generate(algorithm: .ed25519))
        let unknownBlob = try FileKey.generate(algorithm: .ed25519).publicKey.blob

        let request = SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.signRequest.rawValue)
            $0.writeString(unknownBlob)
            $0.writeString(Data("x".utf8))
            $0.writeUInt32(0)
        }
        let response = await agent.handleAgentMessage(request, context: SignContext(purpose: .sshUserAuth))
        #expect(response == Data([SSHAgentMessageType.failure.rawValue]))
    }
}
