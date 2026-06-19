import Foundation
import Testing
@testable import BsnsSSHCore

@Suite("webauthn-sk signature + sk-ecdsa public key (PROTOCOL.u2f)")
struct WebAuthnSignatureTests {

    @Test("sk-ecdsa public blob is well-formed (cross-platform contract)")
    func skEcdsaBlob() throws {
        var point = Data([0x04]); point.append(Data(repeating: 0x11, count: 32)); point.append(Data(repeating: 0x22, count: 32))
        let blob = SSHKeyFormat.skEcdsaPublicBlob(x963Point: point, application: "tools.bsns.cc")
        var d = SSHDecoder(blob)
        #expect(try d.readStringUTF8() == "sk-ecdsa-sha2-nistp256@openssh.com")
        #expect(try d.readStringUTF8() == "nistp256")
        #expect(try d.readString() == point)
        #expect(try d.readStringUTF8() == "tools.bsns.cc")
    }

    @Test("DER ECDSA signature parses to fixed 64-byte r||s, stripping sign padding")
    func derToRawRS() throws {
        // r = 0x44… (no high bit, 32 bytes); s = 0x80… (high bit set → DER adds a 0x00
        // sign byte, making the INTEGER content 33 bytes, which we must strip back to 32).
        let r = [UInt8](repeating: 0x44, count: 32)
        let sCore = [UInt8](repeating: 0x80, count: 32)          // high bit set
        let sDER = [UInt8](repeating: 0x00, count: 1) + sCore     // DER sign-padded → 33 bytes
        var der: [UInt8] = []
        der += [0x02, UInt8(r.count)] + r
        der += [0x02, UInt8(sDER.count)] + sDER
        let body = [0x30, UInt8(der.count)] + der
        let raw = try WebAuthnSignature.rawRS(fromDER: Data(body))
        #expect(raw.count == 64)
        #expect(Array(raw.prefix(32)) == r)
        #expect(Array(raw.suffix(32)) == sCore)                   // sign byte stripped, still 32
    }

    @Test("short DER integer is left-padded to 32 bytes")
    func shortIntegerPadded() throws {
        let r: [UInt8] = [0x01, 0x02, 0x03]                       // 3 bytes → pad to 32
        let s = [UInt8](repeating: 0x09, count: 32)
        var der: [UInt8] = []
        der += [0x02, UInt8(r.count)] + r
        der += [0x02, UInt8(s.count)] + s
        let raw = try WebAuthnSignature.rawRS(fromDER: Data([0x30, UInt8(der.count)] + der))
        #expect(Array(raw.prefix(32)) == [UInt8](repeating: 0, count: 29) + r)
        #expect(Array(raw.suffix(32)) == s)
    }

    // --- CBOR encode helpers (tests only) -------------------------------------
    private func cborUInt(_ n: UInt64) -> [UInt8] {
        if n <= 23 { return [UInt8(n)] }
        if n <= 0xff { return [0x18, UInt8(n)] }
        if n <= 0xffff { return [0x19, UInt8(n >> 8), UInt8(n & 0xff)] }
        return [0x1a, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    }
    private func cborNeg(_ v: Int) -> [UInt8] { var h = cborUInt(UInt64(-1 - v)); h[0] |= 0x20; return h }
    private func cborBytes(_ d: [UInt8]) -> [UInt8] { var h = cborUInt(UInt64(d.count)); h[0] |= 0x40; return h + d }
    private func cborText(_ s: String) -> [UInt8] { let b = [UInt8](s.utf8); var h = cborUInt(UInt64(b.count)); h[0] |= 0x60; return h + b }
    private func cborMap(_ count: Int) -> [UInt8] { var h = cborUInt(UInt64(count)); h[0] |= 0xa0; return h }

    @Test("CBOR decodes maps, ints, byte strings; int-key lookup handles negatives")
    func cborBasics() throws {
        // { 1: 2, 3: -7, -1: 1, -2: h'AA…(3) }
        let bytes = cborMap(4) + cborUInt(1) + cborUInt(2) + cborUInt(3) + cborNeg(-7)
            + cborNeg(-1) + cborUInt(1) + cborNeg(-2) + cborBytes([0xAA, 0xBB, 0xCC])
        let v = try CBOR.decode(Data(bytes))
        #expect(v.value(intKey: 1) == .uint(2))
        #expect(v.value(intKey: 3) == .negint(-7))
        #expect(v.value(intKey: -1) == .uint(1))
        #expect(v.value(intKey: -2) == .bytes(Data([0xAA, 0xBB, 0xCC])))
        #expect(v.value(intKey: 9) == nil)
    }

    @Test("malformed CBOR fails closed (no trap/hang) on hostile lengths & counts")
    func cborHardening() {
        // A malicious/fuzzed authenticator could send a length or count far larger
        // than the buffer. These must throw, not trap on UInt64->Int or attempt an
        // attacker-sized allocation. info=27 → an 8-byte argument of 0xFFFF…FF.
        let huge: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        let byteStr = [UInt8(0x40 | 27)] + huge   // byte string, length = UInt64.max
        let textStr = [UInt8(0x60 | 27)] + huge   // text string, length = UInt64.max
        let array   = [UInt8(0x80 | 27)] + huge   // array, count = UInt64.max
        let map     = [UInt8(0xa0 | 27)] + huge   // map, count = UInt64.max
        let negint  = [UInt8(0x20 | 27)] + huge   // negint, n = UInt64.max (> Int64.max)
        for bad in [byteStr, textStr, array, map, negint] {
            #expect(throws: (any Error).self) { try CBOR.decode(Data(bad)) }
        }
    }

    /// Build a synthetic COSE EC2/P-256/ES256 key for `x`,`y`.
    private func coseKey(x: [UInt8], y: [UInt8]) -> [UInt8] {
        cborMap(5) + cborUInt(1) + cborUInt(2) + cborUInt(3) + cborNeg(-7)
            + cborNeg(-1) + cborUInt(1) + cborNeg(-2) + cborBytes(x) + cborNeg(-3) + cborBytes(y)
    }

    @Test("attestation object → sk-ecdsa public blob")
    func attestationToPublicBlob() throws {
        let x = [UInt8](repeating: 0x31, count: 32)
        let y = [UInt8](repeating: 0x32, count: 32)
        let credId = [UInt8](repeating: 0xCC, count: 4)
        var authData: [UInt8] = []
        authData += [UInt8](repeating: 0xAA, count: 32)   // rpIdHash
        authData += [0x45]                                 // flags
        authData += [0x00, 0x00, 0x00, 0x09]               // counter
        authData += [UInt8](repeating: 0xBB, count: 16)    // aaguid
        authData += [0x00, UInt8(credId.count)]            // credIdLen (big-endian)
        authData += credId
        authData += coseKey(x: x, y: y)
        let attestation = cborMap(1) + cborText("authData") + cborBytes(authData)

        let blob = try WebAuthnSignature.publicKeyBlob(fromAttestationObject: Data(attestation), application: "tools.bsns.cc")
        var d = SSHDecoder(blob)
        #expect(try d.readStringUTF8() == "sk-ecdsa-sha2-nistp256@openssh.com")
        #expect(try d.readStringUTF8() == "nistp256")
        #expect(try d.readString() == Data([0x04] + x + y))
        #expect(try d.readStringUTF8() == "tools.bsns.cc")

        let (flags, counter) = try WebAuthnSignature.authenticatorFlagsAndCounter(Data(authData))
        #expect(flags == 0x45)
        #expect(counter == 9)
    }

    @Test("authenticator extensions = trailing bytes past the 37-byte prefix")
    func authenticatorExtensions() {
        // No extensions: exactly 37 bytes → empty.
        let bare = Data(repeating: 0, count: 37)
        #expect(WebAuthnSignature.authenticatorExtensions(bare) == Data())
        // With extensions: trailing CBOR bytes are returned verbatim.
        let ext = Data([0xa1, 0x6b, 0x68, 0x6d, 0x61, 0x63])
        #expect(WebAuthnSignature.authenticatorExtensions(bare + ext) == ext)
    }

    @Test("webauthn-sk signature blob matches the PROTOCOL.u2f layout")
    func signatureBlobLayout() throws {
        let r = [UInt8](repeating: 0x33, count: 32)   // high bit clear → mpint == raw
        let sCore = [UInt8](repeating: 0x88, count: 32)  // high bit set → mpint prepends 0x00
        let sDER = [0x00] + sCore                      // DER sign byte
        var der: [UInt8] = []
        der += [0x02, UInt8(r.count)] + r
        der += [0x02, UInt8(sDER.count)] + sDER
        let derSig = Data([0x30, UInt8(der.count)] + der)

        let origin = "https://tools.bsns.cc"
        let clientData = Data(#"{"type":"webauthn.get","challenge":"AAAA","origin":"https://tools.bsns.cc"}"#.utf8)
        let blob = try WebAuthnSignature.signatureBlob(
            derSignature: derSig, flags: 0x05, counter: 0x01020304,
            origin: origin, clientDataJSON: clientData)

        var d = SSHDecoder(blob)
        #expect(try d.readStringUTF8() == "webauthn-sk-ecdsa-sha2-nistp256@openssh.com")
        // ecdsa_signature = string( mpint r || mpint s )
        var sig = SSHDecoder(try d.readString())
        #expect(try sig.readString() == Data(r))            // r high bit clear → mpint == raw 32 bytes
        #expect(try sig.readString() == Data([0x00] + sCore))  // s high bit set → mpint prepends 0x00
        #expect(try d.readByte() == 0x05)
        #expect(try d.readUInt32() == 0x01020304)
        #expect(try d.readStringUTF8() == origin)
        #expect(try d.readString() == clientData)
        #expect(try d.readString() == Data())       // empty extensions
    }
}
