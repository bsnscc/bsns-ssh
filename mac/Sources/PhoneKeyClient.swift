import Foundation
import Network
import Observation
import BsnsSSHCore

/// The computer's side of "phone as a hardware key": finds phones on the local
/// network, pairs with one, and gives the agent a key for each key the phone
/// offers. Signing with one of those opens a fresh encrypted session to the
/// phone, sends the request, and waits for its owner to approve it there.
@MainActor
@Observable
final class PhoneKeyClient {
    /// A phone advertising itself on the network.
    struct Found: Identifiable, Equatable {
        let id: String            // the advertised device id
        let endpoint: NWEndpoint
        /// Set when the phone was named by address instead of being found.
        var address: String? = nil

        /// A phone reached by address — on another network, across a tailnet.
        static func at(_ address: String) -> Found {
            Found(id: address, endpoint: .hostPort(host: NWEndpoint.Host(address),
                                                  port: NWEndpoint.Port(rawValue: DeviceLink.port) ?? .any),
                  address: address)
        }
    }

    private(set) var found: [Found] = []
    private(set) var browsing = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let store = LinkStore.shared
    @ObservationIgnored private weak var agentStore: AgentStore?
    /// Keys currently lent by each paired device, so they can be taken back.
    @ObservationIgnored private var lentKeys: [String: [KeyID]] = [:]

    /// Offer the keys of every phone already paired (their public halves were
    /// saved at pairing; the phone need not be reachable now).
    func attach(to agentStore: AgentStore) async {
        self.agentStore = agentStore
        for device in store.paired { await offerKeys(of: device) }
    }

    // MARK: discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: DeviceLink.serviceType, domain: nil), using: LinkConnection.parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Found] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Found(id: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.found = found.sorted { $0.id < $1.id } }
        }
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
        browsing = true
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browsing = false
        found = []
    }

    /// Where a paired phone is right now, if it is on the network: wait briefly
    /// for its advertisement.
    private nonisolated func locate(_ deviceID: String) async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjour(type: DeviceLink.serviceType, domain: nil), using: LinkConnection.parameters)
        return try await withLinkTimeout(6) {
            let once = LinkOnce()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, Error>) in
                    browser.browseResultsChangedHandler = { results, _ in
                        for result in results {
                            if case .service(let name, _, _, _) = result.endpoint, name == deviceID, once.claim() {
                                browser.cancel()
                                continuation.resume(returning: result.endpoint)
                            }
                        }
                    }
                    browser.stateUpdateHandler = { state in
                        switch state {
                        case .failed(let error):
                            if once.claim() { continuation.resume(throwing: error) }
                        case .cancelled:
                            // Gave up waiting: the phone isn't on this network.
                            if once.claim() { continuation.resume(throwing: LinkConnection.TransportError.timedOut) }
                        default:
                            break
                        }
                    }
                    browser.start(queue: .global(qos: .userInitiated))
                }
            } onCancel: {
                browser.cancel()
            }
        }
    }

    /// A started connection to a paired phone: by its advertisement (same
    /// network, or nearby with no network) and by each address the user gave
    /// for it, all at once — the first to connect is used. Which one answered
    /// doesn't matter for trust: the session that follows only completes with
    /// the device that holds the paired key.
    private nonisolated func connect(to deviceID: String, addresses: [String]) async throws -> LinkConnection {
        let attempts: [@Sendable () async throws -> LinkConnection] = [{
            let connection = LinkConnection(to: try await self.locate(deviceID))
            try await Self.start(connection)
            return connection
        }] + addresses.map { address in {
            let connection = LinkConnection(toAddress: address)
            try await Self.start(connection)
            return connection
        } }
        let once = LinkOnce()
        let failures = FailureCount(total: attempts.count)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LinkConnection, Error>) in
            for attempt in attempts {
                Task {
                    do {
                        let connection = try await attempt()
                        if once.claim() { continuation.resume(returning: connection) } else { connection.cancel() }
                    } catch {
                        if failures.addIsLast(), once.claim() { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }

    private nonisolated static func start(_ connection: LinkConnection) async throws {
        do { try await withLinkTimeout(8) { try await connection.start() } }
        catch { connection.cancel(); throw error }
    }

    private final class FailureCount: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(total: Int) { remaining = total }
        func addIsLast() -> Bool { lock.withLock { remaining -= 1; return remaining == 0 } }
    }

    func setAddresses(_ text: String, for deviceID: String) {
        store.setAddresses(HostRoutes.parse(text, excluding: ""), for: deviceID)
    }

    // MARK: pairing

    /// A pairing that has exchanged keys and is waiting for the user to compare codes.
    final class Pairing: @unchecked Sendable {
        let outcome: PairingOutcome
        fileprivate let connection: LinkConnection
        fileprivate let address: String?
        fileprivate init(outcome: PairingOutcome, connection: LinkConnection, address: String?) {
            self.outcome = outcome
            self.connection = connection
            self.address = address
        }
    }

    /// Exchange keys with a phone. Nothing is trusted yet: the caller shows
    /// `outcome.code` and calls `finish` with the user's answer.
    func beginPairing(with phone: Found) async throws -> Pairing {
        let identity = store.identity
        let name = Host.current().localizedName ?? "Mac"
        let connection = LinkConnection(to: phone.endpoint)
        do {
            try await withLinkTimeout(10) { try await connection.start() }
            let initiator = PairingInitiator(identity: identity, name: name)
            try await connection.send(initiator.hello())
            let response = try await withLinkTimeout(10) { try await connection.receive() }
            let (reveal, outcome) = try initiator.reveal(afterResponse: response)
            try await connection.send(reveal)
            return Pairing(outcome: outcome, connection: connection, address: phone.address)
        } catch LinkConnection.TransportError.closed {
            // The phone hangs up on a pairing attempt unless its pairing screen
            // is showing — that screen is how its owner says "now".
            connection.cancel()
            throw PairingError.phoneNotWaiting
        } catch {
            connection.cancel()
            throw error
        }
    }

    enum PairingError: LocalizedError {
        case declinedOnPhone, phoneNotWaiting
        var errorDescription: String? {
            switch self {
            case .declinedOnPhone: return "The pairing wasn't confirmed on the phone."
            case .phoneNotWaiting:
                return "The phone isn't waiting to pair. On the phone, open Settings → Phone as a Key → Pair a Computer and leave \"Waiting for a computer\" on screen, then choose the phone here again."
            }
        }
    }

    /// Complete (or abandon) a pairing. It is kept only if both this user and
    /// the phone's said the codes match.
    func finish(_ pairing: Pairing, accepted: Bool) async throws {
        defer { pairing.connection.cancel() }
        try await pairing.connection.send(Data([accepted ? 1 : 0]))
        guard accepted else { return }
        let theirs = try await withLinkTimeout(120) { try await pairing.connection.receive() }
        guard theirs == Data([1]) else { throw PairingError.declinedOnPhone }
        store.add(pairing.outcome.peer)
        // Paired by address: that address is how to reach it again.
        if let address = pairing.address { store.setAddresses([address], for: pairing.outcome.peer.id) }
        try await refreshKeys(of: pairing.outcome.peer.id)
    }

    func unpair(_ id: String) async {
        for key in lentKeys[id] ?? [] { await agentStore?.release(key) }
        lentKeys[id] = nil
        store.remove(id)
    }

    // MARK: keys

    /// Ask the phone which keys it offers, and offer those through the agent.
    func refreshKeys(of deviceID: String) async throws {
        guard let device = store.paired.first(where: { $0.id == deviceID }) else { return }
        let answer = try await request(LinkRequest(agentPayload: Data([SSHAgentMessageType.requestIdentities.rawValue])),
                                       of: device.peer)
        store.setIdentities(RemoteAgentKey.identities(inAnswer: answer), for: deviceID)
        if let updated = store.paired.first(where: { $0.id == deviceID }) { await offerKeys(of: updated) }
    }

    private func offerKeys(of device: LinkStore.Paired) async {
        guard let agentStore else { return }
        for key in lentKeys[device.id] ?? [] { await agentStore.release(key) }
        var lent: [KeyID] = []
        let peer = device.peer
        for offered in device.identities {
            var decoder = SSHDecoder(offered.blob)
            guard let name = try? decoder.readStringUTF8(), let algorithm = KeyAlgorithm(rawValue: name) else { continue }
            // Named for where it lives, so it is told apart from this Mac's own keys.
            let label = offered.comment.isEmpty ? peer.name : "\(offered.comment) · \(peer.name)"
            let key = RemoteAgentKey(publicKey: SSHPublicKey(blob: offered.blob, algorithm: algorithm, comment: label)) { [weak self] request in
                guard let self else { throw LinkConnection.TransportError.closed }
                return try await self.request(request, of: peer)
            }
            await agentStore.adopt(remote: key)
            lent.append(key.id)
        }
        lentKeys[device.id] = lent
    }

    /// One request, one session: find the phone, authenticate both ways, ask,
    /// wait for the answer. The wait is long because the answer may be a person
    /// reaching for their phone.
    private nonisolated func request(_ request: LinkRequest, of peer: LinkPeer) async throws -> Data {
        let identity = await store.identity
        let addresses = await store.paired.first { $0.id == peer.id }?.addresses ?? []
        let connection = try await connect(to: peer.id, addresses: addresses)
        defer { connection.cancel() }
        let initiator = SessionInitiator(identity: identity, peer: peer)
        try await connection.send(initiator.hello())
        let response = try await withLinkTimeout(10) { try await connection.receive() }
        var session = try initiator.finish(response: response)
        try await connection.send(try session.seal(request.encoded()))
        let answer = try await withLinkTimeout(90) { try await connection.receive() }
        return try session.open(answer)
    }
}
