import Foundation

// Entry point only. All declarations live in Spike.swift so they stay off the
// main actor (the C sign-callback must be referenceable from libssh2).

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    die("usage: (keygen <type> <keypath>) | (connect <type> <keypath> <host> <port> <user>)")
}

switch args[1] {
case "keygen":
    guard args.count == 4, let kt = KeyType(rawValue: args[2]) else {
        die("usage: keygen <ed25519|ecdsa> <keypath>")
    }
    do { try keygen(kt, args[3]) } catch { die("keygen failed: \(error)") }

case "connect":
    guard args.count == 7, let kt = KeyType(rawValue: args[2]), let port = UInt16(args[5]) else {
        die("usage: connect <ed25519|ecdsa> <keypath> <host> <port> <user>")
    }
    exit(connect(kt, args[3], args[4], port, args[6]))

default:
    die("unknown command: \(args[1])")
}
