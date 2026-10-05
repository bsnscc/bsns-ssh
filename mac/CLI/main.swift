import Foundation

// bsns — ask the person at the other end of this machine a question, or tell
// them something, from a script. Talks to the running bsns.SSH app, which gets
// the message to them and brings the answer back.
//
//   bsns ask "Deploy integration to prod?" --option approve --option rollback
//   bsns notify "Build finished"
//
// `ask` waits and prints the chosen option. Exit status: 0 answered (or notice
// delivered), 1 usage, 2 the app isn't running, 3 no answer (expired or
// dismissed).

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage: bsns ask <question> --option <answer> [--option <answer> …] [--source <name>] [--timeout <seconds>]
       bsns notify <message> [--source <name>]
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let verb = arguments.first, verb == "ask" || verb == "notify" else { fail(usage, 1) }
arguments.removeFirst()

var text: String?
var options: [String] = []
var source: String?
var timeout: Double?
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    func value() -> String {
        index += 1
        guard index < arguments.count else { fail("\(argument) needs a value\n\(usage)", 1) }
        return arguments[index]
    }
    switch argument {
    case "--option", "-o": options.append(value())
    case "--source", "-s": source = value()
    case "--timeout", "-t":
        guard let seconds = Double(value()), seconds > 0 else { fail("--timeout needs a number of seconds", 1) }
        timeout = seconds
    default:
        guard text == nil, !argument.hasPrefix("--") else { fail(usage, 1) }
        text = argument
    }
    index += 1
}
guard let text, !text.isEmpty else { fail(usage, 1) }
if verb == "ask", options.isEmpty { fail("ask needs at least one --option\n\(usage)", 1) }
if verb == "notify", !options.isEmpty { fail("notify takes no options — use ask\n\(usage)", 1) }

var request: [String: Any] = ["op": verb, "text": text, "options": options]
if let source { request["source"] = source }
if let timeout { request["timeout"] = timeout }
// What started this, when the caller didn't say: the parent process's name.
if source == nil {
    var name = [CChar](repeating: 0, count: 256)
    if proc_name(getppid(), &name, UInt32(name.count)) > 0 { request["source"] = String(cString: name) }
}

let path = NSHomeDirectory() + "/.bsns/control.sock"
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("bsns: couldn't open a socket", 2) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("bsns: socket path too long", 2) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { fail("bsns: the bsns.SSH app isn't running on this machine (or isn't accepting requests)", 2) }

var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
var line = try! JSONSerialization.data(withJSONObject: request)
line.append(0x0a)
let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
guard sent == line.count else { fail("bsns: couldn't reach the app", 2) }

var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !response.contains(0x0a) {
    let count = read(fd, &buffer, buffer.count)
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { break }
    response.append(contentsOf: buffer[0..<count])
}
guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
    fail("bsns: the app closed the connection without answering", 3)
}
if let choice = object["choice"] as? String {
    print(choice)
    exit(0)
}
if object["ok"] as? Bool == true { exit(0) }
fail("bsns: \(object["error"] as? String ?? "no answer")", 3)
