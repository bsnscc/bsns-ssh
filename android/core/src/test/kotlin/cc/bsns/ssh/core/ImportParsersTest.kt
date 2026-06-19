package cc.bsns.ssh.core

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ImportParsersTest {
    // Real `ssh-keygen` output (see test fixtures): an unencrypted ed25519 and
    // ecdsa-p256 key, plus the public-key blobs they should re-derive to.
    private val ed25519Key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDMz0xUZ0Z1BD0/qiuv/z/RMhq1HSAjhaqlyDHLKdGIHwAAAJCesmO9nrJj
        vQAAAAtzc2gtZWQyNTUxOQAAACDMz0xUZ0Z1BD0/qiuv/z/RMhq1HSAjhaqlyDHLKdGIHw
        AAAEC8fqcCTiIwK2WEZPAGW6NU7Yuzy8yUEdI+c1KkJ3M038zPTFRnRnUEPT+qK6//P9Ey
        GrUdICOFqqXIMcsp0YgfAAAACW1lQGxhcHRvcAECAwQ=
        -----END OPENSSH PRIVATE KEY-----
    """.trimIndent()
    private val ed25519PubBlob = "AAAAC3NzaC1lZDI1NTE5AAAAIMzPTFRnRnUEPT+qK6//P9EyGrUdICOFqqXIMcsp0Ygf"

    private val ecdsaKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRKFmppM6pJM9PV2HXJ2o3R21mQNgbk
        XSw/hJFGYXLZHSRCxVCYNMOvOE4Q1+N2LtDxzt0y7JOp5xBDldc/4XR+AAAAqMGsqA3BrK
        gNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEoWamkzqkkz09XY
        dcnajdHbWZA2BuRdLD+EkUZhctkdJELFUJg0w684ThDX43Yu0PHO3TLsk6nnEEOV1z/hdH
        4AAAAgFSd33R02jG9HDH3ZTw7KuvUjmtSJmNFj8Q3eC+g0wm4AAAAMZWNkc2FAbGFwdG9w
        AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
    """.trimIndent()
    private val ecdsaPubBlob = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEoWamkzqkkz09XYdcnajdHbWZA2BuRdLD+EkUZhctkdJELFUJg0w684ThDX43Yu0PHO3TLsk6nnEEOV1z/hdH4="

    @Test fun ed25519KeyImportsAndDerivesPublicKey() {
        val k = OpenSshPrivateKey.parse(ed25519Key)
        assertEquals(KeyAlgorithm.ED25519, k.algorithm)
        assertEquals("me@laptop", k.comment)
        // The seed must reconstruct exactly the public key ssh-keygen emitted.
        val pub = FileKey.from(KeyAlgorithm.ED25519, k.material).publicKey.blob
        assertEquals(ed25519PubBlob, Base64.getEncoder().encodeToString(pub))
    }

    @Test fun ecdsaKeyImportsAndDerivesPublicKey() {
        val k = OpenSshPrivateKey.parse(ecdsaKey)
        assertEquals(KeyAlgorithm.ECDSA_P256, k.algorithm)
        assertEquals("ecdsa@laptop", k.comment)
        val pub = FileKey.from(KeyAlgorithm.ECDSA_P256, k.material).publicKey.blob
        assertEquals(ecdsaPubBlob, Base64.getEncoder().encodeToString(pub))
    }

    // A real passphrase-encrypted ed25519 key (aes256-ctr / bcrypt).
    private val encryptedKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABALWMPpu3
        TyopxCVYww+8prAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHrAJ0egS0kKDLyp
        IT7xXzvwWT42GEArknW8xNgeD/DLAAAAoB8UwGxI97CDZuvWtbO5od/++f+Px/2a9vPGRL
        s9YEWSoDmIHJ1LqOOAw/7IcgKBykrwroe5UWONdaqvHqeL6/v1WeP7EyAbqLKLXtSrs3pt
        ZvwnU+XmUzrCJ0W8s+o5lN0V8XYJpmHe/qjqXI/O6yT+shJy8r2Pq7y1jbbPdAvydNPUnD
        cPisjMrCOkVAdFKi9gVwFw++lXm1jhVHF6Vuw=
        -----END OPENSSH PRIVATE KEY-----
    """.trimIndent()

    @Test fun encryptedKeyIsRejectedWithReason() {
        val e = assertFailsWith<KeyImportException> { OpenSshPrivateKey.parse(encryptedKey) }
        assertTrue(e.message!!.contains("encrypted"))
    }

    @Test fun nonKeyTextIsRejected() {
        assertFailsWith<KeyImportException> { OpenSshPrivateKey.parse("hello, not a key") }
    }

    // Rewritten for OpenSSH first-match-wins semantics. The literal blocks come
    // BEFORE the `Host *` block so their values win (a later wildcard only fills
    // gaps), matching `ssh -G`.
    @Test fun sshConfigParsesConcreteHostsFirstMatchWins() {
        val cfg = """
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
        """.trimIndent()
        val hosts = SshConfigParser.parse(cfg)
        // web1, web2, bastioned — the wildcard-only block is skipped.
        assertEquals(listOf("web1", "web2", "bastioned"), hosts.map { it.alias })

        val web1 = hosts.first { it.alias == "web1" }
        assertEquals("10.0.0.10", web1.hostName)
        assertEquals(2222, web1.port)            // Host * fills the gap
        assertEquals("deploy", web1.user)        // Host * fills the gap
        assertEquals("~/.ssh/id_ed25519", web1.identityFile)
        assertNull(web1.proxyJump)

        val b = hosts.first { it.alias == "bastioned" }
        assertEquals("root", b.user)             // literal block matched first
        assertEquals("jump.example.com", b.proxyJump)
    }

    @Test fun sshConfigWildcardDoesNotApplyToNonMatchingAlias() {
        // `*.corp` must not match `github.com`, so it gets no ProxyJump.
        val cfg = """
            Host *.corp
              ProxyJump bastion

            Host github.com
              User git
        """.trimIndent()
        val gh = SshConfigParser.parse(cfg).first { it.alias == "github.com" }
        assertNull(gh.proxyJump)
        assertEquals("git", gh.user)
    }

    @Test fun sshConfigFirstMatchWins() {
        // `Host *` (User alice) precedes `Host prod` (User root) → alice wins.
        val cfg = """
            Host *
              User alice

            Host prod
              User root
        """.trimIndent()
        val prod = SshConfigParser.parse(cfg).first { it.alias == "prod" }
        assertEquals("alice", prod.user)
    }

    @Test fun sshConfigNegatedPatternExcludesBlock() {
        // `Host * !prod` must NOT apply to prod; it does apply to web.
        val cfg = """
            Host * !prod
              User x

            Host prod
            Host web
        """.trimIndent()
        val hosts = SshConfigParser.parse(cfg)
        assertNull(hosts.first { it.alias == "prod" }.user)
        assertEquals("x", hosts.first { it.alias == "web" }.user)
    }

    @Test fun sshConfigProxyJumpNoneResolvesToNull() {
        val cfg = """
            Host direct
              ProxyJump none

            Host *
              ProxyJump bastion
        """.trimIndent()
        val direct = SshConfigParser.parse(cfg).first { it.alias == "direct" }
        assertNull(direct.proxyJump)   // explicit none wins (first match) → resolves to null
    }

    @Test fun sshConfigHandlesEqualsAndQuotes() {
        val hosts = SshConfigParser.parse("Host prod\n  HostName=\"prod.example.com\"\n  User=ops")
        assertEquals(1, hosts.size)
        assertEquals("prod.example.com", hosts[0].hostName)
        assertEquals("ops", hosts[0].user)
    }

    @Test fun knownHostsParsesPlainSkipsHashed() {
        val kh = """
            github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
            example.org,10.0.0.5 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
            |1|hashedhostbase64= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        """.trimIndent()
        val entries = KnownHostsParser.parse(kh)
        // github.com + (example.org, 10.0.0.5) = 3 ids; the hashed line is skipped.
        assertEquals(listOf("github.com", "example.org", "10.0.0.5"), entries.map { it.id })
    }

    @Test fun knownHostsSkipsRevokedAndCertAuthorityLines() {
        val key = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        // @revoked / @cert-authority must NOT be imported as trusted host keys.
        assertTrue(KnownHostsParser.parse("@revoked example.com ssh-ed25519 $key").isEmpty())
        assertTrue(KnownHostsParser.parse("@cert-authority *.example.com ssh-ed25519 $key").isEmpty())
        // A normal line in the same input still imports.
        val mixed = """
            @revoked bad.example.com ssh-ed25519 $key
            good.example.com ssh-ed25519 $key
            @cert-authority *.example.com ssh-ed25519 $key
        """.trimIndent()
        assertEquals(listOf("good.example.com"), KnownHostsParser.parse(mixed).map { it.id })
    }

    // Build an unencrypted openssh-key-v1 envelope wrapping a single ecdsa-p256
    // private key whose private-scalar string is exactly [scalar]. Used to feed a
    // deliberately over-long scalar to the importer.
    private fun ecdsaKeyEnvelope(scalar: ByteArray): String {
        // A syntactically valid (if not on-curve) 65-byte uncompressed point.
        val q = byteArrayOf(0x04) + ByteArray(64) { 0x01 }
        val priv = SshEncoder.build { e ->
            e.writeUInt32(0x01020304L)            // checkint
            e.writeUInt32(0x01020304L)            // checkint (must match)
            e.writeString("ecdsa-sha2-nistp256")
            e.writeString("nistp256")             // curve
            e.writeString(q)                      // Q
            e.writeString(scalar)                 // mpint d (raw, as provided)
            e.writeString("imported")             // comment
            e.writeBytes(byteArrayOf(1, 2, 3, 4)) // block padding
        }
        val blob = SshEncoder.build { e ->
            e.writeBytes("openssh-key-v1 ".toByteArray(Charsets.UTF_8))
            e.writeString("none")                 // cipher
            e.writeString("none")                 // kdfname
            e.writeString(ByteArray(0))           // kdfoptions
            e.writeUInt32(1L)                      // count
            e.writeString(q)                      // public key blob (unused)
            e.writeString(priv)                   // private section
        }
        val b64 = Base64.getEncoder().encodeToString(blob)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n$b64\n-----END OPENSSH PRIVATE KEY-----"
    }

    @Test fun ecdsaKeyWithOverLongScalarIsRejectedNotTruncated() {
        // 34 raw bytes — longer than a P-256 scalar's 32 (+optional sign byte).
        val over = ByteArray(34) { 0x11 }
        assertFailsWith<KeyImportException> { OpenSshPrivateKey.parse(ecdsaKeyEnvelope(over)) }
        // 33 bytes with a non-zero first byte is also invalid (not a sign byte).
        val bad33 = byteArrayOf(0x11) + ByteArray(32) { 0x22 }
        assertFailsWith<KeyImportException> { OpenSshPrivateKey.parse(ecdsaKeyEnvelope(bad33)) }
    }
}
