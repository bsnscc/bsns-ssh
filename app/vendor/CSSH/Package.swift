// swift-tools-version:5.9
import PackageDescription

// Local wrapper around the vendored libssh2 + OpenSSL xcframework
// (DimaRU/Libssh2Prebuild, libssh2 1.11.0). Referenced by path so the build
// never depends on xcodebuild's package downloader (which stalls fetching the
// GitHub release asset in this environment). Run vendor/fetch-cssh.sh to
// (re)populate CSSH.xcframework.
let package = Package(
    name: "CSSH",
    products: [
        .library(name: "CSSH", targets: ["CSSH"]),
    ],
    targets: [
        .binaryTarget(name: "CSSH", path: "CSSH.xcframework"),
    ]
)
