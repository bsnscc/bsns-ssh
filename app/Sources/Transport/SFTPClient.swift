import Foundation
import CSSH
import BsnsSSHCore

/// One directory entry from an SFTP listing.
struct SFTPEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: UInt32
}

enum SFTPError: Error, LocalizedError {
    case initFailed
    case op(String)

    var errorDescription: String? {
        switch self {
        case .initFailed: return "Couldn't start an SFTP session on the server."
        case .op(let m): return m
        }
    }
}

/// A persistent SFTP session over its own authenticated libssh2 connection. All
/// libssh2 calls run on a private serial queue (the session isn't thread-safe);
/// the public API is async. Authentication goes through the agent, same as the
/// interactive shell, so a private key never touches the transport.
final class SFTPClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc.bsns.ssh.sftp")
    private var fd: Int32 = -1
    private var session: OpaquePointer?
    private var sftp: OpaquePointer?

    // libssh2 SFTP constants (hardcoded so we don't depend on macro import).
    private static let OPENFILE: Int = 0
    private static let OPENDIR: Int = 1
    private static let FXF_READ: UInt = 0x01
    private static let FXF_WRITE: UInt = 0x02
    private static let FXF_CREAT: UInt = 0x08
    private static let FXF_TRUNC: UInt = 0x10
    private static let S_IFMT: UInt32 = 0o170000
    private static let S_IFDIR: UInt32 = 0o040000

    /// Connect, authenticate, and open the SFTP subsystem. Rethrows the SSH
    /// host-key / auth errors so the UI can run its TOFU prompt and retry.
    func connect(host: String, port: UInt16, user: String, agent: Agent,
                 knownHosts: KnownHosts, keyBlob: Data? = nil) async throws {
        let identities = SSHShell.restrict(await agent.identities(), to: keyBlob)
        try await run {
            let (fd, session) = try SSHShell.openAuthenticatedSession(
                host: host, port: port, user: user, agent: agent,
                identities: identities, password: nil, knownHosts: knownHosts)
            self.fd = fd
            self.session = session
            guard let sftp = libssh2_sftp_init(session) else {
                libssh2_session_free(session); close(fd)
                self.session = nil; self.fd = -1
                throw SFTPError.initFailed
            }
            self.sftp = sftp
        }
    }

    func list(_ path: String) async throws -> [SFTPEntry] {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            guard let dir = path.withCString({ libssh2_sftp_open_ex(sftp, $0, UInt32(strlen($0)), 0, 0, Int32(Self.OPENDIR)) }) else {
                throw SFTPError.op("Couldn't open \(path).")
            }
            defer { libssh2_sftp_close_handle(dir) }
            var entries: [SFTPEntry] = []
            var nameBuf = [CChar](repeating: 0, count: 1024)
            while true {
                var attrs = LIBSSH2_SFTP_ATTRIBUTES()
                let n = libssh2_sftp_readdir_ex(dir, &nameBuf, nameBuf.count, nil, 0, &attrs)
                if n <= 0 { break }   // 0 = end of directory, <0 = error
                // Decode exactly the n bytes returned — the name isn't NUL-terminated
                // and may not be valid UTF-8, so bound by the real length and decode
                // lossily rather than trusting String(cString:).
                let nameBytes = nameBuf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
                let name = String(decoding: nameBytes, as: UTF8.self)
                if name == "." || name == ".." { continue }
                let perms = UInt32(attrs.permissions)
                entries.append(SFTPEntry(name: name,
                                         isDirectory: (perms & Self.S_IFMT) == Self.S_IFDIR,
                                         size: UInt64(attrs.filesize),
                                         permissions: perms))
            }
            return entries.sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory
                                                 : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    func download(_ path: String) async throws -> Data {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            guard let handle = path.withCString({ libssh2_sftp_open_ex(sftp, $0, UInt32(strlen($0)), Self.FXF_READ, 0, Int32(Self.OPENFILE)) }) else {
                throw SFTPError.op("Couldn't open \(path).")
            }
            defer { libssh2_sftp_close_handle(handle) }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 32768)
            while true {
                let n = buf.withUnsafeMutableBytes {
                    libssh2_sftp_read(handle, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
                }
                if n > 0 { out.append(contentsOf: buf[0 ..< n]) }
                else if n == 0 { break }
                else { throw SFTPError.op("Read failed.") }
            }
            return out
        }
    }

    func upload(_ data: Data, to path: String) async throws {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            let flags = Self.FXF_WRITE | Self.FXF_CREAT | Self.FXF_TRUNC
            guard let handle = path.withCString({ libssh2_sftp_open_ex(sftp, $0, UInt32(strlen($0)), flags, 0o644, Int32(Self.OPENFILE)) }) else {
                throw SFTPError.op("Couldn't create \(path).")
            }
            defer { libssh2_sftp_close_handle(handle) }
            try data.withUnsafeBytes { raw in
                var off = 0
                let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                while off < raw.count {
                    let n = libssh2_sftp_write(handle, base + off, raw.count - off)
                    if n <= 0 { throw SFTPError.op("Write failed (code \(n)).") }   // 0 = no progress
                    off += n
                }
            }
        }
    }

    /// Stream a remote file to a local file in fixed-size chunks — bounded
    /// memory, no whole-file Data. Used for the browser's download (a huge file
    /// can't OOM the app).
    func download(_ path: String, toFile url: URL) async throws {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            guard let handle = path.withCString({ libssh2_sftp_open_ex(sftp, $0, UInt32(strlen($0)), Self.FXF_READ, 0, Int32(Self.OPENFILE)) }) else {
                throw SFTPError.op("Couldn't open \(path).")
            }
            defer { libssh2_sftp_close_handle(handle) }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: url) else { throw SFTPError.op("Couldn't write the local file.") }
            defer { try? fh.close() }
            var buf = [UInt8](repeating: 0, count: 32768)
            while true {
                let n = buf.withUnsafeMutableBytes {
                    libssh2_sftp_read(handle, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
                }
                if n > 0 { try fh.write(contentsOf: Data(buf[0 ..< n])) }
                else if n == 0 { break }
                else { throw SFTPError.op("Read failed.") }
            }
        }
    }

    /// Stream a local file to a remote path in fixed-size chunks (bounded memory).
    func upload(fromFile url: URL, to path: String) async throws {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            let flags = Self.FXF_WRITE | Self.FXF_CREAT | Self.FXF_TRUNC
            guard let handle = path.withCString({ libssh2_sftp_open_ex(sftp, $0, UInt32(strlen($0)), flags, 0o644, Int32(Self.OPENFILE)) }) else {
                throw SFTPError.op("Couldn't create \(path).")
            }
            defer { libssh2_sftp_close_handle(handle) }
            guard let fh = try? FileHandle(forReadingFrom: url) else { throw SFTPError.op("Couldn't read the file.") }
            defer { try? fh.close() }
            while true {
                let chunk = (try? fh.read(upToCount: 32768)) ?? nil
                guard let chunk, !chunk.isEmpty else { break }
                try chunk.withUnsafeBytes { raw in
                    var off = 0
                    var stalls = 0
                    let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    while off < raw.count {
                        let n = libssh2_sftp_write(handle, base + off, raw.count - off)
                        if n < 0 { throw SFTPError.op("Write failed (code \(n)).") }
                        if n == 0 {   // no progress on a blocking handle — bail rather than spin
                            stalls += 1
                            if stalls > 1000 { throw SFTPError.op("Write stalled.") }
                            continue
                        }
                        stalls = 0
                        off += n
                    }
                }
            }
        }
    }

    func makeDirectory(_ path: String) async throws {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            let rc = path.withCString { libssh2_sftp_mkdir_ex(sftp, $0, UInt32(strlen($0)), 0o755) }
            if rc != 0 { throw SFTPError.op("Couldn't create folder.") }
        }
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        try await run {
            guard let sftp = self.sftp else { throw SFTPError.initFailed }
            let rc = path.withCString { c -> Int32 in
                isDirectory ? libssh2_sftp_rmdir_ex(sftp, c, UInt32(strlen(c)))
                            : libssh2_sftp_unlink_ex(sftp, c, UInt32(strlen(c)))
            }
            if rc != 0 { throw SFTPError.op("Couldn't delete \(path).") }
        }
    }

    func disconnect() {
        queue.async {
            if let sftp = self.sftp { libssh2_sftp_shutdown(sftp); self.sftp = nil }
            if let session = self.session {
                libssh2_session_disconnect_ex(session, 0, "bye", "")
                libssh2_session_free(session); self.session = nil
            }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
    }

    /// Hop a blocking libssh2 op onto the serial queue as an async call.
    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
