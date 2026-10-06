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

Usage at a Glance supports small, medium and large sizes on Mac, iPhone and iPad, extra-large on iPad, and circular, rectangular and inline iOS Lock Screen accessories. Configure Today or Last 7 Days and Automatic, Light or Dark appearance. Full-color widgets use the selected appearance; system-tinted and accessory widgets respect system rendering. Refresh buttons invoke the containing app to fetch usage, with update failures preserving the last successful figures.

Open tokenstat provides a configurable screen or favorite project in small, and screen/project links in medium and large. The selected screen is included in larger layouts. Quick Access controls support Control Center on iOS 18 and macOS 26, plus supported iOS Lock Screen slots and the Action button.

Snapshots contain aggregate activity and project names/device labels, never credentials, paths, messages or drafts. They update after successful app loads. Extensions do not establish host connections. Partial or locked weeks display unavailable totals instead of a misleading sum. Midnight timeline entries prevent yesterday's value from becoming today's value. Account leases reject late asynchronous publications, and sign-out clears shared data.

## Apple Watch

The paired Watch app receives snapshots through WatchConnectivity, shows daily/weekly activity and projects, and can request a refresh from a reachable iPhone. Project details publish Handoff navigation to the iPhone app. Watch Shortcuts open usage/projects/requests, read today's last synced usage, or open a project. Circular, rectangular, inline and corner complications use the same activity snapshot. Packet revisions reject duplicate and out-of-order deliveries, including replies that arrive after an account reset. Offline refresh explains how to reconnect and preserves cached data.

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

The fixture can seed typical, empty, offline and large-value/long-name snapshots and an inert approval request, refresh data and execute navigation/search/usage intents. Launch with `--render-widget-gallery` to export native SwiftUI layout PNGs into its Documents/widget-layouts directory for all card sizes and both appearances. These are layout checks; system widget rendering and interactions still need simulator/device checks. The fixture is excluded from shipping targets. Test system widget configuration, sizes, appearance, tint, links, controls and Watch sync on signed simulator installations. Spoken Siri, Apple Intelligence behavior, Lock Screen privacy and physical-device Handoff also require device/TestFlight verification.
