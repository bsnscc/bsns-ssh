plugins {
    kotlin("jvm") version "2.1.0"
}

repositories { mavenCentral() }

kotlin { jvmToolchain(17) }

dependencies {
    testImplementation(kotlin("test"))
}

tasks.test { useJUnitPlatform() }
