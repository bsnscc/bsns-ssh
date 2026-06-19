import Foundation
import Testing
@testable import BsnsSSHCore

@Suite("ImportParsers")
struct ImportParsersTests {
    // Real `ssh-keygen` output and the public blobs they should re-derive to.
    let ed25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDMz0xUZ0Z1BD0/qiuv/z/RMhq1HSAjhaqlyDHLKdGIHwAAAJCesmO9nrJj
    vQAAAAtzc2gtZWQyNTUxOQAAACDMz0xUZ0Z1BD0/qiuv/z/RMhq1HSAjhaqlyDHLKdGIHw
    AAAEC8fqcCTiIwK2WEZPAGW6NU7Yuzy8yUEdI+c1KkJ3M038zPTFRnRnUEPT+qK6//P9Ey
    GrUdICOFqqXIMcsp0YgfAAAACW1lQGxhcHRvcAECAwQ=
    -----END OPENSSH PRIVATE KEY-----
    """
    let ed25519PubBlob = "AAAAC3NzaC1lZDI1NTE5AAAAIMzPTFRnRnUEPT+qK6//P9EyGrUdICOFqqXIMcsp0Ygf"

    let ecdsaKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRKFmppM6pJM9PV2HXJ2o3R21mQNgbk
    XSw/hJFGYXLZHSRCxVCYNMOvOE4Q1+N2LtDxzt0y7JOp5xBDldc/4XR+AAAAqMGsqA3BrK
    gNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEoWamkzqkkz09XY
    dcnajdHbWZA2BuRdLD+EkUZhctkdJELFUJg0w684ThDX43Yu0PHO3TLsk6nnEEOV1z/hdH
    4AAAAgFSd33R02jG9HDH3ZTw7KuvUjmtSJmNFj8Q3eC+g0wm4AAAAMZWNkc2FAbGFwdG9w
    AQIDBA==
    -----END OPENSSH PRIVATE KEY-----
    """
    let ecdsaPubBlob = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEoWamkzqkkz09XYdcnajdHbWZA2BuRdLD+EkUZhctkdJELFUJg0w684ThDX43Yu0PHO3TLsk6nnEEOV1z/hdH4="

    let encryptedKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABALWMPpu3
    TyopxCVYww+8prAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHrAJ0egS0kKDLyp
    IT7xXzvwWT42GEArknW8xNgeD/DLAAAAoB8UwGxI97CDZuvWtbO5od/++f+Px/2a9vPGRL
    s9YEWSoDmIHJ1LqOOAw/7IcgKBykrwroe5UWONdaqvHqeL6/v1WeP7EyAbqLKLXtSrs3pt
    ZvwnU+XmUzrCJ0W8s+o5lN0V8XYJpmHe/qjqXI/O6yT+shJy8r2Pq7y1jbbPdAvydNPUnD
    cPisjMrCOkVAdFKi9gVwFw++lXm1jhVHF6Vuw=
    -----END OPENSSH PRIVATE KEY-----
    """

    @Test("ed25519 key imports and re-derives its public key")
    func ed25519Imports() throws {
        let k = try OpenSSHPrivateKey.parse(ed25519Key)
        #expect(k.algorithm == .ed25519)
        #expect(k.comment == "me@laptop")
        let pub = try FileKey.from(algorithm: .ed25519, privateKeyMaterial: k.material).publicKey.blob
        #expect(pub.base64EncodedString() == ed25519PubBlob)
    }

    @Test("ecdsa-p256 key imports and re-derives its public key")
    func ecdsaImports() throws {
        let k = try OpenSSHPrivateKey.parse(ecdsaKey)
        #expect(k.algorithm == .ecdsaP256)
        #expect(k.comment == "ecdsa@laptop")
        let pub = try FileKey.from(algorithm: .ecdsaP256, privateKeyMaterial: k.material).publicKey.blob
        #expect(pub.base64EncodedString() == ecdsaPubBlob)
    }

    @Test("encrypted key is rejected with a reason")
    func encryptedRejected() {
        #expect(throws: KeyImportError.self) { try OpenSSHPrivateKey.parse(encryptedKey) }
    }

    @Test("non-key text is rejected")
    func nonKeyRejected() {
        #expect(throws: KeyImportError.self) { try OpenSSHPrivateKey.parse("hello, not a key") }
    }

    // Rewritten for OpenSSH first-match-wins semantics. The literal blocks come
    // BEFORE the `Host *` block so their values win (a later wildcard only fills
    // gaps), matching `ssh -G`.
    @Test("ssh config parses concrete hosts, first-match-wins fills gaps")
    func configParses() {
        let cfg = """
        # my hosts
        Host web1 web2
          HostName 10.0.0.10
          IdentityFile ~/.ssh/id_ed25519

        Host bastioned
          HostName private.internal
          User root
          ProxyJump jump.example.com

        Host *
          User deploy
          Port 2222

        Host *.wildcard.only
          HostName nope
        """
        let hosts = SSHConfigParser.parse(cfg)
        #expect(hosts.map { $0.alias } == ["web1", "web2", "bastioned"])

        let web1 = hosts.first { $0.alias == "web1" }!
        #expect(web1.hostName == "10.0.0.10")
        #expect(web1.port == 2222)            // Host * fills the gap
        #expect(web1.user == "deploy")        // Host * fills the gap
        #expect(web1.proxyJump == nil)

        let b = hosts.first { $0.alias == "bastioned" }!
        #expect(b.user == "root")             // literal block matched first
        #expect(b.proxyJump == "jump.example.com")
    }

    @Test("wildcard block does NOT apply to a non-matching alias")
    func configWildcardNonApplication() {
        // `*.corp` must not match `github.com`, so it gets no ProxyJump.
        let cfg = """
        Host *.corp
          ProxyJump bastion

        Host github.com
          User git
        """
        let hosts = SSHConfigParser.parse(cfg)
        let gh = hosts.first { $0.alias == "github.com" }!
        #expect(gh.proxyJump == nil)
        #expect(gh.user == "git")
    }

    @Test("first-match wins across blocks")
    func configFirstMatchWins() {
        // `Host *` (User alice) precedes `Host prod` (User root) → alice wins.
        let cfg = """
        Host *
          User alice

        Host prod
          User root
        """
        let hosts = SSHConfigParser.parse(cfg)
        let prod = hosts.first { $0.alias == "prod" }!
        #expect(prod.user == "alice")
    }

    @Test("negated pattern excludes a block")
    func configNegation() {
        // `Host * !prod` must NOT apply to prod; it does apply to web.
        let cfg = """
        Host * !prod
          User x

        Host prod
        Host web
        """
        let hosts = SSHConfigParser.parse(cfg)
        let prod = hosts.first { $0.alias == "prod" }!
        let web = hosts.first { $0.alias == "web" }!
        #expect(prod.user == nil)
        #expect(web.user == "x")
    }

    @Test("ProxyJump none resolves to nil")
    func configProxyJumpNone() {
        let cfg = """
        Host direct
          ProxyJump none

        Host *
          ProxyJump bastion
        """
        let hosts = SSHConfigParser.parse(cfg)
        let direct = hosts.first { $0.alias == "direct" }!
        #expect(direct.proxyJump == nil)   // explicit none wins (first match) → resolves to nil
    }

    @Test("ssh config handles = and quotes")
    func configEquals() {
        let hosts = SSHConfigParser.parse("Host prod\n  HostName=\"prod.example.com\"\n  User=ops")
        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "prod.example.com")
        #expect(hosts[0].user == "ops")
    }

    @Test("known_hosts parses plain, skips hashed")
    func knownHostsParse() {
        let kh = """
        github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        example.org,10.0.0.5 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        |1|hashedhostbase64= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        """
        let entries = KnownHostsParser.parse(kh)
        #expect(entries.map { $0.identifier } == ["github.com", "example.org", "10.0.0.5"])
    }

    @Test("known_hosts skips @revoked and @cert-authority lines entirely")
    func knownHostsSkipsMarkers() {
        let key = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        // @revoked / @cert-authority must NOT be imported as trusted host keys.
        #expect(KnownHostsParser.parse("@revoked example.com ssh-ed25519 \(key)").isEmpty)
        #expect(KnownHostsParser.parse("@cert-authority *.example.com ssh-ed25519 \(key)").isEmpty)
        // A normal line in the same input still imports.
        let mixed = """
        @revoked bad.example.com ssh-ed25519 \(key)
        good.example.com ssh-ed25519 \(key)
        @cert-authority *.example.com ssh-ed25519 \(key)
        """
        #expect(KnownHostsParser.parse(mixed).map { $0.identifier } == ["good.example.com"])
    }

    // Build an unencrypted openssh-key-v1 envelope wrapping a single ecdsa-p256
    // private key whose private-scalar string is exactly `scalar`. Used to feed a
    // deliberately over-long scalar to the importer.
    private func ecdsaKeyEnvelope(scalar: Data) -> String {
        // A syntactically valid (if not on-curve) 65-byte uncompressed point.
        let q = Data([0x04] + [UInt8](repeating: 0x01, count: 64))
        let priv = SSHEncoder.build { e in
            e.writeUInt32(0x01020304)             // checkint
            e.writeUInt32(0x01020304)             // checkint (must match)
            e.writeString("ecdsa-sha2-nistp256")
            e.writeString("nistp256")             // curve
            e.writeString(q)                      // Q
            e.writeString(scalar)                 // mpint d (raw, as provided)
            e.writeString("imported")             // comment
            e.writeBytes(Data([1, 2, 3, 4]))      // block padding
        }
        let blob = SSHEncoder.build { e in
            e.writeBytes(Data("openssh-key-v1\u{0}".utf8))
            e.writeString("none")                 // cipher
            e.writeString("none")                 // kdfname
            e.writeString(Data())                 // kdfoptions
            e.writeUInt32(1)                       // count
            e.writeString(q)                      // public key blob (unused)
            e.writeString(priv)                   // private section
        }
        let b64 = blob.base64EncodedString()
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----"
    }

    @Test("ecdsa key with an over-long scalar is rejected, not truncated")
    func ecdsaOverLongScalarRejected() {
        // 34 raw bytes — longer than a P-256 scalar's 32 (+optional sign byte).
        let over = Data([UInt8](repeating: 0x11, count: 34))
        #expect(throws: KeyImportError.self) {
            try OpenSSHPrivateKey.parse(ecdsaKeyEnvelope(scalar: over))
        }
        // 33 bytes with a non-zero first byte is also invalid (not a sign byte).
        let bad33 = Data([0x11] + [UInt8](repeating: 0x22, count: 32))
        #expect(throws: KeyImportError.self) {
            try OpenSSHPrivateKey.parse(ecdsaKeyEnvelope(scalar: bad33))
        }
    }
}
