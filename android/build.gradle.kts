// Declare every plugin version ONCE here (apply false) so the Kotlin/AGP plugins
// aren't loaded repeatedly across modules (Gradle warns + it's slower). Modules
// apply them without a version.
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("com.android.library") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("org.jetbrains.kotlin.jvm") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.1.0" apply false
}

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
