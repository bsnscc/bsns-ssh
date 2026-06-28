import Foundation
import BsnsSSHCore

/// The terminal byte-stream behind a `TerminalSession`, independent of how it's
/// carried — an interactive SSH channel (`SSHShell`) or a mosh UDP session
/// (`MoshSession`). The session binds to this, so swapping transports (or
/// reconnecting) never touches the view. Port forwarding is SSH-only and stays
/// off this protocol; `TerminalSession` reaches for `SSHShell` directly there.
protocol TerminalTransport: AnyObject {
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)? { get set }
    var onClosed: (@Sendable (String?) -> Void)? { get set }
    func write(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int32, rows: Int32)
    /// Ask the transport to replay its current terminal contents if it owns a
    /// separate framebuffer. Byte-stream transports can ignore this.
    func requestDisplayRefresh()
    func disconnect()
}

extension TerminalTransport {
    func requestDisplayRefresh() {}
}

// SSHShell already exposes exactly this surface.
extension SSHShell: TerminalTransport {}
