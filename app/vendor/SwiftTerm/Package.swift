// swift-tools-version:5.9
import PackageDescription

// Vendored fork of SwiftTerm (https://github.com/migueldeicaza/SwiftTerm, MIT,
// pinned at 1.13.0) — only the SwiftTerm library target. Patched for touch and
// pointer selection, scrollback that holds its place, and more; every patch is
// listed in PATCHES.md. Upstream's Fuzz/Termcast/Benchmark products are dropped (they
// pull external deps we don't need).
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"],
                resources: [.copy("PrivacyInfo.xcprivacy")])
    ]
)
