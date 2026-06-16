pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "bsns-ssh-android"

// Pure-Kotlin core (platform-independent): SSH wire codec, agent protocol,
// key backends, known_hosts, config envelope — ported from Swift, byte-parity
// via shared test vectors.
include(":core")

// Android library: the libssh2 (NDK) SSH transport with the JNI sign-bridge to
// a non-extractable Keystore key. Built/tested on the arm64 emulator.
include(":transport")

// Vendored Termux terminal emulator + view (GPLv3), forked so TerminalSession
// is backed by our SSH session instead of a local process.
include(":terminal-emulator")
include(":terminal-view")

// The Compose app.
include(":app")
