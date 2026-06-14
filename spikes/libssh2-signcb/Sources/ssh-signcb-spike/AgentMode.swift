import Foundation
import Dispatch
import BsnsSSHCore

// Drives a full connection through Agent -> FileKey -> SSHSession -> libssh2,
// proving build-order step 3: the live auth is delegated to the agent.

func agentKeygen(_ keyPath: String) throws {
    let key = try FileKey.generate(algorithm: .ed25519, comment: "bsns-ssh-spike")
    try key.exportPrivateKeyMaterial().write(to: URL(fileURLWithPath: keyPath))
    print("ssh-ed25519 \(key.publicKey.blob.base64EncodedString()) bsns-ssh-spike")
}

func agentConnect(_ keyPath: String, _ host: String, _ port: UInt16, _ user: String) -> Int32 {
    let material: Data
    do {
        material = try Data(contentsOf: URL(fileURLWithPath: keyPath))
    } catch {
        print("key load failed: \(error)")
        return 1
    }

    final class ResultCode: @unchecked Sendable { var value: Int32 = 1 }
    let result = ResultCode()
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        do {
            let key = try FileKey.from(algorithm: .ed25519, privateKeyMaterial: material)
            let agent = Agent()
            await agent.add(key)
            try await SSHSession().connect(host: host, port: port, user: user, agent: agent)
            print("AUTH OK — connected through Agent → FileKey → libssh2; the key stayed in the agent")
            result.value = 0
        } catch {
            print("AUTH FAILED: \(error)")
            result.value = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result.value
}
