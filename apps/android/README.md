# tokenstat for Android

This is the native Kotlin/Jetpack Compose client for phones, foldables and
tablets. It uses the same Rust core and JSON dispatch contract as the Apple
client; only the platform UI, Google Play Billing and FCM integration are
Android-specific.

The application ID is `ai.tokenstat.tokenstat`. Builds require JDK 17, Android
SDK 37.0, the Rust Android targets, and `cargo-ndk`:

```bash
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk --locked
apps/android/gradlew -p apps/android testDebugUnitTest lintDebug lintRelease bundleRelease
```

The launcher pins Gradle 9.8.0 and verifies downloaded distributions. The build
uses Android Gradle Plugin 9.1.1 with built-in Kotlin; release builds enable
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
scripts/build-android-release.sh dist/android/1.3.0-139
```

The script loads the existing local Play upload-key environment and produces a
release APK for direct installation and an AAB for Play Console upload. Google
Play signs delivered APKs with its app-signing key; a locally upload-key-signed
APK cannot update those installs when the certificates differ. Neither file is
uploaded by this script.

Usage at a Glance is a resizable home-screen widget with automatic light/dark
appearance, Today/Last 7 Days switching, a weekly chart on wide and tall layouts and
refresh through WorkManager while the app is closed. Values are US dollars at
list rates across the account. Its backup-excluded snapshot holds only a hashed
owner and daily aggregates; sign-out clears it and rejects late refreshes. The
sign-out block survives process restarts until a foreground account verification. An
incomplete or locked week stays unavailable. Cached data retains its fetch time.
This is tokenstat's usage heatmap, not the device calendar: no Calendar Provider
permission or calendar account is required. Signed-out, offline and denied
usage requests leave the widget unavailable or preserve its dated cache. Missing
widget services and scheduler failures do not interrupt the app or account cleanup.

Long-press the launcher icon for Workspaces, Insights, SSH and recent project
shortcuts. Long-press a project row to pin it to the home screen. Account-scoped
AppSearch indexes only project/computer names and navigation links, with local
storage fallback when system search is unavailable. Sign-out clears the index,
dynamic/Direct Share shortcuts and pending drafts, and disables old pinned links.
Android's Sharesheet accepts text into the existing chat composer; a Direct Share
target opens its project. Incoming text remains a draft and never auto-sends.
Long-press an assistant response's copy control for Copy or Share response.
AppFunctions expose project search, dated cached usage and note creation to
authorized system callers on supported Android versions. The API is experimental;
assistant availability depends on the device. Missing search, shortcut or assistant
services do not prevent the app from opening.
The Workspaces tile can be added in Quick Settings. Both reuse existing app
navigation and sign-in. Permission notifications offer Review request, leading
to the live host request and its existing Allow/Always Allow/Deny choices.

`UsageSnapshotTest` checks account isolation, cache age, partial weeks and
rollover. `UsageWidgetLayoutTest` verifies persisted-cache isolation, shortcut
registration and pending navigation, then renders the actual RemoteViews in both
themes at compact, wide and tall sizes, including empty, offline and large-value data.
It saves PNGs in the debug app's files/widget-layouts directory. Launcher resize,
tile and notification interactions also require device/emulator verification.
`UsageWidgetFailureTest` covers absent/denied widget services, denied usage access,
signed-out review devices and cancellation without network requests.

`SystemIntegrationTest` checks real AppSearch publication/removal, account and
revocation boundaries, cold Direct Share, one-time draft consumption, invalid
shares and denied shortcut services on an isolated emulator.
