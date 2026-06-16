// swift-tools-version:5.9
import PackageDescription

// Vendored fork of SwiftTerm (https://github.com/migueldeicaza/SwiftTerm, MIT,
// pinned at 1.13.0) — only the SwiftTerm library target. Patched for desktop-class
// pointer click-drag selection and forwarding PageUp/PageDown to the remote.
// See PATCHES.md. Upstream's Fuzz/Termcast/Benchmark products are dropped (they
// pull external deps we don't need).
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"])
    ]
)
