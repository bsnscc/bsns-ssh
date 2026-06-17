import XCTest
import Security
@testable import BsnsSSHCore

/// Imports a throwaway RSA key (generated once with `ssh-keygen`, test-only) in
/// all three private-key containers and checks each yields the same correct
/// `ssh-rsa` public blob. The OpenSSH case also signs + verifies, proving the
/// recomputed CRT exponents (dP/dQ) are right.
final class RSAImportTests: XCTestCase {
    // The matching public key, as emitted by `ssh-keygen -y` (base64 of the blob).
    private let expectedPublicBase64 = "AAAAB3NzaC1yc2EAAAADAQABAAABAQC1ibVHS2qAabNowyp8wTJok5L3KgH+F6alj3XAMhCWdLdxXTUP7E8SGO/3y2UA3MJw+tMFycVHTyglWWPUiiAubTI0TJyAHDPJ1YaOD+zzhMy7oCfUEHqzvoQuHg9oK93ZjTvT2kMD+nm51YhvVJ1KdNlZ7rPAS0t+VDznGhB2h4YwOJ58LLEcSl+A3x9wHVA96M0o1yWHrHGuyPIXOliwU3qWNJ+wuYH09G6m13BHGsjluhriP74kAQ53YDRS8WRu7yC+eh9NEmcdlnL/TV8eCpDaASdwq0SU70d49tf/JIvc1UUysmKcUpzjQ3SB2D0M1WnMIuP0Wzl5cCiEgG23"

    private let openssh = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEAtYm1R0tqgGmzaMMqfMEyaJOS9yoB/hempY91wDIQlnS3cV01D+xP
Ehjv98tlANzCcPrTBcnFR08oJVlj1IogLm0yNEycgBwzydWGjg/s84TMu6An1BB6s76ELh
4PaCvd2Y0709pDA/p5udWIb1SdSnTZWe6zwEtLflQ85xoQdoeGMDiefCyxHEpfgN8fcB1Q
PejNKNclh6xxrsjyFzpYsFN6ljSfsLmB9PRuptdwRxrI5boa4j++JAEOd2A0UvFkbu8gvn
ofTRJnHZZy/01fHgqQ2gEncKtElO9HePbX/ySL3NVFMrJinFKc40N0gdg9DNVpzCLj9Fs5
eXAohIBttwAAA8jSyuMe0srjHgAAAAdzc2gtcnNhAAABAQC1ibVHS2qAabNowyp8wTJok5
L3KgH+F6alj3XAMhCWdLdxXTUP7E8SGO/3y2UA3MJw+tMFycVHTyglWWPUiiAubTI0TJyA
HDPJ1YaOD+zzhMy7oCfUEHqzvoQuHg9oK93ZjTvT2kMD+nm51YhvVJ1KdNlZ7rPAS0t+VD
znGhB2h4YwOJ58LLEcSl+A3x9wHVA96M0o1yWHrHGuyPIXOliwU3qWNJ+wuYH09G6m13BH
GsjluhriP74kAQ53YDRS8WRu7yC+eh9NEmcdlnL/TV8eCpDaASdwq0SU70d49tf/JIvc1U
UysmKcUpzjQ3SB2D0M1WnMIuP0Wzl5cCiEgG23AAAAAwEAAQAAAQBbfN8C4xr1RE/KSDEt
ViAVW+oA7ga7CyhM35O0HIcHjCK22wZW0/y1XiPxeWuZl6fWUFHw5NKrMVVGHVqWTlYRj6
5xdPqaBZyD5zw8dAIyZ4bWN8xar0NnOmha5YNWOGVBsk+oYKLNannWEasEkFwEnga7r/Se
wFN3gvR+c0BAuwqYP7WhaCudFZwdzpOeLlf1SMaW7V8dqezeXyY4oh2JMbSe0dTOM5txiJ
JcKvSb4nuB8dUj0zMM7DGr6NE93O+sgzP8HoNbrLWTstJC9vJczi8WKPr7coYJblIUfHcs
zWAaMC+snF/Dj8vLSZkQbnh2ak5qdwmoL07c8LqorScBAAAAgQDaLdmHEhpvWXhmUYEXmf
2kXwTw8HbWdcodPer4pU2YbYX6BJ2GYjVoineD1QXxFuy0NV4Gd8iQZL1Ut9IzLTCbh2iE
3T2SXQATIRdx0ft1q1plQia2NsEfMKUQ+LeCo9jNRwYpvCawyqdZudxTFA+ulHKvQF/vGA
jZonICIctNYgAAAIEA3u/kzSSXLLxmKK17eVWVS9uZiPksF197SeSvsDgithPmbJ62Ljps
xzQjoKaSAXQ7no41zZ8zDbJQKgYy6HiVfyv24RfXOOdYv5VdkqMiiBHrA5B0eN249EWg/I
X6FHa/eugNJ+NIhWFDqRD/l7NEY/oHzOubWqZDgJ80Mw8BJqEAAACBANB2ChtPGyLrVoQ/
SxUncd0a1vjJatSHLiDfjaRHopv7RenX0eC8NeXXA67eCFlY0OiEXoPY27YtzE+PYvSOUf
5NNbHYCY7rCrhdN29eHHmSfYaeaC5uYZNXPXYdsO4/GNn1XlhtvC1IlF4cMuaOtoDkJtX6
/t6qQpO1MAaAEi1XAAAAD3JzYS1pbXBvcnQtdGVzdAECAw==
-----END OPENSSH PRIVATE KEY-----
"""

    private let pkcs1 = """
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAtYm1R0tqgGmzaMMqfMEyaJOS9yoB/hempY91wDIQlnS3cV01
D+xPEhjv98tlANzCcPrTBcnFR08oJVlj1IogLm0yNEycgBwzydWGjg/s84TMu6An
1BB6s76ELh4PaCvd2Y0709pDA/p5udWIb1SdSnTZWe6zwEtLflQ85xoQdoeGMDie
fCyxHEpfgN8fcB1QPejNKNclh6xxrsjyFzpYsFN6ljSfsLmB9PRuptdwRxrI5boa
4j++JAEOd2A0UvFkbu8gvnofTRJnHZZy/01fHgqQ2gEncKtElO9HePbX/ySL3NVF
MrJinFKc40N0gdg9DNVpzCLj9Fs5eXAohIBttwIDAQABAoIBAFt83wLjGvVET8pI
MS1WIBVb6gDuBrsLKEzfk7QchweMIrbbBlbT/LVeI/F5a5mXp9ZQUfDk0qsxVUYd
WpZOVhGPrnF0+poFnIPnPDx0AjJnhtY3zFqvQ2c6aFrlg1Y4ZUGyT6hgos1qedYR
qwSQXASeBruv9J7AU3eC9H5zQEC7Cpg/taFoK50VnB3Ok54uV/VIxpbtXx2p7N5f
JjiiHYkxtJ7R1M4zm3GIklwq9Jvie4Hx1SPTMwzsMavo0T3c76yDM/weg1ustZOy
0kL28lzOLxYo+vtyhgluUhR8dyzNYBowL6ycX8OPy8tJmRBueHZqTmp3CagvTtzw
uqitJwECgYEA3u/kzSSXLLxmKK17eVWVS9uZiPksF197SeSvsDgithPmbJ62Ljps
xzQjoKaSAXQ7no41zZ8zDbJQKgYy6HiVfyv24RfXOOdYv5VdkqMiiBHrA5B0eN24
9EWg/IX6FHa/eugNJ+NIhWFDqRD/l7NEY/oHzOubWqZDgJ80Mw8BJqECgYEA0HYK
G08bIutWhD9LFSdx3RrW+Mlq1IcuIN+NpEeim/tF6dfR4Lw15dcDrt4IWVjQ6IRe
g9jbti3MT49i9I5R/k01sdgJjusKuF03b14ceZJ9hp5oLm5hk1c9dh2w7j8Y2fVe
WG28LUiUXhwy5o62gOQm1fr+3qpCk7UwBoASLVcCgYEAlh7OYIGKNvqqhCvF4H+L
6Cf47G51jUujdq/CypQSc69U08HQBbMb+swWTaC84rPFTdCPVGYmd8uiBZpk/3vr
l1YgiZSHPe8zKNdIymyF3UDLk3vbomQTnpGghUsmik8oQ3gtG7YF6KMFb7xdkGaL
4BLG2+uvkkwxWlRaTyOEb+ECgYBhHdzvhBccWY9g5SvRmyLM42grV4rRoHi5D+0p
D8aN7K5Rlx5MGOLzRQyONxqkpWAOMzzlJ+6UHRoGJsLvNC62zrmpNQCe+Jlx8tuU
or+ZU8nvIXVfzEThI8+aa5K2K+ckA9AEWntEjX+xqGl+SBZ2TdRZ9CkxCxkhP1Q0
cw4E2QKBgQDaLdmHEhpvWXhmUYEXmf2kXwTw8HbWdcodPer4pU2YbYX6BJ2GYjVo
ineD1QXxFuy0NV4Gd8iQZL1Ut9IzLTCbh2iE3T2SXQATIRdx0ft1q1plQia2NsEf
MKUQ+LeCo9jNRwYpvCawyqdZudxTFA+ulHKvQF/vGAjZonICIctNYg==
-----END RSA PRIVATE KEY-----
"""

    private let pkcs8 = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC1ibVHS2qAabNo
wyp8wTJok5L3KgH+F6alj3XAMhCWdLdxXTUP7E8SGO/3y2UA3MJw+tMFycVHTygl
WWPUiiAubTI0TJyAHDPJ1YaOD+zzhMy7oCfUEHqzvoQuHg9oK93ZjTvT2kMD+nm5
1YhvVJ1KdNlZ7rPAS0t+VDznGhB2h4YwOJ58LLEcSl+A3x9wHVA96M0o1yWHrHGu
yPIXOliwU3qWNJ+wuYH09G6m13BHGsjluhriP74kAQ53YDRS8WRu7yC+eh9NEmcd
lnL/TV8eCpDaASdwq0SU70d49tf/JIvc1UUysmKcUpzjQ3SB2D0M1WnMIuP0Wzl5
cCiEgG23AgMBAAECggEAW3zfAuMa9URPykgxLVYgFVvqAO4GuwsoTN+TtByHB4wi
ttsGVtP8tV4j8XlrmZen1lBR8OTSqzFVRh1alk5WEY+ucXT6mgWcg+c8PHQCMmeG
1jfMWq9DZzpoWuWDVjhlQbJPqGCizWp51hGrBJBcBJ4Gu6/0nsBTd4L0fnNAQLsK
mD+1oWgrnRWcHc6Tni5X9UjGlu1fHans3l8mOKIdiTG0ntHUzjObcYiSXCr0m+J7
gfHVI9MzDOwxq+jRPdzvrIMz/B6DW6y1k7LSQvbyXM4vFij6+3KGCW5SFHx3LM1g
GjAvrJxfw4/Ly0mZEG54dmpOancJqC9O3PC6qK0nAQKBgQDe7+TNJJcsvGYorXt5
VZVL25mI+SwXX3tJ5K+wOCK2E+ZsnrYuOmzHNCOgppIBdDuejjXNnzMNslAqBjLo
eJV/K/bhF9c451i/lV2SoyKIEesDkHR43bj0RaD8hfoUdr966A0n40iFYUOpEP+X
s0Rj+gfM65tapkOAnzQzDwEmoQKBgQDQdgobTxsi61aEP0sVJ3HdGtb4yWrUhy4g
342kR6Kb+0Xp19HgvDXl1wOu3ghZWNDohF6D2Nu2LcxPj2L0jlH+TTWx2AmO6wq4
XTdvXhx5kn2GnmgubmGTVz12HbDuPxjZ9V5YbbwtSJReHDLmjraA5CbV+v7eqkKT
tTAGgBItVwKBgQCWHs5ggYo2+qqEK8Xgf4voJ/jsbnWNS6N2r8LKlBJzr1TTwdAF
sxv6zBZNoLzis8VN0I9UZiZ3y6IFmmT/e+uXViCJlIc97zMo10jKbIXdQMuTe9ui
ZBOekaCFSyaKTyhDeC0btgXoowVvvF2QZovgEsbb66+STDFaVFpPI4Rv4QKBgGEd
3O+EFxxZj2DlK9GbIszjaCtXitGgeLkP7SkPxo3srlGXHkwY4vNFDI43GqSlYA4z
POUn7pQdGgYmwu80LrbOuak1AJ74mXHy25Siv5lTye8hdV/MROEjz5prkrYr5yQD
0ARae0SNf7GoaX5IFnZN1Fn0KTELGSE/VDRzDgTZAoGBANot2YcSGm9ZeGZRgReZ
/aRfBPDwdtZ1yh096vilTZhthfoEnYZiNWiKd4PVBfEW7LQ1XgZ3yJBkvVS30jMt
MJuHaITdPZJdABMhF3HR+3WrWmVCJrY2wR8wpRD4t4Kj2M1HBim8JrDKp1m53FMU
D66Ucq9AX+8YCNmicgIhy01i
-----END PRIVATE KEY-----
"""

    func testImportOpenSSHFormat() throws {
        try assertImports(openssh)
    }

    func testImportPKCS1PEM() throws {
        try assertImports(pkcs1)
    }

    func testImportPKCS8PEM() throws {
        try assertImports(pkcs8)
    }

    /// The OpenSSH path recomputes dP/dQ; a wrong value would still load but sign
    /// garbage, so prove a real signature verifies.
    func testImportedOpenSSHKeySignsAndVerifies() async throws {
        let imported = try PrivateKeyImport.parse(openssh)
        let key = try FileKey.from(algorithm: imported.algorithm, privateKeyMaterial: imported.material)
        let message = Data("rsa import round-trip".utf8)
        let sig = try await key.sign(message, context: SignContext(purpose: .sshUserAuth, rsaAlgorithm: .sha256))
        var dec = SSHDecoder(sig.blob)
        _ = try dec.readString()
        let body = try dec.readString()
        let pub = SecKeyCopyPublicKey(try RSAKeySupport.privateKey(fromMaterial: imported.material))!
        var err: Unmanaged<CFError>?
        XCTAssertTrue(SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, body as CFData, &err))
    }

    private func assertImports(_ pem: String) throws {
        let imported = try PrivateKeyImport.parse(pem)
        XCTAssertEqual(imported.algorithm, .rsa)
        let key = try FileKey.from(algorithm: imported.algorithm, privateKeyMaterial: imported.material)
        XCTAssertEqual(key.publicKey.blob.base64EncodedString(), expectedPublicBase64)
    }

    /// A crafted key with a degenerate prime (p or q ≤ 1) makes the CRT modulus
    /// p−1 / q−1 zero; the reduce loop would never terminate. fromComponents must
    /// reject it (fail closed) rather than hang. Returns promptly here.
    func testDegenerateRSAComponentsRejected() {
        let big = Data(repeating: 0xAB, count: 32)   // stand-in n/e/d/iqmp
        for (p, q) in [(Data([1]), big), (big, Data([1])), (Data([0]), big), (big, Data([0]))] {
            XCTAssertThrowsError(
                try RSAPrivateKeyDER.fromComponents(n: big, e: big, d: big, p: p, q: q, iqmp: big))
        }
        // A valid p,q still works (sanity: the guard didn't reject good input).
        XCTAssertNoThrow(
            try RSAPrivateKeyDER.fromComponents(n: big, e: big, d: big, p: big, q: big, iqmp: big))
    }
}
