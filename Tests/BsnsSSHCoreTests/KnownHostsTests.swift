import Foundation
import Testing
@testable import BsnsSSHCore

@Suite("KnownHosts (TOFU)")
struct KnownHostsTests {
    private func key(_ byte: UInt8) -> HostKey {
        HostKey(keyType: "ssh-ed25519", blob: Data(repeating: byte, count: 32))
    }

    @Test("first contact is unknown with a fingerprint")
    func firstContact() {
        let store = KnownHosts()
        let result = store.verify(host: "example.com", port: 22, key: key(0xAA))
        guard case let .unknown(fingerprint) = result else {
            Issue.record("expected .unknown, got \(result)")
            return
        }
        #expect(fingerprint.hasPrefix("SHA256:"))
    }

    @Test("a trusted key verifies as trusted")
    func trusted() {
        var store = KnownHosts()
        store.trust(host: "example.com", port: 22, key: key(0xAA))
        #expect(store.verify(host: "example.com", port: 22, key: key(0xAA)) == .trusted)
    }

    @Test("a changed key is a mismatch")
    func mismatch() {
        var store = KnownHosts()
        store.trust(host: "example.com", port: 22, key: key(0xAA))
        let result = store.verify(host: "example.com", port: 22, key: key(0xBB))
        guard case .mismatch = result else {
            Issue.record("expected .mismatch, got \(result)")
            return
        }
    }

    @Test("host identity is keyed by host and non-default port")
    func portScoping() {
        var store = KnownHosts()
        store.trust(host: "example.com", port: 2222, key: key(0xAA))
        // Same host, default port -> not the same entry.
        #expect(store.storedKey(host: "example.com", port: 22) == nil)
        #expect(store.storedKey(host: "example.com", port: 2222) == key(0xAA))
        #expect(KnownHosts.identifier("example.com", 2222) == "[example.com]:2222")
        #expect(KnownHosts.identifier("example.com", 22) == "example.com")
    }
}
