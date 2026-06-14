// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bsns-ssh",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BsnsSSHCore", targets: ["BsnsSSHCore"]),
    ],
    targets: [
        // Device-independent core: key-backend protocol, SSH agent, wire
        // codec, signature framing, crypto envelope. Buildable and testable
        // on the Mac with no device or app target.
        .target(name: "BsnsSSHCore"),
        .testTarget(
            name: "BsnsSSHCoreTests",
            dependencies: ["BsnsSSHCore"]
        ),
    ]
)
