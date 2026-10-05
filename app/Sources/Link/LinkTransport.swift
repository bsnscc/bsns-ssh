import Foundation
import Network
import BsnsSSHCore

/// One TCP connection between two of the user's devices on the local network,
/// carrying length-prefixed frames. What the frames mean — pairing, a session
/// handshake, encrypted requests — is the core's business (`DeviceLink`); this
/// is only the wire.
final class LinkConnection: @unchecked Sendable {
    /// Larger than any frame the protocol sends (a sign request carries a
    /// session hash, an identities answer a handful of public keys).
    static let maxFrame = 512 * 1024

    enum TransportError: LocalizedError {
        case closed, tooLarge, timedOut
        var errorDescription: String? {
            switch self {
            case .closed: return "The other device closed the connection."
            case .tooLarge: return "The other device sent something unexpected."
            case .timedOut: return "The other device didn't answer."
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cc.bsns.ssh.link")

    init(_ connection: NWConnection) { self.connection = connection }

    convenience init(to endpoint: NWEndpoint) {
        self.init(NWConnection(to: endpoint, using: LinkConnection.parameters))
    }

    /// Plain TCP between the two devices, never through a relay or proxy and
    /// never over cellular: the local network, a direct device-to-device
    /// wireless link (which needs no access point, so it still works where
    /// Wi-Fi keeps clients apart), or a private network the user runs. The
    /// confidentiality and authentication come from the session inside.
    static var parameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = true
        return parameters
    }

    /// A device named by address rather than found by its advertisement.
    convenience init(toAddress address: String, port: UInt16 = DeviceLink.port) {
        self.init(to: .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any))
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: TransportError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ payload: Data) async throws {
        var frame = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= Self.maxFrame else { throw TransportError.tooLarge }
        return length == 0 ? Data() : try await read(length)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? TransportError.closed)
                }
            }
        }
    }

    func cancel() { connection.cancel() }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// Runs `operation`, giving up after `seconds`. The loser is cancelled.
func withLinkTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    // Not a task group: a group waits for every child, and a child stuck in a
    // callback that ignores cancellation would hold the timeout hostage.
    let once = LinkOnce()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let work = Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                work.cancel()
                continuation.resume(throwing: LinkConnection.TransportError.timedOut)
            }
        }
    }
}

/// True for exactly one caller — whoever gets there first resumes the continuation.
final class LinkOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
