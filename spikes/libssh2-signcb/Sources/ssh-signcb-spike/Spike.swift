import Foundation
import CryptoKit
import Darwin
import CLibssh2
import BsnsSSHCore

// Proves the linchpin of the whole architecture: libssh2 authenticates a
// real SSH server using a signature produced by *our* callback — the private
// key is never handed to libssh2. Two key types:
//   ed25519 -> callback returns the raw 64-byte signature (libssh2 frames it)
//   ecdsa   -> callback returns mpint(r) || mpint(s) (our SSHEncoder), the
//              exact framing a Secure Enclave P-256 key will use.
//
// Declarations live here (not main.swift) so they aren't main-actor-isolated
// and the C function pointer is reachable from libssh2's nonisolated calls.

enum KeyType: String { case ed25519, ecdsa }

/// Wraps a private key and produces the *inner* SSH signature blob for a
/// buffer — i.e. exactly the bytes libssh2's sign-callback must return.
final class Signer {
    let innerSignature: (Data) -> Data?
    init(_ f: @escaping (Data) -> Data?) { self.innerSignature = f }
}

// C sign-callback. No captured state — the Signer is reached via `abstract`,
// which we pass to libssh2_userauth_publickey.
let signCallback: @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 = { _, sig, sigLen, data, dataLen, abstract in
    guard let sig, let sigLen, let data, let ctx = abstract?.pointee else { return -1 }
    let signer = Unmanaged<Signer>.fromOpaque(ctx).takeUnretainedValue()
    let input = Data(UnsafeBufferPointer(start: data, count: dataLen))
    guard let inner = signer.innerSignature(input), let buf = malloc(inner.count) else {
        return -1
    }
    inner.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: inner.count)
    sig.pointee = buf.assumingMemoryBound(to: UInt8.self) // libssh2 frees this
    sigLen.pointee = inner.count
    return 0
}

func tcpConnect(host: String, port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { close(fd); return nil }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 { close(fd); return nil }
    return fd
}

func loadSigner(_ keyType: KeyType, _ keyPath: String) throws -> (pubBlob: Data, signer: Signer) {
    let raw = try Data(contentsOf: URL(fileURLWithPath: keyPath))
    switch keyType {
    case .ed25519:
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        let pub = SSHEncoder.build {
            $0.writeString("ssh-ed25519")
            $0.writeString(key.publicKey.rawRepresentation)
        }
        return (pub, Signer { try? key.signature(for: $0) })
    case .ecdsa:
        let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        let pub = SSHEncoder.build {
            $0.writeString("ecdsa-sha2-nistp256")
            $0.writeString("nistp256")
            $0.writeString(key.publicKey.x963Representation)
        }
        return (pub, Signer {
            guard let sig = try? key.signature(for: $0) else { return nil }
            let rs = sig.rawRepresentation // 64 bytes: r || s
            return SSHEncoder.build {
                $0.writeMPInt(Data(rs.prefix(32)))
                $0.writeMPInt(Data(rs.suffix(32)))
            }
        })
    }
}

func keygen(_ keyType: KeyType, _ keyPath: String) throws {
    let url = URL(fileURLWithPath: keyPath)
    switch keyType {
    case .ed25519:
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: url)
        let blob = SSHEncoder.build {
            $0.writeString("ssh-ed25519")
            $0.writeString(key.publicKey.rawRepresentation)
        }
        print("ssh-ed25519 \(blob.base64EncodedString()) bsns-ssh-spike")
    case .ecdsa:
        let key = P256.Signing.PrivateKey()
        try key.rawRepresentation.write(to: url)
        let blob = SSHEncoder.build {
            $0.writeString("ecdsa-sha2-nistp256")
            $0.writeString("nistp256")
            $0.writeString(key.publicKey.x963Representation)
        }
        print("ecdsa-sha2-nistp256 \(blob.base64EncodedString()) bsns-ssh-spike")
    }
}

func connect(_ keyType: KeyType, _ keyPath: String, _ host: String, _ port: UInt16, _ user: String) -> Int32 {
    let pubBlob: Data
    let signer: Signer
    do {
        (pubBlob, signer) = try loadSigner(keyType, keyPath)
    } catch {
        print("key load failed: \(error)"); return 1
    }

    guard libssh2_init(0) == 0 else { print("libssh2_init failed"); return 1 }
    defer { libssh2_exit() }
    guard let fd = tcpConnect(host: host, port: port) else { print("tcp connect failed"); return 1 }
    defer { close(fd) }
    guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { print("session init failed"); return 1 }
    defer { libssh2_session_free(session) }
    libssh2_session_set_blocking(session, 1)
    guard libssh2_session_handshake(session, fd) == 0 else { print("handshake failed"); return 1 }

    var abstract: UnsafeMutableRawPointer? = Unmanaged.passUnretained(signer).toOpaque()
    let rc: Int32 = withExtendedLifetime(signer) {
        pubBlob.withUnsafeBytes { (pk: UnsafeRawBufferPointer) in
            withUnsafeMutablePointer(to: &abstract) { absP in
                user.withCString { cuser in
                    libssh2_userauth_publickey(
                        session, cuser,
                        pk.bindMemory(to: UInt8.self).baseAddress, pk.count,
                        signCallback, absP
                    )
                }
            }
        }
    }

    if rc == 0 {
        print("AUTH OK — \(keyType.rawValue) via sign-callback; libssh2 never saw the private key")
        return 0
    }
    var msg: UnsafeMutablePointer<CChar>?
    let code = libssh2_session_last_error(session, &msg, nil, 0)
    print("AUTH FAILED rc=\(rc) code=\(code): \(msg.map { String(cString: $0) } ?? "?")")
    return 1
}
