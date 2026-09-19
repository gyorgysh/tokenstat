# Android review — build 115

The follow-up review covers the Android source tree (133 Kotlin files before
these changes, about 53,000 lines), resources, bundled terminal assets, manifest,
build scripts and CI. Repository-wide scans and the full existing test suite
were combined with detailed inspection of lifecycle/polling, authentication,
billing, push, storage, attachments, WebViews, setup, transcript readers, native
packaging and screen media ownership. This is not a proof that every execution
path is bug-free or that every visual screen has been exercised.

## Changes made

- Upgrade AGP 8.13.0 to 9.0.1, Gradle to 9.1.0, and migrate to built-in Kotlin.
  Keep the Compose and serialization plugins at 2.2.20. Java remains 17.
- Enable release resource shrinking alongside the existing optimized R8 config.
  Register generated native libraries and assets through the AGP Variant API.
  Give pricing and notices separate generated directories and regenerate them
  instead of treating an output with no declared inputs as permanently current.
- Set `versionCode` to 115; keep the public version at 1.0.6.
- Pin the local launcher instead of silently accepting any installed Gradle;
  verify new distribution downloads against the published SHA-256 checksum.
  Align both CI workflows and archive R8 mappings with native debug symbols.
- Replace reflective brand drawable lookup with explicit resource references,
  preserving the same bundled artwork and unknown-brand fallback under shrinking.
- Run browser port-forward cleanup in the app view model's scope, because the
  composition scope is cancelled when leaving the browser screen.
- Cancel billing work and clear its account callback when closing the manager.
  Refuse purchases when the current-subscription query fails instead of treating
  failure as an empty purchase list; surface immediate billing-flow errors.

## Review observations

- JNI has a narrow explicit keep rule for `NativeBridge`; the default optimized
  rules retain methods annotated with `JavascriptInterface`. No broad app-wide
  keep rule or disabled optimization was found.
- Native libraries for arm64-v8a and x86_64 use 16 KB ELF LOAD alignment.
- Backup is disabled, Android 12+ extraction rules exclude app data, and identity
  storage uses `noBackupFilesDir`. Cleartext is limited to localhost for the
  port-forwarded browser. Browser TLS errors are cancelled rather than bypassed.
- The FCM service is not exported; notification pending intents are immutable.
  The push registrar holds `applicationContext`, so its static-context lint
  warnings do not show an Activity-context leak in the reviewed initialization.

## Remaining work / limits

- **Connected-device verification:** the minified release was installed and
  cold-launched on the API 36 phone emulator using local debug signing. It
  displayed the offline recovery screen, survived background/foreground, and
  emitted no fatal AndroidRuntime/libc log. Network access was disabled for the
  smoke check, restored afterwards, and the emulator was stopped. Real Play
  billing/restore, FCM delivery, SSH, remote terminal, screen/audio, file transfer
  and account-switch flows still need connected end-to-end tests. No memory
  profile, comparative startup benchmark, or Play upload was performed.
- **Feature parity:** `PARITY.md` still records deliberate product differences,
  including saved conversation-text search and some onboarding/presentation
  gaps. Stale statements about absent screen controls/audio, trials and recent
  chat/terminal recording have been corrected from source. Feature descriptions
  marked implemented are not substitutes for device acceptance tests.
- Lint and compiler warnings remain; this change does not perform an unrelated
  dependency refresh or rewrite every deprecated Compose/Billing API.

## Follow-up findings and fixes

| Area | Confirmed issue | Fix |
| --- | --- | --- |
| Authentication | Logout returned to an unchecked auth state; older refresh/dashboard work could repopulate it | Explicit checked signed-out state, cancel/join outstanding work, clear workspace state, preserve errors on failed logout |
| Sign-in | Cancellation attempted cleanup in an already cancelled coroutine; a replacement flow could race old cleanup | Non-cancellable cleanup; new flow waits for previous job |
| Account callbacks | Billing account updates could arrive off the UI dispatcher or after sign-out | Apply on the view-model scope and reject signed-out/account-switched callbacks |
| Polling | Host stats, approvals, chat, tasks and job/run polls continued in the background | Shared STARTED lifecycle effect; restart on foreground |
| Terminal / screen | Terminal read loops and screen sessions survived backgrounding | Gate terminal reads without losing offsets; close/reopen screen sessions with lifecycle |
| Relative time | Process-wide ticker woke every 15 seconds without visible subscribers | Stop ticking when lifecycle-aware subscribers disappear |
| Setup | The Mac setup watch loop only delayed; it never refreshed account state | Refresh while the setup screen is foregrounded |
| Workflow output | Live step transcripts read once and never advanced | Poll using nextOffset with a bounded text tail and lifecycle restart |
| Avatar memory / I/O | Disk decode/compression ran on caller thread; compressed size did not bound decoded pixels | Shared IO jobs, bounds-first sampled decode, bounded disk entries and atomic cache writes |
| Avatar cancellation | Cancelling a waiter could leave completed fetches retained in the pending map | Fetch-owned completion cleanup independent of callers |
| Attachments | Read entire input before enforcing the 12 MB cap; bulk selection had no staging budget | Bound reads while streaming, process picks sequentially, enforce 24 MB staging budget, tolerate provider errors, avoid attaching to a newly selected chat |
| Draft persistence | Invalid sibling queues/messages were silently discarded on the next write | Refuse damaged stores without changing bytes; unknown delivery states require review |
| Draft concurrency | Separate stores serialized independently and could overwrite each other | Shared disk dispatcher and delivery exclusion across store instances |
| Draft atomicity | Failed rename fell back to direct overwrite | Sync temporary file and require atomic replacement; preserve the previous file on failure |
| SSH migration | Cleanup could remove a failed legacy entry merely because an older encrypted value existed | Remove only successfully migrated entries |
| SSH replacement/deletion | Legacy material could resurrect a deleted key or overwrite a new replacement | Remove matching legacy entry after a successful replacement and during deletion |
| Push races | Disable/logout could race a registration; token refresh could slip between unregister and logout | Serialize operations, include logout in the registration lock, bound token retrieval |
| Push lifecycle | Service coroutine scope survived destruction; disabled notifications could still render late deliveries | Cancel service work; check local preference and system notification availability |
| Chat visibility | Foreground notification suppression did not restore after resume | Recompute visible chat with lifecycle transitions |
| WebViews | Terminal bridge remained available to navigated content; output was interpolated directly into JavaScript | Restrict terminal navigation/network/local-file access and JSON-escape output; validate initial browser URL |
| Media ownership | Codec/AudioTrack failures before assignment leaked allocated resources | Retain ownership before configure/play; release on failure; serialize AudioTrack access |
| Frame validation | Audio payload length multiplication could overflow | Long arithmetic and invalid video-dimension rejection |

The resource-shrinking, billing-query, browser cleanup and AGP fixes from the
first pass are retained above.

## Follow-up validation

Final command:

```
apps/android/gradlew -p apps/android testDebugUnitTest lintDebug lintRelease assembleRelease bundleRelease
```

- Successful build of APK and AAB with minification/resource shrinking enabled.
- **433 tests passed**, zero failures/errors/skips, including 14 new regressions.
- Debug and release lint: **zero errors, 61 warnings, 26 hints** each. The remaining
  findings are dependency updates, style/Compose API/performance suggestions,
  unused resources and the reviewed application-context static-field warnings.
- Release APK smoke check on Android API 36 arm64 emulator: package reports
  version code **115**, version **1.0.6**; cold start and background/foreground
  completed without fatal errors. The offline UI replaced the launch screen.
- R8 mapping/resource reports generated; native libraries, debug metadata,
  generated pricing/notices and terminal assets retained in the AAB.
- Shell syntax and `git diff --check` pass.

New regression tests exercise real file persistence across store instances,
refusal to discard corrupt drafts, oversized streams, image sampling, lifecycle
cancellation/restart, push registration ordering and audio length overflow.

## Upgrade references

- [AGP 9.0.1 compatibility and migration](https://developer.android.com/build/releases/agp-9-0-0-release-notes)
- [Built-in Kotlin migration](https://developer.android.com/build/migrate-to-built-in-kotlin)
- [R8 and optimized resource shrinking](https://developer.android.com/topic/performance/app-optimization/enable-app-optimization)
- [Lifecycle cancellation and restart](https://developer.android.com/reference/androidx/lifecycle/RepeatOnLifecycleKt)
- [Bounds-first sampled bitmap decoding](https://developer.android.com/develop/ui/compose/graphics/images/optimization)

## Distribution preparation

The final pre-commit review also handles failed initial workflow transcript reads
without leaving a permanent loading label, and rechecks the attachment staging
budget after suspended reads so overlapping picker results cannot exceed it.
The release script now emits both upload-key-signed APK and AAB files and refuses
missing signing credentials. Distribution still requires the connected-service
acceptance checks above; artifact creation does not publish to Google Play.

## Build 116 follow-up

Build 116 retains version name 1.0.6 and explicitly enables `-repackageclasses ''`
on AGP 9.0.1 to shorten package names for classes eligible for obfuscation. The
existing `NativeBridge` keep rule preserves the fully qualified class name and
methods used by Rust JNI exports. The build 115 review and validation below
remain the baseline; this follow-up changes only the version code and R8 rule.
