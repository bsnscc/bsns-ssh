import SwiftUI
import AppKit
import BsnsSSHCore

/// The keys the agent holds: create one, copy its public half to install on a
/// server, or remove it.
struct MacKeysView: View {
    @Environment(AgentStore.self) private var store
    @State private var error: String?
    @State private var deleting: SSHPublicKey?
    @State private var copied: Data?
    @State private var activity = KeyActivityLog.shared
    @Environment(PhoneKeyClient.self) private var phoneKeys
    @State private var links = LinkStore.shared
    @State private var pairingPhone = false
    @Environment(HostStore.self) private var hosts
    /// The automation key whose host list is being edited (nil blob = a new key).
    @State private var scoping: PeerScopeRequest?

    static func name(of identity: SSHPublicKey, hardware: Bool) -> String {
        let kind: String
        switch identity.algorithm {
        case .ed25519: kind = "Ed25519"
        case .ecdsaP256: kind = hardware ? "Secure Enclave P-256" : "ECDSA P-256"
        case .rsa: kind = "RSA"
        case .ecdsaSK, .ed25519SK: kind = "Security key"
        }
        return identity.comment.isEmpty ? kind : "\(kind) — \(identity.comment)"
    }

    var body: some View {
        Form {
            Section {
                if store.identities.isEmpty {
                    Text("No keys yet.").foregroundStyle(.secondary)
                }
                ForEach(store.identities, id: \.blob) { identity in
                    keyRow(identity)
                }
            } header: {
                Text("Keys")
            }

            Section {
                Button("New Secure Enclave Key") {
                    Task {
                        do { try await store.generateEnclaveKey() }
                        catch { self.error = "Couldn't create a Secure Enclave key: \(error.localizedDescription)" }
                    }
                }
                .disabled(!store.enclaveAvailable)
                Button("New Ed25519 Key") { Task { await store.generateKey(.ed25519) } }
                Button("New Automation Key…") { scoping = PeerScopeRequest(identity: nil, hosts: []) }
                    .disabled(!store.enclaveAvailable)
                    .help("A Secure Enclave key that signs without asking, only for the hosts you choose")
            } header: {
                Text("Create")
            } footer: {
                Text(store.enclaveAvailable
                     ? "A Secure Enclave key never leaves this Mac's hardware and asks for Touch ID (or your password) every time it signs. The Enclave only makes P-256 keys, so it appears on servers as ecdsa-sha2-nistp256. An Ed25519 key is stored in your keychain and can be exported."
                     : "This Mac has no Secure Enclave, so only software keys are available. An Ed25519 key is stored in your keychain.")
            }

            Section {
                if links.paired.isEmpty {
                    Text("No iPhone paired.").foregroundStyle(.secondary)
                }
                ForEach(links.paired) { device in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(Brand.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.peer.name.isEmpty ? "iPhone" : device.peer.name)
                            Text("\(device.identities.count) key\(device.identities.count == 1 ? "" : "s") · \(device.id)")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("Also at", text: Binding(
                                get: { (device.addresses ?? []).joined(separator: ", ") },
                                set: { phoneKeys.setAddresses($0, for: device.id) }),
                                      prompt: Text("Its address on another network — a tailnet name"))
                                .font(.caption).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        }
                        Spacer()
                        Button("Refresh Keys") {
                            Task {
                                do { try await phoneKeys.refreshKeys(of: device.id) }
                                catch { self.error = "Couldn't reach \(device.peer.name): \(error.localizedDescription)" }
                            }
                        }
                        Button("Unpair", role: .destructive) { Task { await phoneKeys.unpair(device.id) } }
                    }
                }
                Button("Pair iPhone…") { pairingPhone = true }
            } header: {
                Text("iPhone as a Key")
            } footer: {
                Text("Use the hardware-backed keys on your iPhone from this Mac. In bsns.SSH on the phone, turn on Settings → Phone as a Key and choose Pair a Computer. Each sign-in is then approved on the phone with Face ID. The two devices connect directly: on the same network, nearby without one, or — if you give the phone's address — across a private network such as a tailnet. The app must be open on the phone.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                if activity.events.isEmpty {
                    Text("Nothing yet. Each time a key signs, it is listed here.").foregroundStyle(.secondary)
                }
                ForEach(Array(activity.events.suffix(50).reversed().enumerated()), id: \.offset) { _, event in
                    activityRow(event)
                }
                if !activity.events.isEmpty {
                    Button("Clear Activity", role: .destructive) { activity.clear() }
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("Which key was used, by what, to sign in where. Stored on this Mac only; what was signed is never recorded.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keys")
        .sheet(isPresented: $pairingPhone) { MacPairingSheet() }
        .sheet(item: $scoping) { request in
            PeerScopeSheet(request: request, savedHosts: hosts.hosts.map(\.host)) { chosen in
                Task {
                    do {
                        if let identity = request.identity { try await store.setPeerKeyHosts(chosen, for: identity) }
                        else { try await store.generatePeerKey(hosts: chosen) }
                    } catch { self.error = "Couldn't save the automation key: \(error.localizedDescription)" }
                }
            }
        }
        .confirmationDialog("Delete this key?", isPresented: Binding(get: { deleting != nil },
                                                                     set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { identity in
            Button("Delete", role: .destructive) { Task { await store.deleteKey(identity) } }
            Button("Cancel", role: .cancel) { }
        } message: { identity in
            Text(store.isHardware(identity)
                 ? "A Secure Enclave key can't be recovered once deleted. Servers that trust it will stop accepting this Mac."
                 : "Servers that trust this key will stop accepting this Mac unless you have exported it.")
        }
    }

    private func activityRow(_ event: AgentAuditEvent) -> some View {
        let target = event.host.map { host in event.user.map { "\($0)@\(host)" } ?? host } ?? "an unidentified host"
        let symbol: String, tint: Color
        switch event.outcome {
        case .signed: (symbol, tint) = ("checkmark.circle", .green)
        case .declined: (symbol, tint) = ("hand.raised", .orange)
        case .failed: (symbol, tint) = ("xmark.circle", .red)
        case .refused: (symbol, tint) = ("nosign", .red)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.requester ?? "bsns.SSH") → \(target)")
                Text("\(event.keyComment.isEmpty ? event.keyFingerprint : event.keyComment) · \(event.outcome.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keyRow(_ identity: SSHPublicKey) -> some View {
        let hardware = store.isHardware(identity)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: hardware ? "cpu" : "key")
                .foregroundStyle(hardware ? Brand.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.name(of: identity, hardware: hardware))
                Text(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let allowed = store.peerHosts(of: identity) {
                    Text(allowed.isEmpty ? "Signs without asking — but no hosts are allowed yet, so it signs for nothing."
                                         : "Signs without asking, only for: \(allowed.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let allowed = store.peerHosts(of: identity) {
                Button("Hosts…") { scoping = PeerScopeRequest(identity: identity, hosts: allowed) }
            }
            Button(copied == identity.blob ? "Copied" : "Copy Public Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authorizedKeysLine(identity), forType: .string)
                copied = identity.blob
            }
            .help("Copy the authorized_keys line to install on a server")
            Button(role: .destructive) { deleting = identity } label: { Image(systemName: "trash") }
                .help("Delete key")
                .accessibilityLabel("Delete key")
        }
    }
}

/// Which automation key's host list is being chosen.
struct PeerScopeRequest: Identifiable {
    let id = UUID()
    /// nil while creating a new key.
    let identity: SSHPublicKey?
    let hosts: [String]
}

/// Choose the hosts an automation key may sign in to.
private struct PeerScopeSheet: View {
    let request: PeerScopeRequest
    let savedHosts: [String]
    let done: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    private var choices: [String] {
        var seen = Set<String>()
        return (savedHosts + request.hosts).map { $0.lowercased() }.filter { seen.insert($0).inserted }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.identity == nil ? "New Automation Key" : "Allowed Hosts").font(.headline)
            Text("This key lives in the Secure Enclave and can't be copied off this Mac, but unlike your other keys it signs without Touch ID — so scripts and schedulers can use it. It only signs in to the hosts ticked here, and only when the connection is provably to that host. Every use is in the activity log.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if choices.isEmpty {
                Text("Save a host under Connect first.").foregroundStyle(.secondary)
            }
            ForEach(choices, id: \.self) { host in
                Toggle(host, isOn: Binding(
                    get: { chosen.contains(host) },
                    set: { if $0 { chosen.insert(host) } else { chosen.remove(host) } }))
            }
            Text("Tick only machines that are yours. Anyone who can run programs as you on this Mac while it is unlocked can use this key to reach them.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.identity == nil ? "Create Key" : "Save") {
                    done(chosen.sorted())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(request.identity == nil && chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { chosen = Set(request.hosts.map { $0.lowercased() }) }
    }
}
