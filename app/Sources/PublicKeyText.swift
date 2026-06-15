import Foundation
import BsnsSSHCore

/// The `authorized_keys` line for a public key: `<type> <base64-blob> <comment>`.
func authorizedKeysLine(_ key: SSHPublicKey) -> String {
    let comment = key.comment.isEmpty ? "" : " \(key.comment)"
    return "\(key.algorithm.rawValue) \(key.blob.base64EncodedString())\(comment)"
}
