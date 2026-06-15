import Foundation
import BsnsSSHCore

/// The `authorized_keys` line for a public key: `<type> <base64-blob> <comment>`.
/// The comment is sanitized — control characters (notably newlines) are stripped
/// so an imported/crafted comment can't inject extra authorized_keys lines during
/// `ssh-copy-id` installation.
func authorizedKeysLine(_ key: SSHPublicKey) -> String {
    let printable = key.comment.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
    let safeComment = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
    let comment = safeComment.isEmpty ? "" : " \(safeComment)"
    return "\(key.algorithm.rawValue) \(key.blob.base64EncodedString())\(comment)"
}
