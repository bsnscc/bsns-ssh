// swift-tools-version:5.9
import PackageDescription

// Local wrapper around the vendored libssh2 + OpenSSL xcframework, built from
// source by vendor/build-cssh.sh (libssh2 1.11.0 on OpenSSL 3.5.1, pinned +
// sha256-verified). Referenced by path; the xcframework is gitignored. Run
// vendor/build-cssh.sh to (re)build CSSH.xcframework.
let package = Package(
    name: "CSSH",
    products: [
        .library(name: "CSSH", targets: ["CSSH"]),
    ],
    targets: [
        .binaryTarget(name: "CSSH", path: "CSSH.xcframework"),
    ]
)
