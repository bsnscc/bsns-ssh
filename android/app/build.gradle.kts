import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "cc.bsns.ssh"
    compileSdk = 35
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "cc.bsns.ssh"
        minSdk = 26
        targetSdk = 35
        versionCode = 18
        versionName = "1.0"
        ndk { abiFilters += "arm64-v8a" }
    }

    buildFeatures { compose = true; buildConfig = true }

    signingConfigs {
        create("release") {
            val props = rootProject.file("keystore.properties")
            if (props.exists()) {
                val k = Properties().apply { props.inputStream().use { load(it) } }
                storeFile = file(k.getProperty("storeFile"))
                storePassword = k.getProperty("storePassword")
                keyAlias = k.getProperty("keyAlias")
                keyPassword = k.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            // R8 on for dead-code shrinking. Keep rules in proguard-rules.pro protect
            // the JNI entry points + the by-name `sign` callback (no obfuscation goal —
            // the app is open source). Use the NON-optimizing config: the aggressive
            // optimizer (proguard-android-optimize.txt) miscompiled the ECDSA signature
            // bit-twiddling in KeystoreSigner.sign → pubkey auth failed (rc=-18). Plain
            // shrinking keeps the signing path correct (verified: live Keystore-key connect).
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":transport"))
    implementation(project(":terminal-view"))   // vendored Termux VT terminal
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.biometric:biometric:1.1.0")        // app-lock (BiometricPrompt)
    // biometric:1.1.0 pulls an old fragment whose startActivityForResult clashes with
    // the Compose ActivityResultRegistry ("lower 16 bits for requestCode"); force-upgrade.
    implementation("androidx.fragment:fragment:1.8.5")
    implementation("com.yubico.yubikit:android:2.5.0")          // YubiKey NFC/USB transport
    implementation("com.yubico.yubikit:piv:2.5.0")              // PIV applet (slot 9A signing)
    implementation("com.yubico.yubikit:fido:2.5.0")             // FIDO2/CTAP2 (sk- security-key SSH keys)
    implementation("androidx.documentfile:documentfile:1.0.1")  // SAF folder access for sync
    implementation(platform("androidx.compose:compose-bom:2024.10.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material:material-icons-extended")   // Material icons (R8 strips unused)

    // JVM unit tests for pure logic (e.g. MoshBootstrap parsing). Run via
    // `./gradlew :app:testDebugUnitTest`. kotlin-test routes to the JUnit4 runner.
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
}
