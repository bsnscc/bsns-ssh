// Supply-chain hardening: pin the exact resolved version of every dependency
// (direct + transitive) into a per-module `gradle.lockfile`, so every build
// resolves an identical graph and a swapped/republished artifact is caught.
// The native crypto stack (OpenSSL/libssh2/mosh) is already built from source
// with pinned SHAs; this covers the Gradle/Maven layer.
//
// Regenerate after a deliberate dependency change:
//   ./gradlew :app:dependencies :transport:dependencies :core:dependencies \
//     :terminal-view:dependencies :terminal-emulator:dependencies --write-locks
subprojects {
    dependencyLocking {
        lockAllConfigurations()
    }
}
