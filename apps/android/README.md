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
apps/android/gradlew -p apps/android testDebugUnitTest lintDebug bundleRelease
```

`preBuild` compiles `tokenstat-ffi` for arm64 and x86_64 and generates the
pricing seed. A release bundle is written below
`apps/android/app/build/outputs/bundle/release/`.

Local sign-in and read-only account views work without Firebase configuration.
Push requires `app/google-services.json`. Play upload needs the local upload
keystore (`scripts/android-play-keystore.sh init`) and the Console steps in
[PLAY_RELEASE.md](PLAY_RELEASE.md). Production release is blocked by every
unfinished row in [PARITY.md](PARITY.md).
