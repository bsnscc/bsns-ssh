import java.util.Properties

plugins {
    id("com.android.application") version "8.7.2"
    id("org.jetbrains.kotlin.android") version "2.1.0"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0"
    id("com.github.triplet.play") version "3.11.0"   // Play Developer API upload
}

android {
    namespace = "cc.bsns.ssh"
    compileSdk = 35
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "cc.bsns.ssh"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
    }

    buildFeatures { compose = true }

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
            // R8 off for now: KeystoreSigner.sign is called from native by name —
            // add a keep rule before enabling minification.
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// Play Developer API upload (./gradlew :app:publishReleaseBundle). The service
// account JSON is supplied out-of-band — PLAY_SERVICE_ACCOUNT_JSON env var, or a
// gitignored android/play-service-account.json. The app must already exist in
// the Play Console (the API can't create the listing) and the service account
// must have release access to it.
play {
    val envCreds = System.getenv("PLAY_SERVICE_ACCOUNT_JSON")
    serviceAccountCredentials.set(
        if (envCreds != null) file(envCreds) else rootProject.file("play-service-account.json")
    )
    track.set("internal")
    defaultToAppBundles.set(true)
}

dependencies {
    implementation(project(":transport"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
}
