import Foundation
import Dispatch
import BsnsSSHCore

// Drives a full connection through Agent -> FileKey -> SSHSession -> libssh2,
// proving build-order step 3: live auth delegated to the agent, host-key
// (TOFU) verification, and channel exec I/O.

func agentKeygen(_ keyPath: String) throws {
    let key = try FileKey.generate(algorithm: .ed25519, comment: "bsns-ssh-spike")
    try key.exportPrivateKeyMaterial().write(to: URL(fileURLWithPath: keyPath))
    print("ssh-ed25519 \(key.publicKey.blob.base64EncodedString()) bsns-ssh-spike")
}

private func loadAgent(_ keyPath: String) async throws -> Agent {
    let material = try Data(contentsOf: URL(fileURLWithPath: keyPath))
    let key = try FileKey.from(algorithm: .ed25519, privateKeyMaterial: material)
    let agent = Agent()
    await agent.add(key)
    return agent
}

func agentConnect(_ keyPath: String, _ host: String, _ port: UInt16, _ user: String) -> Int32 {
    runBlocking {
        let agent = try await loadAgent(keyPath)
        let (hostKey, verdict) = try await SSHSession().connect(host: host, port: port, user: user, agent: agent)
        print("host key \(hostKey.fingerprint) (\(hostKey.keyType)) — \(describe(verdict))")
        print("AUTH OK — connected through Agent → FileKey → libssh2; the key stayed in the agent")
    }
}

func agentExec(_ keyPath: String, _ host: String, _ port: UInt16, _ user: String, _ command: String) -> Int32 {
    runBlocking {
        let agent = try await loadAgent(keyPath)
        let output = try await SSHSession().runCommand(command, host: host, port: port, user: user, agent: agent)
        print("CHANNEL OUTPUT >>>")
        print(output, terminator: "")
        print("<<< AUTH + EXEC OK through the agent")
    }
}

// MARK: helpers

private func describe(_ verdict: HostVerification) -> String {
    switch verdict {
    case .trusted: return "trusted"
    case let .unknown(fingerprint): return "TOFU first contact (\(fingerprint))"
    case let .mismatch(stored, presented): return "MISMATCH stored=\(stored) presented=\(presented)"
    }
}

/// Run an async body to completion from synchronous `main`, returning a
/// process exit code.
private func runBlocking(_ body: @escaping @Sendable () async throws -> Void) -> Int32 {
    final class ResultCode: @unchecked Sendable { var value: Int32 = 1 }
    let result = ResultCode()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            try await body()
            result.value = 0
        } catch {
            print("FAILED: \(error)")
            result.value = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result.value
}
