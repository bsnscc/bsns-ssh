#if os(iOS)
import Foundation
import Network
import Observation
import UIKit
import BsnsSSHCore

/// Lets a paired computer use this phone's keys: the phone as a hardware key.
///
/// While the app is open and this is switched on, the phone advertises itself
/// on the local network and answers two kinds of connection: a pairing
/// attempt (only while the pairing screen is open, and only completed if the
/// user confirms the code), and sessions from computers already paired. A
/// session can list the keys offered and ask for signatures; each signature is
/// approved on this phone, with a prompt that says which program on which
/// computer wants to sign in where.
@MainActor
@Observable
final class PhoneKeyServer {
    static let shared = PhoneKeyServer()
    static let enabledKey = "link.serveKeys"

    enum State: Equatable { case off, listening, failed(String) }
    private(set) var state = State.off

    /// A pairing waiting for the user to compare codes.
    struct PendingPairing: Identifiable {
        let id = UUID()
        let outcome: PairingOutcome
        fileprivate let decide: (Bool) -> Void
    }
    private(set) var pendingPairing: PendingPairing?
    /// True while the pairing screen is open. Pairing attempts are refused otherwise.
    var acceptsPairing = false

    @ObservationIgnored private var listener: NWListener?
    /// Connections being served. Turning the feature off ends them: a computer
    /// connected while it was on doesn't keep its session afterwards.
    @ObservationIgnored private var connections: [ObjectIdentifier: LinkConnection] = [:]
    @ObservationIgnored private var agent: Agent?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Debug builds only: confirm pairings without asking, and offer every key.
    @ObservationIgnored var devAutoConfirm = false
    @ObservationIgnored var devOfferAllKeys = false

    private init() {
        // iOS stops a listener when the app leaves the foreground; bring it
        // back when the app returns.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopListening() }
        })
    }

    func configure(agent: Agent) {
        self.agent = agent
        refresh()
    }

    /// Apply the setting: listen or stop.
    func refresh() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) || devAutoConfirm {
            startListening()
        } else {
            stopListening()
            state = .off
        }
    }

    private func startListening() {
        guard listener == nil, agent != nil else { return }
        do {
            let listener = try NWListener(using: LinkConnection.parameters)
            // Advertised under an id derived from the link key: it identifies
            // this phone to a computer paired with it and says nothing else.
            listener.service = NWListener.Service(name: LinkStore.shared.identity.deviceID, type: DeviceLink.serviceType)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    switch newState {
                    case .ready: self?.state = .listening
                    case .failed(let error):
                        self?.state = .failed(error.localizedDescription)
                        self?.listener = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.serve(LinkConnection(connection)) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        if let pending = pendingPairing { pending.decide(false) }
    }

    /// Admit a connection — only while still listening.
    private func admit(_ connection: LinkConnection) -> Bool {
        guard listener != nil else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    private func release(_ connection: LinkConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    // MARK: connections

    private nonisolated func serve(_ connection: LinkConnection) async {
        guard await admit(connection) else { connection.cancel(); return }
        defer {
            connection.cancel()
            Task { @MainActor in self.release(connection) }
        }
        do {
            try await withLinkTimeout(10) { try await connection.start() }
            let first = try await withLinkTimeout(10) { try await connection.receive() }
            switch first.first {
            case 0x50: try await pair(connection, hello: first)
            case 0x53: try await session(connection, hello: first)
            default: return
            }
        } catch {
            DiagLog.log("link", "connection ended: \(error.localizedDescription)")
        }
    }

    private nonisolated func pair(_ connection: LinkConnection, hello: Data) async throws {
        guard await acceptsPairing else { return }
        let (identity, name) = await (LinkStore.shared.identity, UIDevice.current.name)
        var responder = PairingResponder(identity: identity, name: name)
        try await connection.send(try responder.respond(toHello: hello))
        let reveal = try await withLinkTimeout(10) { try await connection.receive() }
        let outcome = try responder.finish(reveal: reveal)

        // Both people-facing halves have to agree: this phone's owner, and
        // whoever is at the computer. Each side sends its verdict; the pairing
        // is kept only if both say yes.
        let mine = await askUser(outcome)
        try await connection.send(Data([mine ? 1 : 0]))
        guard mine else { return }
        let theirs = try await withLinkTimeout(120) { try await connection.receive() }
        guard theirs == Data([1]) else { return }
        await LinkStore.shared.add(outcome.peer)
        DiagLog.log("link", "paired with \(outcome.peer.id)")
    }

    private func askUser(_ outcome: PairingOutcome) async -> Bool {
        if devAutoConfirm { return true }
        return await withCheckedContinuation { continuation in
            pendingPairing = PendingPairing(outcome: outcome) { [weak self] accepted in
                self?.pendingPairing = nil
                continuation.resume(returning: accepted)
            }
        }
    }

    /// The pairing screen's Confirm / Cancel.
    func decidePairing(_ accepted: Bool) { pendingPairing?.decide(accepted) }

    private nonisolated func session(_ connection: LinkConnection, hello: Data) async throws {
        let store = await LinkStore.shared
        let identity = await store.identity
        var accepted = try SessionResponder.accept(hello: hello, identity: identity) { store.pairedName(forPublicKey: $0) != nil }
        let computer = store.pairedName(forPublicKey: accepted.peerPublicKey) ?? "a paired computer"
        try await connection.send(accepted.response)
        guard let agent = await agent else { return }
        let offerAll = await devOfferAllKeys
        // Only keys that ask their owner every time are lent out: the Face ID
        // prompt IS the approval, and it carries the question.
        let hardwareOnly: @Sendable (any KeyBackend) -> Bool = { key in key.requiresUserPresence }
        let exposed: (@Sendable (any KeyBackend) -> Bool)? = offerAll ? nil : hardwareOnly

        while true {
            // Nothing is acted on until a message from the computer opens —
            // that is what proves it holds the key it claimed.
            let frame = try await connection.receive()
            // Unpaired since this session began: it ends here.
            guard store.pairedName(forPublicKey: accepted.peerPublicKey) != nil else { return }
            let request = try LinkRequest(decoding: try accepted.session.open(frame))
            let asker = "\(request.requester ?? "A program") on \(computer)"
            // The host is the computer's word for it — shown, never relied on.
            let context = SignContext(host: request.host, purpose: .remoteAgent, requester: asker, user: request.user,
                                      hostProven: false)
            let answer = await agent.handleAgentMessage(request.agentPayload, context: context, exposing: exposed)
            try await connection.send(try accepted.session.seal(answer))
        }
    }
}
#endif
