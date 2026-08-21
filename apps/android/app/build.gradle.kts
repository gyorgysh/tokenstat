// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
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
        versionCode = 43
        versionName = "0.6.8"
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
    sourceSets["main"].jniLibs.srcDir(layout.buildDirectory.dir("rust-jni"))
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated-assets"))
    kotlinOptions { jvmTarget = "17" }
}

val buildRust by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("scripts/build-ffi-android.sh", project.layout.buildDirectory.dir("rust-jni").get().asFile)
}
tasks.named("preBuild").configure { dependsOn(buildRust) }
val generatePriceBook by tasks.registering(Exec::class) {
    val output = layout.buildDirectory.file("generated-assets/PriceBookSeed.json")
    outputs.file(output)
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("cargo", "run", "-q", "-p", "xtask", "--", "pricing-seed", output.get().asFile)
}
tasks.named("preBuild").configure { dependsOn(generatePriceBook) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.core:core-ktx:1.17.0")
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
