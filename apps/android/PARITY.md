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
