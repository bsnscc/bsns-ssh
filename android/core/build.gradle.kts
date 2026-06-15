plugins {
    kotlin("jvm") version "2.1.0"
    kotlin("plugin.serialization") version "2.1.0"
}

repositories { mavenCentral() }

kotlin { jvmToolchain(17) }

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    // Key-material math only (keygen + public-from-private derivation for sync
    // restore). The SSH transport itself is libssh2/OpenSSL over the NDK, not BC.
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    testImplementation(kotlin("test"))
}

tasks.test { useJUnitPlatform() }
