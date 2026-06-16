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

    @Test("ssh config parses concrete hosts and applies wildcard defaults")
    func configParses() {
        let cfg = """
        # my hosts
        Host *
          User deploy
          Port 2222

        Host web1 web2
          HostName 10.0.0.10
          IdentityFile ~/.ssh/id_ed25519

        Host bastioned
          HostName private.internal
          User root
          ProxyJump jump.example.com

        Host *.wildcard.only
          HostName nope
        """
        let hosts = SSHConfigParser.parse(cfg)
        #expect(hosts.map { $0.alias } == ["web1", "web2", "bastioned"])

        let web1 = hosts.first { $0.alias == "web1" }!
        #expect(web1.hostName == "10.0.0.10")
        #expect(web1.port == 2222)            // Host * default
        #expect(web1.user == "deploy")        // Host * default
        #expect(web1.proxyJump == nil)

        let b = hosts.first { $0.alias == "bastioned" }!
        #expect(b.user == "root")             // block overrides default
        #expect(b.proxyJump == "jump.example.com")
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
}
