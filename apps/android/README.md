# tokenstat for Android

This is the native Kotlin/Jetpack Compose client for phones, foldables and
tablets. It uses the same Rust core and JSON dispatch contract as the Apple
client; only the platform UI, Google Play Billing and FCM integration are
Android-specific.

The application ID is `ai.tokenstat.tokenstat`. Builds require JDK 17, Android
SDK 36, the Rust Android targets, and `cargo-ndk`:

```bash
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk --locked
apps/android/gradlew -p apps/android testDebugUnitTest lintDebug lintRelease bundleRelease
```

The launcher pins Gradle 9.1.0 and verifies downloaded distributions. The build
uses Android Gradle Plugin 9.0.1 with built-in Kotlin; release builds enable
both R8 code optimization and optimized resource shrinking. Keep the release
mapping files alongside native symbols for crash diagnosis (CI archives both).

Variant source tasks compile `tokenstat-ffi` for arm64 and x86_64 and generate the
pricing seed. A release bundle is written below
`apps/android/app/build/outputs/bundle/release/`.

Local sign-in and read-only account views work without Firebase configuration.
Push requires `app/google-services.json`. Play upload needs the local upload
keystore (`scripts/android-play-keystore.sh init`) and the Console steps in
[PLAY_RELEASE.md](PLAY_RELEASE.md). Production release is blocked by every
unfinished row in [PARITY.md](PARITY.md).

Build both signed distribution formats with:

```bash
scripts/build-android-release.sh dist/android/1.0.6-115
```

The script loads the existing local Play upload-key environment and produces a
release APK for direct installation and an AAB for Play Console upload. Google
Play signs delivered APKs with its app-signing key; a locally upload-key-signed
APK cannot update those installs when the certificates differ. Neither file is
uploaded by this script.
