# Mobile release parity

This is the release gate for customer-visible mobile behavior. A shared feature
does not leave a release branch until its Apple and Android implementations and
contract tests are green. Platform presentation may differ; behavior may not.

## Design-once rule

The design system is defined once, in `apps/mac/Sources/Design/` (tokens,
components, motion). Android ports those definitions 1:1 into
`app/src/main/java/ai/tokenstat/tokenstat/ui/theme/`, `ui/components/`, and
`ui/marks/`; it never invents its own colours, spacing, radii, or timing.
Validation is the mapping table below: every Apple source has a named Android
counterpart or an explicit gap. Pure logic that both platforms must answer
identically (greeting pool, token compaction, tunnel copy, recents ranking,
recent places, pin shelf, home arrangement, device sentences, limit ordering
and severity, stats readings) is pinned by unit tests in `PortedLogicTest.kt`.

| Capability | Rust contract | Apple | Android |
| --- | --- | --- | --- |
| Sign-in, sign-out, account status | built | built | built |
| Account activity, limits, insights | built | built | built |
| Device and remote workspace directory | built | built | built |
| Sessions, changes, tasks, notes | built | built | built (real renderers; diff/tasks/notes/actions wired) |
| Workflows, automations, files | built | built | built (run/stop, enable, tree drill, file edit) |
| Interactive terminal emulator | built | built | built (xterm.js WebView over pty.*; accessory key row) |
| Port-forwarded browser | built | built | built (`proxy.listen` + WebView) |
| Store subscription activation | Apple + Google built | built | built; custom pitch wraps Play Billing |
| Push registration and delivery | built | built | built; FCM configuration required |
| SSH connect + key import | built | built | built (password/key, generate/import) |
| Screen viewer (Legend) | built | built | built (JPEG blit; H.264 status) |

## Component map (Apple → Android)

| Apple (`Sources/Design`) | Android (`ui/theme`, `ui/components`) | Status |
| --- | --- | --- |
| `Theme.swift` tokens (accent/secondary pairs, background/panel/sidebar/tabStrip/border/row colours, semantic set, heat ramp, syntax palette) | `theme/TsColors.kt` (light+dark transcribed hex-for-hex) | done |
| Spacing scale, cardRadius 14, cardPadding 16 | `theme/TsMotion.kt` (`Space`), `components/TsComponents.kt` (`cardRadiusDp`, `cardPaddingDp`) | done |
| Tabular figures / mono / sectionHeader fonts | `TsType.numeric/.mono/.sectionHeader/.cardTitle` | done |
| `Card` | `TsCard` (panel fill + hairline border) | done |
| `Stat`, `SectionLabel`, `ScopeChip`, `TierBadge` | same names | done |
| `Banner` (+severity tints/symbols) | `Banner`, `BannerSeverity` | done |
| `EmptyState` | `EmptyState` | done |
| `AccentButtonStyle` / `SecondaryButtonStyle` | `TsAccentButton` / `TsSecondaryButton` (pressed fills/strokes ported) | done |
| `SegmentedCapsulePicker` | `SegmentedCapsulePicker` | done |
| `TransientToast` | `TransientToast` (slide-from-trailing + fade, snappy 250ms) | done |
| `Skeleton.Bar/Rows/CardPlaceholder` + phase-staggered pulse (0.95s autoreverse) | `components/Skeleton.kt` (infiniteTransition, StartOffset phases; static full-strength bar under Reduce Motion) | done |
| `smoothIn` content arrival (opacity + 4pt rise; fade under Reduce Motion) | `theme/smoothEnter` + `Arrive` wrapper | done |
| Reduce Motion | `rememberReduceMotion()` (animator duration scale == 0) | done |
| `Marks.swift`: LogoMark bars (rise loop 0.62s staggered 0.14s, one-shot 1.2s staggered 0.15s, refresh pulse 0.26s staggered 0.07s with 0.35 dip), Wordmark (`token` + accent `stat`), Avatar, TierMark | `marks/Marks.kt` (loop/one-shot/pulse timings verified; loops land static under Reduce Motion; listener unsubscribes), Wordmark splits the accent the same way; Avatar uses djb2 over the heat-minus-greys plus warning/danger ramp with the vertical tint gradient; `marks/TierMark.kt` transcribes the exact 24-unit crown/star/shield paths with the 8B5CF6 to C026D3 gradient, free renders nothing, unknown renders the seal | done (source verified; on-device rendering is an open device check) |
| App icon (three bars on dark paper) | Adaptive `mipmap/ic_launcher` + `drawable/app_icon.xml` from `store/play-icon.svg`; notification glyph is the bars, not a T; launch `windowBackground` is Theme paper in light and night; splash is paper with the looping LogoMark rise plus Wordmark, no skeleton or spinner on the first frame | done in source (install icon, splash frame, and notification rendering need a physical device) |
| `RelativeTimeText.swift` single shared 15s tick | `components/RelativeTime.kt` `RelativeTick` + `RelativeTimeText` over `RelativeClock.label`; chat event times tick | done |
| `MiniGraph`, `WorkflowStepStrip`, layering | step-capsule FlowRow reading of workflows (`workspace/WorkspaceSections.kt`) | simplified |
| `RunVisuals` outcome tints, RunHistoryStrip, DurationBar | `marks/RunVisuals.kt`: `RunOutcome`, `RunHistoryStrip` (8 slots), `DurationBar` | done |
| `CadenceGlyph`, `CountdownRing`, `NextRunBadge`, `SlotGauge` | `marks/CadenceGlyph.kt` (seven-dot week ring from the host `schedule` struct with Monday on top, idle tint when paused, play/refresh symbols for once/interval; pinned by `scheduleRingFiresLikeApple`) + `marks/RunGauges.kt` (fraction math, 12-tile bound, No cap words) | done (source verified; automation rows previously read a `cadence` key the host never sends, so no glyph ever rendered) |
| `FriendlyError.swift` translation table | `logic/TsLogic.kt` `friendlyError` (full table, same order and copy) | done |
| `HistoryLockBanner` | `TokenstatApp.HistoryLockBanner` (same copy, opens pricing) | done |
| `ActionIcon` (77 glyphs) | `components/ActionIcon.kt` enum, same case names, Material mapping | done |
| `TimeLimitChips`, `ConcurrentChips`, `ChoiceChip`, `BrandToggleChip`, `CommitTagPills` | `components/TsChips.kt` (same presets, No limit / No cap sentinels, custom number selects none) | done |
| `PickerSearchField` | `components/TsSearchField.kt` (magnifier + prompt + clear button, no capitalise or autocorrect) | done |
| `FieldSaveState`, `FieldSaveBar` | `components/FieldSaveBar.kt` (same five states, same copy, actions only when dirty or failed) | done |
| `BrandCheckboxStyle`, `ThemeCheckDisc`, `BrandToggleChip` | `components/BrandToggles.kt` (`BrandCheckbox`, `BrandCheckDisc`, `TsBrandSwitch`); the one raw `Switch` now reads `TsBrandSwitch` | done |

## Client screen map (Apple `Sources/Client` → Android)

| Apple screen | Android counterpart | Motion parity |
| --- | --- | --- |
| Onboarding (10 pages) + art | `auth/Onboarding.kt` + `OnboardingArt.kt` scenes | heatmap wave 2.8s landing on 0.35, spend spring 0.7/0.78 staggered 0.1s, remaining sweep gradient with easeOut 0.9s, sessions typewriter 280ms with easeOut 0.2s reveal, device tiles spring 0.55/0.78, privacy lock spring 0.55/0.7 closing after 280ms, control rows spring 0.5/0.84 staggered 0.08s; every scene lands on its last frame under Reduce Motion. Gaps: no Agents scene (Apple has one; Android flow has no agents page), Intro keeps the mark-plus-wordmark lockup rather than Apple's tiles, Devices labels read Mac/Tablet/Phone, progress is a single fill bar rather than per-page capsules | done with noted gaps |
| Login | LogoMark rise-and-land, Wordmark, `TsAccentButton` / `TsSecondaryButton` | done |
| Root chrome (avatar leading, wordmark centre) | Themed TopAppBar / NavigationBar from `TsColors` including light; door fade 280ms | done |
| DevicesView (rows, awake dot, detail) | `TsCard` rows; online dot is accent (`success`), not green; `DeviceCopy` names and status lines; rename over `account.renameMachine`; reach copy with the Always-on sentence; stats bar with failure state and direct/relay route mark | done |
| HomeView (greeting, totals, heatmap card, limits, lock banner) | `HomeScreen` draws the arranged sections in phone balanced order (usage, continue, machines, pinned, activity, limits) with the Apple copy; continue/pinned shelves over `HomeStores` with pin toggles; awake-hosts machines section; `Customize Home` editor with presets, reorder, hide, reset; offline/empty/error status with getting-started card; limits sorted closest-to-full-first with severity gauges and observed dates | done |
| `ClientRecentChatsRanking` (3 newest + 5 by priority) | `logic/HomeLogic.kt` `RecentChatsRanking`, pinned by tests; no per-host Recents row in Workspaces yet (needs host-level chat aggregation plus read receipts) | logic done, UI gap |
| `ClientRecentPlaces` (continue shelf, 20, account scope) | `logic/HomeLogic.kt` `RecentPlaces` + `home/HomeStores.kt` (SharedPreferences); scope is handle-only, the account payload carries no host name; records folder opens, chat/terminal opens not yet recorded | done with noted gaps |
| `PinnedWork` (pin shelf, 8, refused with words) | `logic/HomeLogic.kt` `PinnedWork` + `HomeStores.togglePin`; shelf-full refusal reads "The shelf holds eight pins" | done |
| `HomeLayout`/`HomePreset`/`ClientHomeEditor` | `logic/HomeLogic.kt` (`HomeSection`, `HomePreset`, `normalizeHomeLayout`) + `home/HomeSections.kt` `HomeEditor`; presets Balanced/Work first/Usage first, up/down moves, reset with undo | done |
| `ClientGettingStarted` (phone first run) | `home/HomeSections.kt` `GettingStartedCard`; "Set up a machine" lands on Devices (no setup wizard on Android); no ghost grid | done with noted gaps |
| `ClientLimitsCard` (sort, severity, observed) | `LimitCard` sorts closest-to-full-first, gauges read the host severity over the `limits.rs` 90/70 scale, observed dates with stale prefix; resets line not rendered (`RelativeClock` is past-oriented) | done with noted gap |
| `DeviceCopy` (names, status, reach) | `logic/HomeLogic.kt` `DeviceCopy` ported word-for-word, pinned by tests | done |
| `HostStatsFormat` (power/CPU/RAM words) | `logic/HomeLogic.kt` `HostStatsFormat`; bar shows failure `n/a`, direct/relay route from `remote.status`, same tunnel footnote | done (no CPU/RAM meter bars) |
| Saved-work library (`ClientSavedWorkView`) | no Android work-cache bridge (`cache.list` and friends do not exist), so no screen and no data | gap |
| Launch tiles (`ClientLaunchTile`) | tiles live in the workspace launcher, not Home; Android `WorkspaceDetail` has no launcher row yet | gap |
| App places (`ClientAppPlaces`) | no work search on Android, so no searchable places catalogue | gap |
| Host-sent scope notice (`NoticeCard`) | `account.status` carries no scope notice on Android, so nothing to render | gap |
| PhoneHeatmap (fixed cell, scroll-to-latest-week, month marks, locked alpha, press focus) + DayDetailSheet | `heatmap/Heatmap.kt` YearHeatmap (Canvas, pointer press-focus ring, tap sheet) | done |
| InsightsView (Models/Tools/Days cuts, search) | rebuilt with SegmentedCapsulePicker, search, accent share bars animating in | done |
| Workspace sections (Sessions list, Changes w/ DiffView, Tasks composer/archive, Notes, Workflows board, Automations, Files tree) | `workspace/WorkspaceSections.kt` + `WorkspaceFiles.kt` (per-type icons, breadcrumb drill, single-file editor with return context) + `WorkspaceNotes.kt` (quick capture, search, newest/A-Z sort, archive toggle, optimistic rows, edit sheet, delete confirm, make-a-task); pure rules in `ui/logic/WorkspaceLogic.kt` pinned by `WorkspaceLogicTest` | run/stop, file edit, browser |
| TerminalSession + accessory keys | `terminal/TerminalScreen.kt` + bundled xterm.js WebView, pty spawn/read/write/resize/detach, long-poll loop, accessory key row | done |
| AccountSheet (tier badge, products, sign out) | AccountDialog: TierMark, notify toggle ("or a chat" copy), Sync privacy card, legal URLs, "Delete on website…" with the permanence copy, PaywallSheet | done |
| Paywall (gradient tier marks, tier-switch spring) | `billing/PaywallSheet.kt` wraps Play Billing; feats and summaries match `ClientStore` word-for-word with relay allowances as Apple captions; "Your current plan" marker; Play renew note (Google Play wording where Apple says App Store) | done (no spring; no trial, Play trial state is not exposed) |
| WebBrowser sheet (progress bar animation) | `browser/PortBrowser.kt` | progress bar |
| ConnectionChip | `chrome/ConnectionChip.kt` in the top bar | done |
