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
identically (greeting pool, token compaction, tunnel copy) is pinned by unit
tests in `PortedLogicTest.kt`.

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
| `Skeleton.Bar/Rows/CardPlaceholder` + phase-staggered pulse (0.95s autoreverse) | `components/Skeleton.kt` (infiniteTransition, StartOffset phases) | done |
| `smoothIn` content arrival (opacity + 4pt rise; fade under Reduce Motion) | `theme/smoothEnter` + `Arrive` wrapper | done |
| Reduce Motion | `rememberReduceMotion()` (animator duration scale == 0) | done |
| `Marks.swift`: LogoMark bars (rise loop 0.62s staggered 0.14s, refresh pulse), Wordmark (`token` + accent `stat`), Avatar | `marks/Marks.kt`; Wordmark splits the accent the same way; LogoMark one-shot lands over 1.2s | done |
| App icon (three bars on dark paper) | Adaptive `mipmap/ic_launcher` + `drawable/app_icon.xml` from `store/play-icon.svg`; notification glyph is the bars, not a T | done |
| `RelativeTimeText.swift` single shared 15s tick | pending (`RelativeClock` equivalent not yet needed on-screen) | gap |
| `MiniGraph`, `WorkflowStepStrip`, layering | step-capsule FlowRow reading of workflows (`workspace/WorkspaceSections.kt`) | simplified |
| `RunVisuals` outcome tints, RunHistoryStrip, DurationBar | pending (needed with workflow runs UI) | gap |
| `CadenceGlyph`, `CountdownRing`, `SlotGauge` | `marks/CadenceGlyph.kt` (ring + hand) | simplified |
| `FriendlyError.swift` translation table | `logic/TsLogic.kt` `friendlyError` (core rows only) | partial |
| `HistoryLockBanner` | `TokenstatApp.HistoryLockBanner` (same copy, opens pricing) | done |
| `ActionIcon` (~55 glyphs) | `components/ActionIcon.kt` enum, same case names, Material mapping | done |

## Client screen map (Apple `Sources/Client` → Android)

| Apple screen | Android counterpart | Motion parity |
| --- | --- | --- |
| Onboarding (10 pages) + art | `auth/Onboarding.kt` + `OnboardingArt.kt` scenes | heatmap wave, spend springs, sessions typewriter, privacy lock; Reduce Motion lands on last frame |
| Login | LogoMark rise-and-land, Wordmark, `TsAccentButton` / `TsSecondaryButton` | done |
| Root chrome (avatar leading, wordmark centre) | Themed TopAppBar / NavigationBar from `TsColors` including light; door fade 280ms | done |
| DevicesView (rows, awake dot, detail) | `TsCard` rows; online dot is accent (`success`), not green | done |
| HomeView (greeting, totals, heatmap card, limits, lock banner) | `HomeScreen` with `HomeGreeting` port, Stat tiles, Canvas heatmap, lock banner, skeleton→Arrive | done |
| PhoneHeatmap (fixed cell, scroll-to-latest-week, month marks, locked alpha, press focus) + DayDetailSheet | `heatmap/Heatmap.kt` YearHeatmap (Canvas, pointer press-focus ring, tap sheet) | done |
| InsightsView (Models/Tools/Days cuts, search) | rebuilt with SegmentedCapsulePicker, search, accent share bars animating in | done |
| Workspace sections (Sessions list, Changes w/ DiffView, Tasks composer/archive, Notes, Workflows board, Automations, Files tree) | `workspace/WorkspaceSections.kt` real renderers replacing the JSON dump | run/stop, file edit, browser |
| TerminalSession + accessory keys | `terminal/TerminalScreen.kt` + bundled xterm.js WebView, pty spawn/read/write/resize/detach, long-poll loop, accessory key row | done |
| AccountSheet (tier badge, products, sign out) | AccountDialog: TierMark, notify toggle, legal/delete URLs, PaywallSheet | done |
| Paywall (gradient tier marks, tier-switch spring) | `billing/PaywallSheet.kt` wraps Play Billing | done (no spring) |
| WebBrowser sheet (progress bar animation) | `browser/PortBrowser.kt` | progress bar |
| ConnectionChip | `chrome/ConnectionChip.kt` in the top bar | done |
