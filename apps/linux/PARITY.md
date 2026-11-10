<!-- SPDX-License-Identifier: LicenseRef-tokenstat-source-available -->

# Linux and SwiftUI desktop parity

The Linux desktop must look and behave identically to the SwiftUI desktop.
The SwiftUI implementation is the specification. GPUI is the Linux renderer,
not a reason to change the interface. This covers every application screen,
menu, context menu, toolbar, popover, sheet, dialog and interaction state.

The `--probe-ui` experiment only verifies rendering and host transport. Its
three-view navigation and styling are not an accepted Linux design. Do not
expand that design or count it as completed product UI.

## Reference sources

| Contract | SwiftUI source |
| --- | --- |
| Window composition, sidebars, inspector, overlays, menus and retained state | `apps/mac/Sources/App/RootView.swift` |
| Rail, panel geometry, title band and resizing | `apps/mac/Sources/App/ShellChrome.swift` |
| Global, workspace and SSH routes | `apps/mac/Sources/App/Route.swift` |
| Application menus, shortcuts, About and windows | `apps/mac/Sources/App/TokenstatApp.swift` |
| Colours, typography, spacing, radii and control metrics | `apps/mac/Sources/Design/Theme.swift` |
| Font families, weights and loading | `apps/mac/Sources/Design/AppFonts.swift` |
| Action glyph vocabulary | `apps/mac/Sources/Design/ActionIcon.swift` |
| Native/context menu behavior | `apps/mac/Sources/Design/NativeMenuTrigger.swift`, `apps/mac/Sources/App/SidebarRowActions.swift` |
| Text, tooltips, accessibility labels and placeholders | `apps/localization/en/common.json`, `apps/localization/en/apple.json` |
| Desktop action parsing and activation | `apps/mac/Sources/App/DesktopOpenRequest.swift`, `scripts/tests/desktop-actions.json` |
| Each feature's complete behavior | Its views and state models under `apps/mac/Sources/Features/` |

Read the current source when porting. A copied value is not permission to drift
after the SwiftUI implementation changes.

## Shell and navigation

Port the actual shell before porting feature contents:

- Rail order: Home, Projects, Tasks, Notes, Automations, Insights, Devices,
  SSH, Teams. Account stays at the foot.
- Preserve the 64-point rail, 272-point default sidebar and 400-point default
  inspector. Their ranges, title band, floating-panel geometry and fit logic
  come from `ShellMetrics` and the layout helpers, not new GPUI defaults.
- Preserve project grouping, machine grouping, expanded/collapsed states,
  recent conversations, new chat, search, badges, account menu and tooltips.
- Preserve retained panes, scroll positions, drafts, independent widths,
  floating inspectors, hover peeks, pinned overlays and full-screen behavior.
- Global screens include Home, Teams, New chat, Insights, Devices, Tasks,
  Notes, Workflows, Automations and Account. Workflows shares the Automations
  rail destination exactly as in SwiftUI.
- Workspace destinations include terminals, chat, changes, history, pull
  requests, tasks, notes, workflows, automations, files and browser. Match
  their actual placement and reachability, including inspector-only views.
- SSH includes hosts and folders, keys, snippets, known hosts and live
  sessions. Session state survives navigation exactly as in SwiftUI.

## Menus and commands

Build a source-linked inventory before declaring menu parity. Include dynamic
items, separators, submenus, destructive styling, shortcuts, visibility and
enablement conditions. A visible but unwired menu item is incomplete.

The inventory includes:

- Application, File, Edit, View, Window and Help commands, About, Add project,
  Search work, sidebar/inspector toggles, previous/next conversation, chat
  detail modes and step-group visibility.
- Signed-in and signed-out account menus, sync cooldown/checking states,
  update actions, Teams and Account settings.
- Project, conversation, terminal, tab and file context menus, including
  pin/archive/share/rename/fork/remove/close actions and their confirmations.
- Composer add/setup/model/permission menus, slash commands, approvals,
  attachments and chat workbench tool selectors.
- Every menu in devices, SSH, tasks, notes, workflows, automations, boards,
  reports, editor, browser and remaining feature views.

Keep command identity separate from its keyboard binding. Preserve all actions
when mapping the platform modifier. Do not silently drop a command because
GPUI or a Linux desktop does not expose the same menu surface.

## Visual contract

Use the same bundled Manrope and JetBrains Mono families with the same weights
and logical sizes. Match both light and dark themes, accent, semantic colours,
transparency settings, borders, shadows, radii, padding, hit areas, animation
timing and reduced-motion behavior. Match glyph meaning, shape, size and
alignment with assets that may be shipped on Linux.

Measure the current SwiftUI application at fixed logical window sizes and
scales. Capture the Linux view using identical fixture data and UI state.
Compare full screens and expanded menus, not only the initial Home screen.
Overlay and difference images expose spacing, alignment, text and geometry
differences. Inspect animation and interaction separately from still images.

Platform constraints that prevent a faithful match must be recorded and
resolved before signoff. They do not authorize a redesign or an unreviewed
exception. This includes window decoration, native dialogs, material effects,
font shaping, icons, menus, browser surfaces and terminal rendering.

## Behavior and state coverage

For every surface, cover loaded, loading, empty, offline, stale, permission
required, partial failure, destructive confirmation and recovery states where
they exist in SwiftUI. Include selection, hover, focus, keyboard navigation,
menus opening/closing, scrolling and resizing. Preserve draft and tab state,
unsaved edits, cancellation, reconnect and host compatibility gating.

Use the shared host methods and existing protocol fixtures. UI parity must not
fork backend behavior or duplicate business logic. Any missing Linux host
capability remains an explicit parity gap.

## Host startup and descriptor limits

The desktop shares concurrent host-start requests for the same socket, including
failures, and rechecks the socket before launching. Later calls can retry; a
different socket does not wait. The host's existing identity ownership remains
the cross-process guard. Calls to the user service manager are bounded, and a
timeout does not trigger a direct-host fallback; managed starts queue a job
before socket readiness is checked. The staged user service leaves file limits to its user
manager instead of requiring a fixed hard limit. The shared host raises its
soft limit within that inherited ceiling without lowering a higher soft limit.
Isolated child-process tests exercise low ceilings and the host's target limit.
Service startup, multiple desktop processes, shell compatibility, resource
diagnostics, power/session behavior and restart recovery still need real Linux
validation; these checks do not establish distro acceptance.

## Completion gates

1. Inventory every reachable desktop surface and menu, with SwiftUI source
   references, matching state fixtures and a Linux implementation owner/file.
2. Port shared design primitives and the complete shell/navigation structure.
3. Port menus and feature screens in their current SwiftUI arrangement.
4. Verify each surface visually and interactively using the same state/data.
5. Validate all Linux system integrations and the distro/hardware matrix.
6. Resolve every parity gap before calling the Linux desktop complete.

The Linux-machine handoff may contain an unfinished port, but it must identify
every unfinished area. A working graphics probe, successful compilation or
passing protocol tests cannot mark GUI parity complete.

[SURFACES.md](SURFACES.md) is the working source-linked ledger. Its root route,
inspector and presenter coverage is explicit; nested feature menus still need
individual expansion and review. No row has visual signoff yet.

## Initial Home arrangement and plan panels

The confirmed-empty Activity branch now contains an initial source-shaped
Getting Started card rather than a preview message. Its three-step text,
account/scan/cooldown branches and action closures match the original card in
eight compiled SwiftUI state comparisons. Scan goes through the existing host
with the source's 600-second timeout, per-window duplicate guard and ten-second
success cooldown; successful scans invalidate Home day data and refresh the
calendar. The per-window scan stays active through a guarded Insights snapshot
refresh; its cooldown and action timers start when the scan succeeds, and Home
is notified after that refresh returns, including on a refresh error. Synthetic
socket tests cover protocol and report decoding, and suspended comparisons run
the original scan body with controlled Bridge, refresh and timer stubs. The
Account/sign-in flow and complete Insights screen/model are not yet ported.
Actual GPUI task/notification interleavings, full archive notification behavior,
native buttons/focus/accessibility, animated halo and ghost grid, reduced motion
and visual/Linux acceptance remain open. Fixtures do not prove pixel parity.

For the default All devices Insights scope, `insights/account.rs` now retains
per-cut reports and requests with the original account-scope privacy guards,
refresh invalidation and cancellation behavior. Eleven held-reply checkpoints
compare the complete original `ClientInsightsModel` against the Rust owner,
with synthetic identity and Bridge stubs. The existing `account.report` RPC is
covered by a temporary fake socket. An initial All devices route now mounts
the owner with cut selection, search field, refresh, report rows, a basic chart
and the All devices inspector. Twenty-seven day-position cases compare with
the original `InsightDayAxis`. This is not visual or behavioral signoff:
localized-standard search, full date/relative-age localization, chart axes,
gradients, native control/focus/IME/AX, real GPUI task interleavings, precise
layout and account transitions remain open.

An initial This device Insights route now mounts the shared-host snapshot,
period and tab controls, day focus, scan, explicit remote fetch, ranked rows,
pagination and a basic inspector. Fetch uses the existing host RPC and keeps
its separate busy and 30-minute cooldown states through the post-fetch refresh;
scan and fetch share the transient action message. The original fetch method
is compared against held synthetic replies in four lifecycle scenarios, and a
temporary fake socket checks the request and required report fields. These
tests do not validate real vendor access or GPUI task interleavings.
Superseded snapshot reads are fenced before and after host setup.
Seventy-two synthetic calendar queries across four time zones compare with the
original Swift query; the broader Foundation calendar and locale space is not
covered. This is not a parity signoff: the chart and inspector are preliminary,
route-task cancellation and overlapping UI work need further comparison, and
the original chart, toast layout, controls, localization,
accessibility, rendering and real Linux input have not been validated.

The GPUI Home stack follows the original desktop arrangement, including
Balanced hiding Usage. The draft editor includes presets, visibility, visible
row reordering, preview, reset/undo, Cancel/Done and the all-hidden Home state.
Linux connected previews save a GUI-only device preference atomically on a
worker; synthetic fixtures and macOS previews stay ephemeral. Tests preserve
unknown preference fields and reject damaged files without replacing them.

Usage figures use the delivered calendar, rather than another archive query.
Vendor quota cache/live requests and archive plan usage use the existing host
methods independently, with stale/error retention and generation fences.
Source comparisons cover layout normalization/movement, quota display labels,
percentages, semantic colours, visible provider order, panel columns, optional
cache fields and figure boundaries. The vendor store now owns the shared
flight, attempt throttle and settings revisions separately from Home's
independent waiters/archive usage. Twenty-two checkpoints execute the original
asynchronous Swift store and compare its observable state with Rust, including
one canceled waiter, account retirement, failures and settings races.
Home archive rows, errors, loading and successful-load throttles belong to
independent registered window readers, as `RootView` owns each `HomeModel`.
Tests cover one window hiding or closing while another joins/completes the
same vendor flight. Releasing a window retires its pending deliveries without
retiring the shared store.

Accepted account-status responses drive a shared login/helper lifetime gate;
23 transitions compare its generation and receipt behavior with the original
Swift update method for normalized host replies. Old cross-window reads cannot
restore earlier identity. An owner change hides old quota data immediately and
retires calendar/day reads without reusing request identifiers. These are
state/integration checks, not full authentication, saved-access/routing or UI
acceptance. Account/composer consumers and settings mutation/events remain
unported; no live account was used to verify the adapter.

Remaining Home gates include editor drag/keyboard/focus scrolling, native sheet
behavior and AX announcements; complete locale/calendar relative-time
formatting; animated loading/tooltips; Account/composer/settings-event wiring
and full owner/authentication workflows; sync/credential suggestions; Continue/pins, full Devices flow and
Getting started. The new panels/editor have no accepted same-state captures.
Existing day/font/pointer and full-app/Linux gates below remain open.

## Foundation verification

The Rust build now extracts the initial palette, font scale, shell/control
metrics, rail, global/workspace routes and action-glyph vocabulary from the
SwiftUI source. Rust models implement the initial route selection, pane fit,
sidebar toggles, localization and account-menu state behavior. Shared GPUI
text, font-loading, panel and chrome-bar adapters consume these values.

`scripts/tests/linux-swiftui-contract.py` compiles the original Swift
declarations and compares their outputs with Rust using synthetic inputs.
This covers 378 pane-layout cases, six sidebar transitions and 16 account-menu
states, alongside route, copy, palette and glyph-name checks. These are source
and state checks. Rendered pixels, complete root composition, remaining
menus/screens, input handling and native Linux acceptance are still open.

The published GPUI Linux backend stores application-menu definitions without
providing a system menu bar. Implementing a visible, accessible menu surface
with the required focus, shortcut and dismissal behavior is part of this port.
Calling `set_menus` alone cannot satisfy menu parity.

## Current rendered shell preview

`--desktop-preview` renders the initial source-shaped shell separately from
the probe. `--shell-fixture` supplies synthetic signed-out account/folder data,
does not acquire the host owner lock or open the host/archive, and exposes the
Linux menu surface on macOS. Connected reads and folder picking use the
existing host protocol on worker threads. Failed fields preserve a previous
reading with an error; a successful empty directory remains authoritative.

The initial menu tree shares command identities between shortcuts and popup
dispatch. It includes app-owned File/Edit/View commands, four chat-detail
levels, and the dynamic account tree. Tests compare app-owned copy, modifier
bindings, detail options and the Compact default against current Swift code.
Keyboard input supports selection, enabled-row wrapping, submenus, horizontal
application-menu traversal, typeahead and dismissal; closing restores focus.
Disabled pointer rows cannot accidentally execute the previous selection.

Native macOS fixture inspection verified menu opening, detail submenu/check
state, selection, pane shortcuts, account navigation, horizontal traversal,
outside-click consumption and the Team rail destination. The first capture
exposed a missing Team vector mapping and variable-font default weight; both
were corrected and inspected again. Static font instances now embed real
400/500/600/700-weight outlines from both original bundled variable fonts.
This is a rendering/input milestone, not a same-state SwiftUI screenshot diff.

Home now has an initial profile/activity implementation described below.
Other feature contents remain gaps. Unported
commands explicitly report that status. Further gaps include native/default
menu completeness and localization, popup geometry and pointer submenu/menu-bar
traversal, native check/enablement rendering, global persisted detail settings,
continuous corners/materials, final glyph shapes/fills/weights, small-display
font fit, avatar/tier fidelity, retained feature panes, workbench behavior,
resize handles, hover peeks, modal focus trapping and accessibility. GPUI's
macOS AX tree currently exposes the window and native menu bar, not these
custom controls. Linux AT-SPI/input and compositor verification remain open.

## Home activity implementation

`src/home.rs` owns wire presentation and request generations;
`src/desktop/home_view.rs` owns the initial GPUI Home rendering. Connected
calendar reads call the existing `activity.calendar` method after the mandatory
protocol handshake on a worker. The renderer consumes delivered rows, dates,
levels, totals and streaks. It never rebuilds the calendar from usage events.
The synthetic fixture uses the shared core's calendar builder with explicit
synthetic dates/values and opens no archive.

The scope picker keeps requested and delivered scope distinct. A local fallback
is labelled as this device, with the account sign-in notice when the host sends
`noticeCode=auth`. A failed read keeps the last grid and reports the error;
only a successful null response confirms an empty archive. Request generations
discard stale scope completions. Date selection survives refresh/scope changes,
and hover and selection use the same measured canvas packing. Gaps, future
blanks and locked cells cannot be selected by the pure hit-testing function.
The initial day-detail implementation is described below; rendered pointer
coverage still needs further verification.

Profile figures use the host's current/best streak and active-day fields with
tabular Manrope numerals. The source's greeting, literal interpolation and USD
currency presentation have initial Rust equivalents. The activity mark reuses
the original product SVG. Five heat colours and the initial packing constants
are extracted from Swift at build time. The initial loading/error/history-lock
surfaces are partial; they are not completion evidence for those states.

The compiled source comparison now also runs original Swift heatmap layout/hit
functions, ActivityScope, HomeGreeting, Money/formatSpend and activitySubtitle.
It covers 56 heatmap layouts with gap/future/locked hit inputs, five heat levels,
two scopes, four delivered-scope subtitle states, 16 currency boundaries and
160 greeting cases. It caught and corrected decimal half-even rounding at
1.015 dollars. Source fonts register in the temporary reference bundle; 26
actual NSHostingView text-height measurements cover both bundled families.
The Rust build reads their font metrics, and GPUI now uses the measured native
line-box convention instead of its default phi spacing. Card borders also
reserve their width inside source padding to match SwiftUI's overlay strokes.
These checks establish specific source values and sizes, not pixel parity.

Native fixture inspection verified the scope picker, disclosed local fallback,
profile figures, calendar drawing, selected-day ring, hover date/value footer,
hover dismissal without losing selection, and repacking beside the inspector.
A startup capture exposed a blank rail until input; its height now comes from
the already-known viewport rather than nested percentage sizing. A fresh
capture showed the rail before input after the change. Native Linux startup
and repeated compositor validation remain required.

Home completion still requires plan limits/usage, Continue, pins, machines,
customization and persistence; sign-in/scan/Getting Started workflows;
freshness presentation;
exact skeleton/empty/error/locked states and animations; avatar/tier marks;
native-system text roles and baseline alignment; small-window composition;
keyboard/screen-reader navigation; and same-state SwiftUI/Linux screenshot
comparisons. No Home or whole-app visual-parity signoff has occurred.

## Home day detail implementation

`src/home/day.rs` owns typed day-detail/overview readings, independent hover
and selected-day generations, refresh/scope invalidation and presentation
grouping. `src/desktop/day_view.rs` renders the initial hover card and pinned
inspector from `DayDetailPopover.swift` and `HomeInspector.swift`.

Connected reads use the existing `activity.day` method with date, delivered
scope and 53 weeks. Local inspector breakdowns use `totals` plus four `report`
queries for model, source, project and session; only session sets `limit=80`.
Individual overview failures remain absent, matching the source's independent
optional reads. Account scope never requests local project/session breakdowns
or reuses cached local detail. Pointer leave cancels hover delivery without
cancelling a pinned-day read; hover waits 140 ms before IO. Date echoes,
scope and generations fence stale responses. These paths have fake-socket
tests; no live archive or account was accessed for this milestone.

The initial renderer includes day date/value/headline/counters, split bar and
legend, Models, Coding tools, Repositories, Sessions and Unpriced/local models,
list limits, loading/empty/locked presentations, close control and pinned
Open in Insights footer. Unknown counters remain `N/A`, distinct from zero,
and aggregation saturates. Vendor and feature marks embed the original shared
SVG assets. Open in Insights retains the selected date, updates the local
snapshot query and navigates to the initial Insights route described above;
its complete visual and interaction parity remains open.

The compiled reference now also runs the original Swift popover placement
properties, inspector grouping/counter/split math, signed Money formatting,
compact token labels, model labels, tool aliases and brand-asset selection.
It compares 90 window/anchor placements, 15 detail/overview combinations,
32 money qualifier/sign cases, 17 token boundaries, 15 model labels and
26 tool names/aliases. It caught Foundation whitespace and Gemini-name
differences, which were corrected. These source checks do not establish
rendered pixel parity or complete wire/schema compatibility.

macOS fixture inspection showed priced-day details, inspector scrolling to
the lower cards, empty-day content, closing the inspector, hover placement
and navigation to the explicitly unfinished Insights screen. Pointer coverage
is incomplete: some right-side upper-grid clicks did not reach GPUI event
handlers in this desktop-testing session, while left-side empty-day selection
and other controls worked. Window focus/placement and clipping trials did not
resolve it. The cause remains unproven; do not count those clicks as verified
or attribute the failure to Linux. Temporary tracing was removed.

Day-specific gaps include same-state SwiftUI/GPUI screenshot comparisons,
complete pointer and keyboard coverage, accessibility, local date/number
preferences beyond environment locales, native-system caption roles, middle
truncation, tracking, exact shadows and spinner appearance, reduced motion,
loading/error/locked visual fixtures and native Linux validation. Dot colours
use the same five-colour palette and a stable per-process hash; Swift's
process-randomized `hashValue` does not supply a cross-process colour mapping.
No day-detail visual-parity signoff has occurred.

## Fixed-state rendered references

`--day-fixture NAME` renders the same GPUI day-view functions at a fixed
400×797-point inspector or 360×400-point popover size. Inspector states are
ready, empty, loading, locked and no-selection; popover states are ready and
loading. Light/dark suffixes force the renderer's theme without changing desktop
preferences. These modes are dispatched before host/owner setup.

`scripts/tests/linux-swiftui-render.py` compiles the original HomeInspector,
DayDetailPopover, DesktopHomeMachines, Card, Stat, marks and inspector/button primitives with an
immutable fixture-only HomeModel. It embeds the original variable fonts,
localization and asset catalogs. It creates no visible window and runs no
production model/host polling. Thirty-six PNGs render at a fixed two-pixel scale;
the manifest records dimensions, input/harness hashes and explicitly says
pixel parity is unverified. A separate environment file records display fit,
locale, preferred languages, timezone and OS. Generated files remain ignored.

Initial manual comparison of matching ready-inspector fixtures exposed native
system-font roles incorrectly rendered in Manrope. The port now distinguishes
the source's system card headings/captions/footer and native Stat note from
bundled-face text. Native line boxes use measured ascent/descent; a measured
descender-seat difference aligns the native caption beside the Manrope number.
The no-selection state now follows the original centred 28-point mark,
13/11-point text, 10-point gaps and 360-point subtitle width. Final rendered
alignment of these corrections still needs inspection.

`examples/font-contract.rs` measures actual GPUI platform shaping in a hidden
window, including the numeric figure feature. The render script's optional
`--compare-gpui-fonts` compares these widths/line boxes with original Swift font
selection. The original 101-versus-98 system-medium discrepancy was traced to
GPUI/font-kit's macOS weight selection: AppKit's 0.23 Medium trait maps to CSS
530, above the 400/500 selection range. The macOS adapter now selects the right
face, without changing text size or spacing. Linux keeps actual CSS weights.
All 149 current rounded intrinsic-width/line-box cases pass locally, across
native weights 400/500/600/700, five sizes and multilingual/emoji samples plus
the original bundled-face cases. The strict command writes a passing report;
the proposed macOS CI now executes it. No tolerance was widened. Computed baseline seats are
recorded, but source baseline/glyph alignment is not signed off. GPUI's
platform UI font also needs Linux font availability/shape/metrics acceptance.

Later native inspection in this session failed with `cgWindowNotFound` for
both the new fixture and the previously working shell binary. Startup traces
showed a returned render tree and one open window; a process sample showed the
normal idle event loop, not a render deadlock. Changing fixture decorations,
title, focus or test-bundle identity did not establish a cause. These are
capture/graphics-environment observations, not proof of a Linux defect or a
fix for the earlier pointer issue. Temporary traces were removed and owned
fixtures were stopped. Reinspection, full-screen differences and real Linux
acceptance remain open.

Home's device card now consumes the account's real `machines` array and follows
DesktopHomeMachines' labels, tri-state status, icon selection, separators,
tooltip and keyed Devices selection. The source comparison covers 438 device
cases and six selection/refresh/removal cases. `--home-fixture` provides
`machines-ready`/`machines-empty` in both appearances, at 400×220 points. A
native `component-preview` executable also avoids shell-wrapper ambiguity in
test bundles. Capture still failed with `cgWindowNotFound` for that executable;
the wrapper hypothesis did not resolve the issue. The owned process was
stopped. Card geometry/typography/glyphs/input/AX and the unported Devices
destination still require acceptance.

Continue and Pinned work have initial GPUI row/card views and ready/empty
400×360 point fixtures in both appearances. The pure work projection preserves
the four-reference limit before hidden/unused rows are removed, live directory
labels, source unavailable messages, saved-copy gates and ended-terminal checks.
Open requests recheck current scope/access rather than trusting a row captured
before an account change. Unpin and open remain separate targets, including on
unavailable rows. An account/helper lifetime change retires injected work data.

The compiled reference runs the actual RootView projection and open methods
with inert loaded-model adapters: 864 availability states, 54 folder routes and
28 row/open scenarios. Inputs inject the existing ChatModel.isUnused result
and already-verified access/cache facts. This does not verify the chat draft
store, access/cache authentication, or their IO. The durable work layer now
supplies account-origin canonicalization, Unicode keys/labels, a persisted
local installation ID, pin validation/capacity and continuity/place envelopes.
Connected previews now bootstrap this metadata off-thread and resolve the local
daemon's public key through the existing protocol. Shared snapshots are
projected against each window's loaded local directory. Peer directory,
complete chat, saved/access and terminal consumers remain unported; the service
does not initiate a peer connection or transcript read to fill those gaps.
Full chat reveal, saved reader, terminal selection and complete
pin/context menus are still unported. Fixture pin/unpin changes only shared
ephemeral metadata and never saved-copy retention. The ordinary component source
images now total 46, including ten chat-rename states;
disabled-row opacity was carried into the GPUI view after source inspection,
but glyphs, geometry, focus, pointer, keyboard, AX and Linux pixels remain open.

`work/preferences.rs` serializes read-modify-write operations with a shared
file lock, rereads before mutation and atomically replaces a private file.
It preserves unknown container/value fields and rejects malformed containers
or symlink targets without replacing them. Source data blobs retain the
Codable Date epoch, 100-visit limit, 256KiB visit and 32KiB place read limits,
scope-specific eight-pin refusal and re-pin behavior. The disk format is a
Linux GUI preferences container, separate from the host archive and Mac's
preferences domain. Connected Linux previews use `config_dir()/desktop-work.json`
and persist project pin/unpin, Home unpin and navigation places through a serialized worker. An
absolute `TOKENSTAT_DATA_DIR` puts both GUI preference files below its
`desktop-preferences` directory for isolation. Connected macOS previews use
memory, and component fixtures disable the service entirely.

Scope changes retire displayed metadata immediately; receipt/helper changes
within the same scope retain verified local data while fencing old deliveries.
Errors retain a same-owner snapshot and appear in the existing preview banner.
Reads coalesce without dropping queued writes, including writes captured before
an account changes or the originating window closes. Window labels and
directory readiness are not shared. The source's known-empty versus not-yet-
loaded distinction is preserved. The local public identity requires the source
wire shape and never falls back to a fingerprint, label or network address.

Deliberate route changes use the source rememberPlace policy. Saved visits are
not invented from opening a Chat placeholder; actual chat selection still
needs its owner. Bootstrap loads the initial place/restoration flag without
applying it after first paint. Source splash, 1400ms settling, once-per-process
claiming, external-open precedence, peer restoration and Startup settings remain
unported. Ordinary menu quit/last-window close perform a five-second bounded
preference drain before GPUI quit. Accepted draft operations additionally drain
without that preference timeout. GPUI 0.2.2's native quit hooks alone allow
100ms; compositor/session termination and force-stop paths still need native
validation and integration.

Compiled source checks execute the complete original pin/continuity stores
against private in-memory defaults, comparing eleven traces plus 198 origin,
45 key and 37 Unicode-label cases. The origin shim intentionally preserves
URLComponents path behavior rather than browser navigation normalization.
Login lifetime checks also cover canonical-equivalent handles/receipts and
invalid origins. These checks do not establish a complete Account/auth flow,
native launch restoration, cache authorization or every Foundation/platform
edge case. Those integration and native acceptance gates remain open.

## Initial project row and menu

`project_menu.rs` follows all branches in `RootView.projectActions`,
`WorkspaceRow.menu` and `SidebarPinAction.items`. The compiled original
declarations compare 1,536 complete ordered menu snapshots, retaining titles,
symbols, disabled capacity explanation, separators and destructive metadata.
Seventy-two cases execute the original pin-reference resolver against local,
remote, empty and malformed route IDs with known/unknown scopes and identities.
Loaded sharing/git/stale facts are tested explicitly; their production owners
are still unported and are not inferred from machine labels or account status.

`desktop/project_rows.rs` captures a folder/reference and pin operation at menu
opening. Pin creation and unpin use the shared serialized worker; an account
change or selected-row change cannot substitute a different target. Capacity
is checked again by the store. A concurrency test covers two window clicks at
seven pins followed by an account change: exactly one fills the shelf, neither
writes into the next account, and the captured labels survive. The source
ignores the pin return value, so no new toast is introduced. Fixture pinning
uses the same store rules in private memory without enabling metadata IO.

The initial row has a 30-point fitted height, 18-point disclosure/mark seats,
source title weights and reserved 24-point hover controls. Selection and New
terminal open Sessions; the launcher content remains unported. Connected local
Reveal uses the platform file manager adapter. Saved work, sharing,
disconnect, chat, worktrees and chat deletion still report
explicit gaps. Source/native menu text uses the measured 13-point system font,
and popups now render the image column. NativeMenuTrigger does not apply red
styling to its destructive metadata, so the preview does not add it. Popup
widths now accommodate the capacity explanation and top positions clamp to the
window; exact native menu geometry/scrolling/traversal still need acceptance.

Remaining terminal/job children, summary/git/remote/sharing feeds,
hover cards, selected symbol variants, middle truncation, native input/focus/AX,
same-state screenshots and all real Linux gates remain open. No project row or
menu has visual or functional-completion signoff.

## Initial project rename and removal

`desktop/project_dialogs.rs` now mounts the original rename sheet's inner
anatomy, dimensions, wording and save/error/retry behavior. Save captures its
scope/reference when submission starts. A successful host mutation dismisses
even after that scope retires, while retired directory results cannot publish.
Its following pin-label update is one atomic existing-pin transaction; unpinning
during a pending rename cannot resurrect the shortcut. Failed saves retain the
name and error; retry keeps the error and 300-point frame while controls disable.

`text_input.rs` and `input_field.rs` provide an actual platform input handler,
with UTF-16/UTF-8 conversion, marked text and relative composition selection,
candidate geometry, grapheme movement/deletion, mouse selection, clipboard,
undo/redo, caret and horizontal scrolling. Tests cover surrogate splitting,
combining marks, reversed ranges, marked replacements, selecting all during
composition and retiring a redo branch. These are model/API checks; native
IME/keyboard/selection, undo grouping, focus/caret timing, AT-SPI and pixels are
not accepted. Fields and sheets are not complete merely because typing code
compiles. The source's circular 22-point close seat and measured native Cancel
button's 89×24-point size inform the initial renderer; default bezel and sheet
attachment/material behavior still need acceptance.

Local Remove calls the existing registry-only host method after confirmation.
An authoritative reload moves a removed current project to the first remaining
project's Sessions launcher, or Home when none remain; unrelated routes stay.
Newly seen projects read the source's per-key persisted expansion choice,
defaulting to expanded, while known in-memory choices survive reload. Failed
directory reads do not assert empty.
The dirty-document gate blocks removal and requires another explicit Remove
after closing; the editor owner/close prompt and real tab/browser/document
cleanup are still unported. Remote routing is implemented in the transport/model
and verified, but the missing remote directory owner remains a visible gap.

`sidebar.rs` ports the complete additive SidebarPreferences store, including
boolean-only expansion values, history/server expanded-ID queries and section
order normalization/moves that preserve unknown future values. The compiled
reference executes the original class and RootView disclosure setters/arrival
expressions in 63 traces (1,701 checkpoints), covering malformed preferences,
Unicode-equivalent IDs, disappearing/returning projects and separate windows.
Only the disclosure portion of directory arrival is compared here; retained
workbench cleanup and missing-route behavior have separate owners and gates.

The Projects section and individual project disclosures use an app-owned
background worker over the existing GUI-only `desktop-work.json`. Writes merge
one key into current locked storage, survive window closure/account changes,
and join ordinary quit draining. A late first read initializes untouched rows
without reversing clicks. New or returning rows use current shared preferences;
already-known rows retain their window's own choice, matching RootView's local
state. Failed writes retain the in-memory intent and an error until that key
succeeds; an unrelated successful write cannot clear it. Selecting a project,
New terminal and Home project navigation reveal and persist its disclosure.
Authoritative removal fallback does not force open the next project's row.
macOS previews and synthetic fixtures never use production preferences.

The store's section ordering/server APIs do not port their missing UI owners.
Conversation history disclosures now have the initial owner described below.
Server disclosures, section-order controls, terminal/job children,
launch-location restoration, active keyboard/AX behavior and native first-paint
timing remain open. Store/owner tests are not startup or visual signoff.

## Initial conversation children

`chat.rs`, `chat/directory.rs`, `chat/history.rs`, `chat/flights.rs` and
`desktop/chat_rows.rs` now supply title-only conversation directories under
expanded projects. This follows `projectChildren`, not a new list of section
links: the source places live terminals, conversations and running jobs here.
Only conversation children are implemented so far. Existing `chat.list` and
`remote.call` own the data, with the original raw-workspace routing rules.
No transcript, event page or agent-start method is called by directory warming.
`chat.list` returns the host's normal conversation records, which can include
setup/resume fields. The frontend now decodes the full private record in memory;
"title-only" describes this warming/cache purpose, not a narrower wire payload.
The Home projection still receives only its consumed fields.

Directory caches belong to each window and retain at most 30 projects. Only
simultaneous transport is shared across matching account/helper/folder readers.
Closing a window or collapsing a project retires its waiter without canceling
another window's producer. Results are not a global transport cache. Account
changes clear the private directory; same-scope helper replacement keeps verified
titles while retiring deliveries. The transport checks retirement before startup,
after protocol IO and after the response. Both result branches are checked again
against the current global generation before they can reach a window.

The visible list has the original five/ten limits, selection-following window,
hover-held order, appended arrivals, release on disappearance, history expansion
preferences, Show more/less and See all controls. Arrow commands use live list
order, matching ChatModel, while held order stabilizes pointer targeting. Row
selection and overview state are initial route/metadata state, not a completed
conversation reader. The running label has a separate entity/timer with one-second
updates, first-observed stamps and the original Working prefix. Only visible
rows own these timers. Native scheduling, power/session behavior and inactive
window handling remain unverified.

Loading, first-read retry and authoritative empty states are distinct. Failed
refreshes retain verified content, including a previously loaded empty list.
The row ports mark/title/pull/draft seats, numeric age/status, selection/hover,
reserved actions/info controls, right click and Shift presentation. Pin/unpin
capture the opening-time reference, operation and labels and use the existing
metadata worker. Rename now has the initial captured owner described below;
Fork now has the initial captured owner described below; deletion/confirmation,
detail cards and preview dwell reads remain gaps.
The full wire DTO and initial page-window foundation are described below.
Send/live-event integration and the mounted active transcript remain open. The directory now uses the original read-flight invalidation,
list mutation and pending-note boundaries before enabling its first mutation.

[chat/list_mutations.rs](src/chat/list_mutations.rs) and
[chat/steer_overlay.rs](src/chat/steer_overlay.rs) port the complete original
state owners. Captured request order prevents late predecessors regressing a
newer list. Only edits completed after a read began overlay that read; a fresh
list remains authoritative. Pending-note acknowledgments keep independent
per-project sequences and per-conversation mutation revisions, so an older
delivery/clear cannot erase a newer identical acceptance. Metadata replies
preserve the current note. These are frontend state rules over the existing host,
not another chat backend or evidence that the send UI is ported.

[chat/flights.rs](src/chat/flights.rs) retries invalidated results and errors
without surfacing an invented transport failure. Invalidation drops sharing
slots but never cancels producers, and predecessor teardown cannot erase a
successor slot. Account/helper owner bytes, canonical peer identity and raw
parameter spellings follow `ChatReadFlights`; mutation domains span all projects
on the matching host. Completed values are never a transport cache.

[chat/query.rs](src/chat/query.rs) now gives directory, event-page and tail/whole
reads distinct typed identities, with their fixed original result types and
60-second patience. Cursors, offsets, limit and usage flags are part of the
identity. Timeline requests do not acquire a workspace parameter merely because
a caller came from a different folder. The worker prepares the existing host,
checks the account/helper epoch before and after protocol/feature IO, routes
through the existing `remote.call` when needed, and decodes once into immutable
shared replies. The original plain-text core RPC API stays compatible; its new
coded-error API preserves the remote code and raw message for the exact original
`unknown_method` / `unknown ` prefix fallback. Transport and decoding errors
cannot masquerade as an older host by containing similar words.

[chat/transport.rs](src/chat/transport.rs) provides one actual GPUI shared pool
for all three types. The sidebar directory now uses it, so rename/fork
invalidation also applies to any timeline consumer. Exact waiter leases survive
until delivery: a callback can cancel another lease or release another retained
entity even after their producer has left the pool. Retired waiters cannot
retry, publish or erase a successor, and cancellation never stops another
window's producer. Page replies remain shared Arc values through the publication
API; per-window projection and committed rows retain separate ownership.

This transport is not the full retained ChatModel/controller. Product directory
mounts still request only titles; no transcript IO is enabled by opening the
existing placeholder. The selected/load/reveal/helper-adoption, original
full polling/status/approval composition, load/selection cleanup and ChatView
owners remain open. The retained live-page owner below now binds opening,
awaited transport, metadata projection and publication for a stable owner. Consumer lifetime guards must not replace page-specific publication
checks: a still-owned stale reply may need to finish its original progress defer.
Other read methods must join this same boundary when ported.

[desktop/chat_mutations.rs](src/desktop/chat_mutations.rs) wires Rename through
the existing SidebarRenameSheet adapter. It captures the row's project/id,
invalidates before and after either mutation result, rechecks retirement after
protocol IO, publishes the returned metadata through reconciliation, and relabels
only an existing pin while preserving its latest folder name. Pin effects outlive
the initiating window. Scope changes dismiss the retired chat sheet, and tickets
prevent old replies affecting a newer sheet. Running chats can rename; shared
chats remain disabled. The original active-reader `contextRevision/sendRevision`
step still needs its unported selection owner. Native sheet attachment/chrome,
focus/IME, keyboard and pointer behavior, AX and pixels remain gates.

[linux-swiftui-chat-mutations.py](../../scripts/tests/linux-swiftui-chat-mutations.py)
compiles the unchanged complete `ChatListMutations`, `ChatSteerOverlay` and
`ChatReadFlights`. A minimal synthetic conversation supplies only their consumed
fields. Thirty-four list/note traces / 616 checkpoints and the eight read/twenty
mutation classifications compare strictly. Original read-actor tests use actual
continuations for thirty shared waiters, cancellation, retries, type/cursor and
account/peer isolation. Rust tests cover the mounted directory adapter and fake
local/remote rename transport, including retirement during protocol IO. This
does not establish full reader or native GUI behavior. The optional check below
also exercises the actual GPUI transport against an owned temporary Unix host.
It verifies shared pages, immutable replies, both invalidation result branches,
all three read types, coded refusals, successor slots, completed-cache absence,
exact and batched cancellation/entity release, pre-IO retirement and foreground
resumption. Fixture-owned Window adapters then consume the same shared page
through two real CPU lanes: retiring one selection cannot stop the other reader
from publishing raw events and rows atomically. These adapters are explicit
substitutions for the unfinished retained ChatModel/load/poll controller. The
check opens no product window, archive, account or production store.

```bash
python3 scripts/tests/linux-swiftui-chat-mutations.py --compare-gpui
```

`component-preview project rename-chat-STATE-THEME` covers ready, empty, error,
saving and retry. Ten original SwiftUI chat-rename references join the ordinary
component render corpus (46 images); the twenty-two original child references remain
separate. Neither set is a GPUI pixel comparison or native Linux signoff.

[chat/actions.rs](src/chat/actions.rs) and `desktop/chat_mutations.rs` now wire
initial Fork. Copying/error state belongs to a mounted account/host/project/row;
it does not cancel an accepted backend copy when the row disappears. Tickets
prevent an old completion clearing a recreated row's newer copy. The menu shows
Forking and disables duplicate Fork/Delete/Shift controls, while the information
control also follows copying/error state. Pending errors stay with their rows;
the window presents them one at a time and restores focus after OK.

The owning project routes the original `chat.fork {id}` through the shared host.
The source's remote protocol-26 capability check precedes mutation invalidation;
probe failure and unsupported versions return the original update-computer
message without sending the method. Positive probes are fenced again before
dispatch, and both mutation result branches invalidate predecessor reads.
Publication uses existing list reconciliation. A copy is revealed only when
the current route equals the operation's original route, including leaving and
returning. Scope/helper retirement cannot publish or retain a stuck copying flag.
Canonical Unicode route equality and hashing now follow actual Swift enums.

[linux-swiftui-fork.py](../../scripts/tests/linux-swiftui-fork.py) executes the
complete original bridge/model fork methods, capability enum, row task body and
root callback against owned continuations. It compares 192 outcomes plus five
actual Swift route equality/set-membership pairs. Inert row fields represent
mount lifetimes; actual SwiftUI observation and GPUI callbacks remain unverified.
Rust tests additionally check stale/recreated rows, isolated queued errors and
fake-socket local/remote protocol/dispatch, malformed/old peers and retirement.
The full transcript/selection/reveal owner remains unported. Complete wire
records and initial page-window rules are described below. Same-scope
helper cancellation text and simultaneous native sheet/menu presentation still
need source/native interaction acceptance; they are not waived by these traces.

[linux-swiftui-chat-alerts.py](../../scripts/tests/linux-swiftui-chat-alerts.py)
measures the actual original fork alert modifier in transparent inactive owned
windows. The 260-point content uses 13-point bold/regular native text, 20-point
insets and one 228×28-point OK button with the cancel role/Escape equivalent.
It has no icon, Return key equivalent or default button, even with button focus
in the inactive reference. Five message shapes in both themes match the real
hidden-window GPUI component's content frames, copy and roles. Shared two-button
confirmation regression checks also pass all eight previous cases. These checks
do not grant active keyboard/focus, glass/material or Linux pixel signoff.

`component-preview project fork-error-NAME-THEME` mounts failed, long, unicode,
account-changed and unsupported states. Native raw captures preserve transparent
foregrounds; separate flat semantic-background previews are labelled inspection
artifacts, not composited glass. Visible-content checks reject empty captures;
manifests hash inputs, output geometry, images and toolchains. Copying children
have their own matching source/GPUI fixture. All native/Linux gates still apply.

Production draft presence now comes from the private app-owned store described
below. It remains unknown while restoration is pending. A completed failed read
follows the original empty-memory/saveFailed result while preserving damaged
bytes, rather than silently overwriting them. Offline fixtures seed this same
owner in memory. The existing Home projection now consumes known draft-aware
facts from each window's loaded local chat directories, without initiating more
IO. Full chat/peer/access consumers, terminal/SSH/workflow/job children, sharing
owners and section-order UI remain open.

The compiled original-source comparison covers 220 visible windows, 550 arrow
steps, 20 held-order cases, all 128 chat menu states, 16 directory presentations,
64 known-draft untouched filters, nine sidebar-field wire projections, age and
elapsed-time boundaries, ten grapheme initials and the cache cap. The shared
fallback mark now takes the first whole grapheme, preserving joined emoji and
combining accents as HarnessMark does. It executes original declarations;
it does not instantiate the real ChatModel, draft store or host. Missing draft
facts are deliberately outside the known-draft filter comparison.

The separate [draft reference](../../scripts/tests/linux-swiftui-drafts.py)
executes the complete original `ChatDraftStore`, `OriginalFileCoordination` and
`WorkReference` against explicit temporary directories. It compares 14 store
traces / 97 checkpoints, including stable/replaced/legacy delivery IDs, exact
submitted-version clearing in memory and latest disk, account/host/key isolation,
canonical String equality, attachment-only work, whitespace clearing, queued
changes, failed writes/deletions/retry, initial corruption/oversize and quota
byte counts across finite date boundaries. UUID normalization is explicit;
original code is unchanged, and only attachment extraction/localization errors
use inert harness adapters. Manifest inputs, toolchains and outputs are hashed.

[drafts.rs](src/drafts.rs), [drafts/service.rs](src/drafts/service.rs),
[drafts/storage.rs](src/drafts/storage.rs) and
[drafts/coordination.rs](src/drafts/coordination.rs) own the initial Rust port.
Every scope stays in `data_dir()/desktop-drafts` on connected Linux; prose is
user data and never evicted to meet the 8 MiB bound. Constructors are inert,
registration and bounded IO run on workers, accepted edits outlive windows and
account changes, and failed mutations remain pending. Writes reread under a
persistent `fcntl` lock, atomically replace a 0600 file in a 0700 directory, and
sync file/directory. Empty storage preserves the lock inode. Independent original
Swift/Rust processes preserve and reopen 50 simultaneous edits, keep private
modes and the lock inode, and refuse live/release terminated participants in both
directions. Same-process tests cover nested gates and in-use originals.

[desktop/draft_marks.rs](src/desktop/draft_marks.rs) isolates mark membership
notifications from text edits. Missing marks use `display:none`, reserving no
extra flex gap. As in the original non-observing `isUnused`, membership changes
alone do not relayout the list; navigation/current list updates ask again.
Initial readiness/error changes notify the parent. Pencil geometry, accessibility
labels/AT-SPI, native input and pixels are still gates. The active composer/send,
staging/attachment UI, retry notice and explicit original-file removal owner
remain unported. The coordinator primitives do not prove that future removal
checks live memory/disk references under the same gate. Async registration timing,
special-file/symlink hardening differences, session termination and all real
Linux filesystem/lock behavior require native acceptance. No original retention
or attachment file is removed by this implementation.

`component-preview project children-STATE-THEME` mounts ready, empty, loading,
failed, expanded, selected-tail, hover, shift, held, decorated and copying fixtures.
`python3 scripts/tests/linux-swiftui-chats.py` renders the corresponding 22
original SwiftUI references from the actual child/list/row bodies with inert
owners, fixed clocks and initial hover/Shift state. Skeleton reduced motion is
injected only into the reference, without modifying system settings. Windows
remain transparent/unordered/inactive. The ignored manifest records all captured
declaration inputs, fonts/assets/localization, harness/fixture/image hashes and
toolchain/runtime metadata. Closed menu/detail adapters and absent terminal/job
owners are explicit fixture substitutions. These are source references, not GPUI
captures or approved pixels. Geometry, truncation, glyphs, focus, input/AX,
materials, motion and all real Linux acceptance gates remain open.

The compiled reference executes the complete original WorkspacesModel.remove
method against inert bridge/document/directory adapters in 504 cases. It checks
dirty blocking, malformed-prefix local forgetting, local/remote RPC arguments,
failure retention, selected-ID cleanup and reload/publish/peer-refresh calls.
Separate fake sockets verify protocol-before-mutation, acknowledgement schemas
and forwarding through the existing remote.call method. No real registry,
folder, host, peer or account was mutated by these checks.

Removal now uses the app-owned confirmation described below. The pinned GPUI
backend's generic white, pointer-only fallback is no longer used by this flow.
Native materials, focus, accessibility and Linux acceptance remain open.

`component-preview project rename-STATE-THEME` provides ready/empty/error/saving/
retry components before client/owner setup. The reference renderer compiles the
original SidebarRenameSheet and ThemedSheet/field primitives, injecting only
private initial state; their bodies and callbacks remain original. Ten new
source images join the previous 26, at 920×500/600 pixels. They are hidden
inactive reference windows, not matched GPUI captures or active-focus proof.
No project edit/removal surface has visual or functional-completion signoff.

## Reader records and initial page window

[chat.rs](src/chat.rs) now decodes the complete private ChatConversation, including
setup, permissions, resume token, pending note, sharing marker, routing and run/
send revisions. These records stay in private memory; the Home projection remains
small. [chat/wire.rs](src/chat/wire.rs) supplies full timeline/agent/approval,
page/chunk, usage and routing records. Unknown kinds survive; one malformed event
is skipped while a malformed page envelope still fails. Legacy spellings follow
the source's lazy fallback, tool input objects are not token counts, and shared
read-only approvals cannot adopt a private conversation ID. Known scalar types,
integer ranges and required permissions/identities remain strict. Nil object
fields currently encode as null where Swift omits them; the comparison explicitly
normalizes that encoding difference. DTO equality/hash semantics and their future
render-invalidation consumers are not signed off by decoder comparisons.

[chat/recent_messages.rs](src/chat/recent_messages.rs) ports the complete original
bounded display-row cache: ten conversations per project, sixty overall, newest
150 rows and 512 KiB per entry, speculative-first eviction, non-touching peek/
contains, promotion on open and canonical String keys. An empty/oversize newest
row leaves an older copy intact. It holds rows, never downloaded bytes or a second
archive. Actual row reflection byte-cost accounting, background preview warming
and mounting the same disabled live renderer remain work for the projector/view.
[chat/send_context.rs](src/chat/send_context.rs) preserves the exact one-step own-
edit revision rule; the existing rename controller still needs the mounted active
reader before it can update that context.

[chat/paging.rs](src/chat/paging.rs) is an unmounted retained-window foundation.
Newest opens request 1,500 records; older pages request 1,200. It separates unread
from loaded empty state, keeps opaque cursors, filters prepend overlap, preserves
whole-conversation usage, replaces trimmed windows and fences replies by owner,
selection, replacement epoch and cursor. Both initial page failure branches fall
back to the original whole read; only an unknown method disables future paging.
Quiet tail failures retain content without introducing an error. A reset full
fallback finishes rather than recursively awaiting its own open. Setup metadata
alone cannot grant a displayed send context. Edits capture the original revision
and exact selection/owner before waiting, preserve the current pending note and
refuse old replies after leaving/returning or changing owner. Portable tests cover overlapping
prepend/tail completions, duplicate tails, trim retirement and account/helper/
selection retirement. This is not the complete ChatModel, selection/load/reveal,
polling, saved-copy, outgoing, scroll/follow/restoration or CPU projection owner.
It does not dispatch a new host method or replace the current Chat placeholder.

[linux-swiftui-reader.py](../../scripts/tests/linux-swiftui-reader.py) compiles
unchanged complete original wire decoders, recent-row cache and send-context
helper. It compares 1,480 decoding cases, 15 cache traces / 220 checkpoints and
343 revision cases with exact numeric equality. The complete original newest/
earlier/tail read methods and Bridge parameter builders additionally compare in
35 traces / 123 checkpoints, including synthetic bridge CancellationError at an opening. Selection setup, immediate event publication,
closed reading-reference, cache/attachment/notification/markdown side effects and
the opening wrapper are explicit inert substitutions. The separate suspended-publication comparison below now covers CPU delivery
races. Typed directory/page/tail transport is now covered separately above;
their composition with the retained reader and mounted callbacks remains unverified. No host, archive, preferences, GUI or
real account is opened by this comparison. Manifests hash source, inputs, output
and toolchains. No visual, input, accessibility or native Linux gate is waived.

## Complete transcript projection

[chat/transcript.rs](src/chat/transcript.rs) and its child modules now port the
original display rows, full event coalescer, question-block stripping, bounded
tool snippets and legacy Muse tool metadata. Stable archive identities survive
prepending; legacy duplicate call IDs close the oldest running start. Edits
replace their tool row, approvals and question answers update existing cards,
steer preserves a turn, and tool/image provenance keeps its original provider.
The full detail remains copyable while display snippets keep the source's
60-line, 600-grapheme and 2,400-scalar bounds. Swift Character LF/CRLF behavior,
required nil/default distinctions and canonical String keys remain explicit.
Row equality compares all nested fields using Swift canonical String semantics,
with a byte-equal fast path for unchanged large tool output.

[transcript/auth.rs](src/chat/transcript/auth.rs) ports the original refusal
presentation and retry context. Only recognized agent refusals qualify; adjacent
prompt attachments can be retried, later response files cannot. Legacy Muse
challenges require the source's exact scheme/host, heading and confirmations.
The URL guard is presentation-only and opens no URL or sign-in flow. It is not a
transport authorization parser. Raw persisted rows are never changed.
[transcript/images.rs](src/chat/transcript/images.rs) groups adjacent images or
files explicitly attributed to the same tool and backend. Turn boundaries reset
that ownership; mere proximity never attaches a file to a tool.

[transcript/fold.rs](src/chat/transcript/fold.rs) ports all four original detail
passes and uses the existing application-menu `ChatDetail` type. Closed groups
retain their member/gallery anchors; opened members remain separate rows with
the original group/plain-step metadata. Minimal keeps live activity, preserves
unknown spend and saturates usage counts, and completed turn changes aggregate
canonical file paths across hidden edits. Raw rows remain separate for search
and caching; folding and authentication presentation do not rewrite history.

[linux-swiftui-transcript.py](../../scripts/tests/linux-swiftui-transcript.py)
executes the complete unchanged original coalescer/display/question/Muse/fold/
image/authentication declarations, full event/attachment/approval DTOs and actual
L10n against owned English bundle resources. All fields of raw, presented, image
and folded rows compare exactly, including nested state and equality. The corpus
covers 370 histories and 4,440 detail/open states, plus clipping, malformed and
streaming questions, Muse recovery, refusal classification, timing, preview and
canonical-equality cases. The harness manually serializes non-Codable display
rows and normalizes omitted nil fields; these are explicit test adapters. No
host, archive, real credentials or GUI is opened by this comparison. Portable
regressions cover ordering/provenance, stable prepend identities, edit replacement,
steer, questions, bounded full-copy output, galleries, group ownership, unknown
spend, turn changes, live activity, refusal input and nested row equality.

This is still an unmounted presentation foundation. The guarded worker and
atomic event/row publication described below now own its page commits; the
retained live-page owner below now consumes that API. Exact warm-row reflection
cost, markdown/text rendering, row controls, copying/selection, accessibility,
scroll/follow/restoration, native input, materials and pixels remain gates. The
actual retained ChatView/overview/toolbar/composer/status/setup/send/approval/
question/queue/steer/saved-copy/attachment owners are still being ported. Existing
Chat placeholders remain explicit. Source/data equality is not visual signoff.

## Guarded background publication

[chat/projector.rs](src/chat/projector.rs) now provides one serial CPU lane per
retained reader, using GPUI's shared BackgroundExecutor. Constructors are inert;
it creates no dedicated thread, host or store. A caller's cancellation/drop
retires only that work. The lane checks before and after coalescing and wakes a
registered foreground waiter. Explicit cancellation returns an owner-bound
completion so its matching progress flags can finish immediately. The actual
GPUI adapter has a development guard against running projection on the UI thread.

[chat/paging/publication.rs](src/chat/paging/publication.rs) replaces the earlier
raw-only completion path. A successful page/chunk receipt prepares immutable
shared snapshots and a guarded Work value; it cannot publish raw events alone.
The lane builds proposed raw events and rows off-thread. On return, the Window
checks instance, scope/helper, selection, replacement epoch and cursor ownership.
Newest/whole replacements reject a changed event revision. Tail/prepend work
rebases against the current window, and provider/running changes reproject with
current metadata. Only a valid result commits events and display rows together,
then advances cursors/usage/progress. Metadata-only work assigns no events and
equal canonical rows keep their existing storage. Its source guard follows the
selection and metadata ticket across a paging-epoch change; page transactions
still require their captured epoch/cursor. Event revisions follow source
assignments even for equal records; the display key follows the actual original
revision/count/sequence/backend/running fields. Scope retirement clears private
state while keeping revision history and model identity distinct.

Read/edit/publication tickets also retain the original model-instance ownership:
two readers with equal accounts, chat IDs and request numbers cannot consume one
another's result or clear each other's spinner. This models the original async
closure's implicit `self` ownership. New metadata work supersedes earlier
metadata tickets; switching a provider away and back cannot revive a cancelled
metadata operation. The existing Rename controller still needs its active reader.
The controller must explicitly return cancellation receipts and schedule metadata
refreshes as the original selected observer does; those view lifetimes are not
claimed by the lane API alone.

[linux-swiftui-publication.py](../../scripts/tests/linux-swiftui-publication.py)
compares 26 suspended traces / 99 checkpoints. It executes the complete unchanged
original publishEvents, events observer, commitDisplay/DisplayKey and newest/
earlier/tail methods against the actual original coalescer actor. A gate holds
already-computed delivery so valid response orders are reproducible; explicit
metadata/selection setup and secondary owners remain harness adapters. Every
held/committed raw event, full row, revision, cursor, progress flag and attempt
state compares exactly. The extractor preserves default closure arguments and
the complete function body. No backend/network/production store is involved.

```bash
python3 scripts/tests/linux-swiftui-publication.py --compare-gpui
```

The optional check builds and runs the real GPUI executor with synthetic Window
state and no opened window. It verifies the background-thread guard, forced registration/wake of the
foreground waiter, foreground resumption, atomic raw/row publication, metadata
supersession and cancellation.
Portable tests separately exercise actual worker threads, registered wakeups,
serial dispatch, queued/dropped/cancelled waiters, rebase/replacement behavior,
metadata changes and model-instance isolation. This is scheduling/state evidence
on the current host, with no Linux compositor, window/input/AX or pixel signoff.
Typed read flights now use the shared GPUI transport described above. Actual
full ChatView/model composition, warm-cache reflection cost, saved copies and
complete views remain open. The live-page transaction owner is described below.

## Retained opening and poll tasks

[chat/polling.rs](src/chat/polling.rs) and its [shared](src/chat/polling/shared.rs)
and [watcher](src/chat/polling/watcher.rs) modules now implement the original
opening owner, bounded read lane, exact watcher leases and cadence. They use
GPUI's existing foreground executor and background timer; constructors start no
work and create no per-reader thread, socket, archive or store. Explicit Rust
cooperative cancellation represents the original ambient Task cancellation.

Opening is lazy and same-owner callers await one producer. Dropping a waiter,
even the last waiter, cannot cancel that producer. A changed owner cooperatively
cancels the old operation; old cleanup cannot clear its successor. Poll lanes
keep the original operation and one in-flight read. Refreshes retire its current
publication permission and request one fresh pass after that operation ends.
Revision capture happens when the pass actually starts, so a refresh burst before
scheduling does not invent an extra read. Wrong-owner cancellation leaves the
current lane alone. Event, status and approval lanes remain independent.

Watcher enrollment is lazy, with an exact lease per view lifetime. The last
release stops the current loop once and resumes its waiters. Owner displacement
resumes old waiters without allowing their later cancellation or cycle completion
to stop the successor. Cancellation interrupts the actual timer; it does not wait
out a quiet interval. The awaited watcher keeps its original self lifetime, and
queued release retains it until cleanup runs. A started poll task also retains
its lane through a suspended operation, matching the original weak-to-strong
promotion. Dropping an owner handle is distinct from explicit cancellation.

The cadence preserves the exact 120/180/260/400ms busy/quiet progression, 2s idle
interval, 400/800/1600/2000ms failure backoff, 1.2s progress window and independent
one-second status/approval claims. The unchanged original policy compares in
88 traces / 2,964 checkpoints, including adjacent representable clock values.
Clock fixture arguments are decimal strings parsed directly by each language;
the comparison checks exact IEEE bits as well as results. This explicitly avoids
an incidental JSON-number parser rounding a test boundary. No tolerance or host
wire/decoder change was introduced.

```bash
python3 scripts/tests/linux-swiftui-polling.py --compare-gpui
```

This compiles the complete unchanged original ChatPolling.swift beside its actual
suspended-task tests, now including opening sharing and retained owner lifetimes.
The optional actual GPUI executor checks shared opening, waiter drop, producer
cancellation, refresh bursts, successor protection, exact watcher leases, retained
owners, a real timer cycle and foreground resumption. Portable scheduler tests
also inspect cancellation of timers and complete draining of held tasks. These
are complementary async assertions plus strict cadence data comparisons, not
execution of the complete ChatModel or a mounted view.

The retained reader must still connect these owners to typed transport and
Window/Lane publication. Operation closures must check Cancellation/Permit at the
original boundaries, including after IO and CPU delivery, and perform the exact
progress cleanup. A lane alone cannot grant publication or restore a send context.
The awaitable transport adapter below now preserves cooperative cancellation
completion timing: the original read-flight waiter checks cancellation after
its own shared producer answers, before deciding whether to retry. Full
selected/load/reveal/helper adoption, metadata observation, warm caches,
status/approval/attachment operations, saved copies and every ChatView/composer/
menu/scroll/follow/input owner remain mandatory. Existing Chat placeholders and
all native Linux/visual/accessibility/system acceptance gates remain open.

## Awaited transport and retained live pages

[chat/transport.rs](src/chat/transport.rs) now supplies lazy read_async on the
same pool as callback directories. Cancelled async consumers remain attached to
their own producer until it answers; unrelated completions cannot finish them.
Cancellation is checked before an invalidation retry and before either result
branch is delivered. An abandoned future retires only its own lease, keeping
shared producers and successors alive. Callback-only consumers retain their
existing immediate release behavior. Cancellation and bridge-owner retirement
are distinct typed outcomes, with no invented remote failure or error-copy match.
A poll refresh also differs from task cancellation: Permit.cancellation() is the
RPC guard, while Permit.allows() controls the original publication boundaries.

[chat/reader.rs](src/chat/reader.rs) now owns retained GPUI live-page transactions.
It composes the shared opening owner, awaited transport, Window and its serial
background projection lane. Constructor/selection changes start no polling or
transcript IO. Explicit opens share one operation; older pages and tails retain
independent exact read tickets. Page/whole failures use the existing source
fallbacks. A tail reset enters the shared opening wrapper BEFORE allocating a
replacement, so another opening caller joins the same page; a reset whole
fallback finishes and can recover on the next read without recursion/deadlock.

The selected-metadata observer cancels its previous task and projects only when
backend/running changes. Its task snapshots at actual execution rather than at
observer enqueue time, including a page making that same selection empty. Rapid
provider changes cannot revive cancelled work. Metadata-only projection assigns
no raw records or displayed send-context acknowledgment. No-op tail cursor
rotation does not notify/invalidate the reader. Render-visible progress, context,
errors and committed event/display revisions do notify. Raw events and rows
remain atomic, with non-rebasing replacements and source rebase retries.

Transactions and metadata tasks retain the original self lifetime through their
suspended work. Returned history/tail waiters do not own the producer; their
explicit Cancellation represents the original task's cooperative cancellation.
Source defers finish at actual RPC/CPU completion, not when another query or
window ends. Scope/selection/instance guards protect successors. A required global
reading-scope provider is independent of helper generation and is checked at read
and pre/post-CPU boundaries. Higher-level scope changes still need to retire the
private model as in the original app; this provider is not that cleanup owner.

The native --compare-gpui mode of linux-swiftui-chat-mutations.py now executes
actual retained Reader entities, not just direct Window adapters. It checks two
independent readers sharing one opening RPC, overlap/prepend/tail preservation,
selected metadata and rapid cancellation, same-owner reset/open sharing, deferred
history cleanup, no-op notification suppression, stale selection/progress fences,
retained self, finite legacy fallback/recovery and reading-scope retirement. The
original actor tests additionally assert cancellation stays pending across an
unrelated producer and prevents invalidation retry. All resources are owned and
synthetic; no product window, archive, account or production store is opened.

This is a live-page owner, not the full ChatModel or mounted ChatView. It now
keeps verified rows across a same-scope helper generation change, validates new
metadata ownership, and uses current bridge context for an interrupted opening
page's whole-history fallback. Native fake-host checks hold old replies across
generation changes, including a second change during a quiet fallback, and
verify later tail and earlier-page retries. For an encoded remote folder, the
reader accepts a current helper with a different local identity because the
conversation belongs to the folder's peer; it still rejects another scope,
stale generation or different metadata folder. A local folder conservatively
requires its captured local identity. The Swift session resolves its local
identity once; the complete model's identity lifecycle still needs validation.
The reader currently accepts encoded desktop remote folders, not a separate
explicit peer argument. Full helper adoption and recovery remain open:
nonquiet tail/whole cancellation copy, CPU and metadata interleavings,
status/approval/attachment and cache owners, identity lifecycle and the complete
load/reveal/selection orchestration still need source-matched interleaving tests.
Full canonical Conversation equality, load/select/
reveal/restore, recent rows/warming, source effects and progress wrappers, full
status/approval/attachment polling, drafts/queue/composer/send/saved copies and
all view/menu/scroll/follow/input owners remain required. Existing product Chat
placeholders and every native Linux/visual/accessibility/system gate remain open.

## Native confirmation content and input

The original `RemoveWorkspaceConfirm` is now measured through its actual native
sheet, rather than approximated from an app-owned task sheet. On the current
macOS reference it has no icon, a 260-point content width, 13-point native
bold/regular title/message, 20-point text insets, a 10-point title gap and two
110×28-point buttons with an 8-point gap and 16-point footer insets. The regular
glass corner radius is 26 points. Height is 138 for the standard message, 186
for the long name and 154 for Unicode/multiline names. Runtime OS/SDK/compiler,
colours, frames, input hashes and callback evidence are recorded; these are not
universal claims about every macOS version or preference configuration.

SwiftUI reorders the declared actions visually: Keep it on the left, destructive
Remove on the right. Cancel has the Escape key equivalent and is the configured
initial responder. There is no Return default. Native Return checks, including
direct dispatch after focusing each button, do not remove or dismiss. Native
Escape and explicit Remove callbacks are checked against inert fixture state;
they never call a host. `confirmation.rs` retains these roles and completion
rules. The GPUI view adds trapped Tab/Shift-Tab/arrow focus and Space activation;
real active keyboard behavior and platform accessibility remain acceptance gates.

The desktop retains an immutable project target and a per-opening ticket.
Closing/choosing removes the pending dialog once; stale delivery cannot act on
a later confirmation. Focus restoration is deferred to the owning window's
next render instead of attempting a nested update during event dispatch. The
overlay consumes parent pointer input and outside clicks do not dismiss.
Keyboard Return cannot implicitly select the destructive action. Parent window
decoration, global-command interaction and native focus restoration still need
runtime acceptance.

`scripts/tests/linux-swiftui-confirmations.py --compare-gpui` compiles the
original SwiftUI view with only a small in-memory folder/binding/callback owner.
Transparent reference windows are configured before presentation, remain
inactive and assert zero alpha. Eight short/long/Unicode/multiline cases in both
appearances check roles, key equivalents, focused Return and response lifetime.
The `confirmation-contract` example draws the actual GPUI component without
presenting its window, measuring real panel/title/message/button bounds. All
eight currently match native relative frames exactly, including text wrapping;
the comparator applies no rounding or tolerance. Content bitmaps are 2× and
explicitly omit the separate system glass compositor.

The source's native system material, shadow, vibrancy/colour composition,
baseline/glyph rendering, active focus and input have no pixel signoff. Current
GPUI semantic flat fills and focus ring are provisional. The initial offscreen
source probe was ordered onscreen by AppKit despite its requested coordinates;
it closed, and subsequent probes use transparent parent/sheet/glass windows.
No real tokenstat window, preferences, host, registry or folder was involved.
Project removal remains incomplete until those native and wider owner gates
are resolved. Existing full-screen and real Linux gates still apply.
