rootProject.name = "bsns-ssh-android"

// Pure-Kotlin core (platform-independent): SSH wire codec, signature framing,
// known_hosts, config envelope — ported from Swift BsnsSSHCore, kept byte-parity
// via shared test vectors. The Android :app and the libssh2 :transport (NDK/JNI)
// modules are added once the NDK + an emulator/device are available.
include(":core")
