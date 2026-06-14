// swift-tools-version: 6.0
import PackageDescription

// Throwaway de-risk spike (build-order step 0): prove that libssh2's
// client publickey-auth sign-callback authenticates a real sshd using a
// signature our own code produces — the private key never enters libssh2.
// Kept as a separate package so the core stays free of a system-libssh2 dep.
let package = Package(
    name: "libssh2-signcb-spike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../..") // BsnsSSHCore (reuse the real SSH wire codec)
    ],
    targets: [
        .systemLibrary(
            name: "CLibssh2",
            path: "Sources/CLibssh2",
            pkgConfig: "libssh2",
            providers: [.brew(["libssh2"])]
        ),
        .executableTarget(
            name: "ssh-signcb-spike",
            dependencies: [
                "CLibssh2",
                .product(name: "BsnsSSHCore", package: "bsns-ssh"),
            ]
        ),
    ]
)
