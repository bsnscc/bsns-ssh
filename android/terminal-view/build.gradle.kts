plugins { id("com.android.library") version "8.7.2" }
android {
    namespace = "com.termux.view"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    api(project(":terminal-emulator"))
    implementation("androidx.annotation:annotation:1.9.1")
}
