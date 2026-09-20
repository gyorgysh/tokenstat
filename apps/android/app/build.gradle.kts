// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import org.gradle.api.tasks.Exec
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.OutputDirectory

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

if (file("google-services.json").exists()) apply(plugin = "com.google.gms.google-services")

android {
    namespace = "ai.tokenstat.tokenstat"
    compileSdk = 36

    defaultConfig {
        applicationId = "ai.tokenstat.tokenstat"
        minSdk = 28
        targetSdk = 36
        versionCode = 117
        versionName = "1.0.8"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    signingConfigs {
        create("play") {
            val path = System.getenv("TOKENSTAT_ANDROID_KEYSTORE")
            if (!path.isNullOrBlank() && file(path).isFile) {
                storeFile = file(path)
                storePassword = System.getenv("TOKENSTAT_ANDROID_STORE_PASSWORD")
                keyAlias = System.getenv("TOKENSTAT_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("TOKENSTAT_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            ndk.debugSymbolLevel = "FULL"
            val keyStore = System.getenv("TOKENSTAT_ANDROID_KEYSTORE")
            if (!keyStore.isNullOrBlank() && file(keyStore).isFile) {
                signingConfig = signingConfigs.getByName("play")
            }
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging { jniLibs.useLegacyPackaging = false }
}

// The Variant API marks these directories as generated and wires task dependencies.
abstract class GenerateAndroidFiles : Exec() {
    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    init {
        // Cargo/scripts own incremental work; their inputs span the Rust workspace.
        outputs.upToDateWhen { false }
    }
}

val buildRust by tasks.registering(GenerateAndroidFiles::class) {
    outputDirectory.set(layout.buildDirectory.dir("rust-jni"))
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("scripts/build-ffi-android.sh", outputDirectory.get().asFile)
}
val generatePriceBook by tasks.registering(GenerateAndroidFiles::class) {
    outputDirectory.set(layout.buildDirectory.dir("generated-assets/pricing"))
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("cargo", "run", "-q", "-p", "xtask", "--", "pricing-seed",
        outputDirectory.file("PriceBookSeed.json").get().asFile)
}
val generateNotices by tasks.registering(GenerateAndroidFiles::class) {
    outputDirectory.set(layout.buildDirectory.dir("generated-assets/notices"))
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("scripts/notices-android.sh",
        outputDirectory.file("THIRD_PARTY_NOTICES.md").get().asFile)
}
androidComponents {
    onVariants { variant ->
        variant.sources.jniLibs?.addGeneratedSourceDirectory(buildRust, GenerateAndroidFiles::outputDirectory)
        variant.sources.assets?.addGeneratedSourceDirectory(generatePriceBook, GenerateAndroidFiles::outputDirectory)
        variant.sources.assets?.addGeneratedSourceDirectory(generateNotices, GenerateAndroidFiles::outputDirectory)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.navigation:navigation-compose:2.9.5")
    implementation("androidx.browser:browser:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("com.android.billingclient:billing-ktx:9.1.0")
    implementation(platform("com.google.firebase:firebase-bom:34.3.0"))
    implementation("com.google.firebase:firebase-messaging")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
