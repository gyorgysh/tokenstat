# tokenstat Apple apps

The SwiftUI app shares its sources between macOS, iOS and iPadOS. Minimum versions are macOS 14, iOS 17 and watchOS 10. XcodeGen generates the projects from `project.yml`; generated projects are not committed.

## Local builds

Install Xcode and XcodeGen, then build the Rust FFI framework and generate the project:

```sh
scripts/build-ffi-xcframework.sh
xcodegen generate --spec apps/mac/project.yml
```

Open `apps/mac/Tokenstat.xcodeproj` and select the Tokenstat scheme and a Mac, iPhone or iPad destination. The iPhone app embeds the paired TokenstatWatch app and its complication extension. Regenerate after changing sources or the project specification. Use a destination instead of a global `-sdk` override when building the iPhone scheme, so embedded Watch targets retain their watchOS SDK.

## Shortcuts, Siri and discovery

Shortcuts expose Open Screen, Open Project, Usage, Refresh, Search and Activity Streak. Screens include Home, Workspaces, Insights, Devices, SSH, Account and Search. Project actions can open Terminals, Chats, Changes, History, Pull Requests, Tasks, Notes, Workflows, Automations, Files or Browser. Search accepts a query and opens the existing app search interface.

Usage attempts a fresh load and returns US dollars at list rates, the selected scope and the last successful update time. Cached values remain available offline. Projects are scoped to the current account, indexed for Spotlight on supported systems, and removed from discovery after sign-out or revocation. The Xcode 27 SDK adds Apple's system content-opening and search schemas while retaining regular App Intents on older systems. Navigation actions open existing app flows; they do not execute terminal commands or agents.

## Widgets and controls

Plan Limits has a dynamic provider picker: choose one or several available readings, or leave it empty for all available providers. Circle and bar layouts show used allowance rather than remaining allowance. Choose Highest usage, 5-hour, Weekly, both or All windows. Both displays a separate reading for each available period, with four circles fitting in a small widget. Missing periods stay unknown, and general/primary quotas take precedence over model-specific windows. Providers are discovered from the account's shared readings, including new providers without changing the widget. A computer must enable **Share with my devices** in Plan limits for its observations to reach the phone. Background provider fetches follow the account plan's sync interval, with a five-minute floor and hourly fallback; the Mac widget publisher checks the local cache once a minute and reloads only when readings change. Readings retain their observation and reset times; an expired window becomes unknown until refreshed, never a synthetic zero. Saved selections are scoped to the account. Small widgets show up to four circles or three summaries, medium up to four circles or three providers, and large up to nine circles or three detailed bars. Additional hidden readings are counted in the header. The age appears once in a compact footer; it does not tick every second. Refresh shows native waiting feedback, a brief success check or a retry indicator.


Usage at a Glance supports small, medium and large sizes on Mac, iPhone and iPad, extra-large on iPad, and circular, rectangular and inline iOS Lock Screen accessories. Configure Today or Last 7 Days, toggle **Show charts** to keep just the totals, and choose Automatic, Light, Dark, Clean (glass) or Black appearance. Accent tints include tokenstat, Teal, Orange, Pink and Monochrome. Black uses a pure black background and light text; Clean follows the system's light/dark scheme with a translucent material. The settings are named **Full-color style** and **Full-color accent**: they apply when the Home Screen uses normal full-color widgets. In Clear or Tinted Home Screen modes, Apple removes widget backgrounds and chooses glass/tint colors, so selecting Light, Dark or Black cannot override that system mode. Full-color widgets use the selected appearance and tint; system-tinted, clear and accessory widgets respect system rendering. Backgrounds remain removable so the system can supply its own glass. Refresh buttons invoke the containing app to fetch usage, with update failures preserving the last successful figures.

Open tokenstat provides a configurable screen or favorite project in small, and screen/project links in medium and large. Circular and rectangular Lock Screen launchers open that same configured destination. The selected screen is included in larger layouts. Widgets, complications and Quick Access controls share the tokenstat three-bar symbol, using the same geometry as the app logo. Quick Access controls support Control Center on iOS 18 and macOS 26, plus supported iOS Lock Screen slots and the Action button. App Shortcut tiles require SF Symbols and use action-specific icons.

On iPhone, an active conversation observed in the foreground starts a Live Activity
on compatible hosts (protocol 31+). Lock Screen and Dynamic Island layouts show
the tokenstat mark, elapsed time and working/waiting/completed state. Tapping opens
the exact conversation. Completion stays briefly; sign-out and computer revocation
remove the activity. Disabled Live Activities or system limits leave chat usable.
Status transitions respect Reduce Motion and the always-on display. Background
updates use the host's bounded status queue and the website's activity-specific
APNs transport; they require the matching host/client/backend deployment and APNs
configuration. Push content carries only opaque conversation keys, revisions,
fixed phases and timestamps, never project names or transcript text. Project names
are stored in the phone's local activity attributes. Disconnected activities become
stale rather than claiming that a run is still working.

Further Apple integrations include onscreen project context for Siri (entity
annotations/action donations) and task/note entities with focused Shortcuts actions.
See Apple's [contextual cues guidance](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri).

Snapshots contain aggregate activity, dated provider/window percentages, and project names/device labels, never credentials, paths, messages or drafts. They update after successful app loads. Extensions do not establish host connections. Partial or locked weeks display unavailable totals instead of a misleading sum. Midnight timeline entries prevent yesterday's value from becoming today's value. Account leases reject late asynchronous publications, and sign-out clears shared data.

## Apple Watch

The paired Watch app focuses on Activity (Today/Week), Plan limits and actionable Requests, using tokenstat colors and the three-bar logo. It receives dated snapshots through WatchConnectivity and can refresh from a reachable iPhone using the white sync arrow. First-run and reconnect instructions ask you to open tokenstat on the paired iPhone, sign in and keep it nearby. Allowance cards show the observed percentage, reset time and cache age; expired windows require a refresh. Watch Shortcuts open these three screens or read today's last synced usage. Existing saved project Shortcuts explain that projects open on the iPhone. Circular, rectangular, inline and corner activity complications remain available; Plan Limits adds circular, rectangular and inline complications for the highest active percentage, and Requests adds a circular count from the last sync. Tapping a limits/request complication opens that screen. Packet revisions reject duplicate and out-of-order deliveries, including replies after an account reset. Offline refresh explains how to reconnect and preserves dated data. Large packets keep requests ahead of provider details and explain omitted providers. The Watch uses the light/dark/tinted Icon Composer asset and a validated opaque fallback PNG.

Requests on Watch query existing approved hosts on the signed-in account. Each detail shows the host, action, full bounded preview and expiry. Allow Once and Deny answer that request; Always Allow confirms the tool or safe command prefix remembered for that chat only. Long requests require iPhone review before allowing. The iPhone revalidates the exact live request, expiry, account and trusted host before sending any choice; it never automatically pairs a host or grants workspace access. Watch packets include up to twelve expiring previews, stored with file protection and excluded from backup. Widgets and complications display no request previews.

Watch requests can wake the companion iPhone app in the background when WatchConnectivity is reachable. The host must be running and accessible; unavailable replies never claim an approval succeeded. Agent notifications use the existing review route: tap to open the host's current pending request and choose Allow, Always Allow or Deny there. Push payloads carry only a fixed reason and machine identifier. Don't ask mode does not generate agent permission requests.

## Signing

Register `group.ai.tokenstat.tokenstat` and assign it to all four bundle IDs:

- `ai.tokenstat.tokenstat`
- `ai.tokenstat.tokenstat.widgets`
- `ai.tokenstat.tokenstat.watchkitapp`
- `ai.tokenstat.tokenstat.watchkitapp.widgets`

Regenerate provisioning profiles after changing assignments. The existing iOS archive script uses automatic signing and validates the app, widgets, Watch app and complications before upload. Simulator targets use ad hoc signing so App Intents execute without a developer team.

For Developer ID Mac builds, set `TOKENSTAT_MAC_PROFILE` and `TOKENSTAT_MAC_WIDGET_PROFILE` to authorized app/extension profiles. Release CI uses `DEVELOPER_ID_PROFILE_BASE64` and `DEVELOPER_ID_WIDGET_PROFILE_BASE64`. `scripts/sign-mac-app.py` validates App Group authorization and signs the extension before the app. Properly signed installations are required for shared-container behavior.

## Verification

Run `scripts/run-swift-tests.sh` and `python3 scripts/tests/AppleWidgetSigningTests.py`. The ecosystem tests cover URL validation, midnight/timezone rollover, unavailable/locked data, snapshot persistence, source replacement and out-of-order Watch packets.

For isolated simulator UI checks without account/network data:

```sh
xcodegen generate --spec apps/mac/WidgetQA.yml
xcodebuild -project apps/mac/WidgetQA.xcodeproj -scheme Tokenstat \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath target/WidgetQA ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

The fixture can seed typical, empty, offline and large-value/long-name snapshots and an inert approval request, refresh data and execute navigation/search/usage intents. Launch with `--render-widget-gallery` to export native SwiftUI layout PNGs into its Documents/widget-layouts directory for all card sizes, glass/black styles, accent tints and Lock Screen launcher layouts. The accented-mode fixture exercises adaptive layout but ImageRenderer does not apply the system compositor's tint/glass effects. These are layout checks; system widget rendering and interactions still need simulator/device checks. The fixture is excluded from shipping targets. Test system widget configuration, sizes, appearance, tint, links, controls and Watch sync on signed simulator installations. Spoken Siri, Apple Intelligence behavior, Lock Screen privacy and physical-device Handoff also require device/TestFlight verification.

## Device acceptance and release uploads

Use the following checks on the new TestFlight build with a signed-in account and a running, trusted computer:

1. **Live Activities:** enable Tokenstat's Live Activities in iPhone Settings. Start a longer conversation and open that exact running chat on the phone, then lock the phone or return Home. Check the Lock Screen and Dynamic Island while working, waiting for approval, done, failed, stopped and disconnected. Tap the activity to return to the exact chat. Test a run finishing while the phone is locked to verify the deployed APNs path. Activities start from a run observed by the foreground app; backend deployment alone does not remotely start an activity. The matching host must support the live-work protocol (31 or later). Disabled activities must leave chat usable.
2. **Shortcuts and Siri:** open Shortcuts, add an action from Tokenstat, and run Open Screen, Open Project, Get Usage, Refresh, Search and Get Streak. Use a visited project so it appears in the account-scoped picker. Then try “Show my usage in tokenstat,” “Open tokenstat Workspaces,” and “What is my streak in tokenstat.” Usage announces its date/scope; it does not expose chat contents or execute agent commands. Confirm old project selections stop resolving after account changes. Apple Intelligence contextual actions depend on device/language support and require physical-device verification.
3. **Widgets and Watch:** select one provider, several, and all; compare Circles/Bars, 5-hour/Weekly/Both windows, chart-free totals, all supported sizes, Light/Dark/Glass/Black and system Clear/Tinted. Check expired/offline readings and sign-out. On Watch, switch Today/Week, refresh limits, and review an approval including expiry and Always Allow confirmation. Check the icon, complications, account changes, unreachable phone, large text and Reduce Motion.
4. **iPhone Duo:** compile with Xcode 27.1 RC or newer and test the app's existing responsive layouts in Duo's poses and orientations. SDK support does not replace device/Device Hub layout checks.

Apple accepts Xcode 27.1 RC / iOS 27.1 builds for App Store Connect and internal/external TestFlight, as listed in the [October 5 release notes](https://developer.apple.com/help/app-store-connect/release-notes/). Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/upload-ios-appstore.sh` with the local 27.1 installation. This archives, signs, exports, validates and uploads; it does not submit for App Review or change listing metadata. Commit a new build number before uploading. Device Siri, Apple Intelligence, physical APNs delivery and system glass composition are separate acceptance checks; native fixture renders cannot prove them.
