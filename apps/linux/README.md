<!-- SPDX-License-Identifier: LicenseRef-tokenstat-source-available -->

# Linux desktop feasibility build

A GPUI client of the existing Rust host daemon. The required product is a
visual and behavioral port of the SwiftUI desktop, including every menu and
state. [The parity contract](PARITY.md) governs all GUI work. The
[surface ledger](SURFACES.md) records root routes/presenters and remaining
feature/menu audits. A similar-looking
redesign or reduced feature set does not meet the requirement.

The separate `--probe-ui` transport/rendering experiment has Home,
Insights and Host views, local usage reports, Refresh, Scan logs, and offline
recovery. Reads and scans run away from the UI thread. A failed refresh keeps
the previous reading and labels it stale.

The experiment is not the target interface. It is not a Linux release or a claim of
desktop feature parity. Linux graphics, input, accessibility and distribution
acceptance must pass on real Linux machines before release.

`--desktop-preview` mounts the partial SwiftUI shell port: the nine-destination
rail, repository sidebar, pane controls, source logo and initial Home identity
and activity cards, plus linked-device rows from the account snapshot. Customize Home now edits a discardable arrangement with
presets, visibility, ordering and reset/undo; Done saves the device preference
off the UI thread. Usage figures read the delivered calendar. Vendor quota and
archive subscription-usage panels load separately and keep stale readings on
failure. The calendar uses the shared host's rows, levels, scope and
streaks, with initial pointer hover/day selection, day-detail hover card and
pinned inspector breakdowns. `--shell-fixture` uses
synthetic data and never opens a host socket or
archive. Its synthetic repository and conversation rows let the repository/chat
switch, filter, sort menu and grouped timeline be exercised on macOS. The
connected preview uses the same initial sidebar controls and sequentially reads
project chat directories. These controls still require real Linux input,
accessibility and visual acceptance, and some source actions remain unported.
The fixture also exposes the Linux menu surface on macOS for input checks.
Feature contents and many commands remain visibly unported. Neither mode is
a complete desktop, a visual-parity signoff or a stable download.

## Architecture

GPUI renders the interface. `tokenstat-hostd` owns the archive, identity,
terminals, agent processes, remote access and every business method. The app
uses its existing Unix socket protocol and the shared bounded JSON framing.
It holds the same shared owner lock as the other desktop clients. It never
opens an independent archive or embeds a second host.

GPUI is compiled Rust with custom controls. It does not use GTK or Qt widgets.
The exact `0.2.2` dependency and lockfile make this initial experiment
reproducible. Evaluate a newer pinned upstream revision for production input
and accessibility support. Do not treat current upstream capabilities as
capabilities of this published version.

The standalone Cargo workspace keeps the feasibility dependency graph out of
the shipping clients. Both privacy and dependency licence checks still apply.
The app and the root workspace share source crates, not a copied backend.

## Build and test

Use the repository's pinned Rust toolchain. On Linux, install the development
headers for fontconfig, FreeType, xkbcommon, X11/XCB and Wayland, plus Clang,
pkg-config, a C/C++ compiler and Vulkan drivers. Exact distro package lists and
the oldest supported runtime are part of Linux-machine validation.

```sh
cargo test --manifest-path apps/linux/Cargo.toml --no-default-features --lib --locked
bash scripts/prepare-linux-fonts.sh
cargo clippy --manifest-path apps/linux/Cargo.toml --all-targets --locked -- -D warnings
bash scripts/check-dep-licences.sh --manifest-path apps/linux/Cargo.toml --locked
bash scripts/check-no-network.sh
cargo build --manifest-path apps/linux/Cargo.toml --locked
apps/linux/target/debug/tokenstat-linux --shell-fixture
```

Font preparation uses Python 3.11+ and a hash-pinned, build-only FontTools wheel
in an isolated `target/` environment. Cargo never installs Python packages or
downloads fonts. The GUI build
derives static 400/500/600/700-weight faces from the existing Manrope and
JetBrains Mono sources into Cargo's output directory, and checks their weight
metadata before embedding them. No generated font is tracked, no font is
installed into the system, and Python is not a runtime dependency. Both
original OFL notices accompany the bundle. This avoids GPUI 0.2.2's macOS
memory-font path selecting the default variable instance for every weight.

The design and route declarations are extracted from the current SwiftUI
source during the Rust build. This needs the source checkout, but does not
need a Swift compiler on Linux. Unsupported declaration changes fail the
build so the port can be reviewed instead of silently keeping old values.

On macOS, compare the Rust models with compiled SwiftUI definitions:

```sh
python3 scripts/tests/linux-swiftui-contract.py
```

This checks the rail and route metadata, 19 colour roles, shared
metrics, 378 layout inputs, sidebar transitions, 16 account-menu states, action
glyph names and text interpolation. It executes extracted original Swift
logic with synthetic state and does not call an account or a running host.
It does not verify rendered layout, glyph shapes, menu input or Linux runtime
behavior. The separate `linux desktop contracts` workflow runs the portable
checks on Linux/macOS and the compiled reference comparison on macOS.
Portable menu tests also compare the app-owned command labels and shortcuts,
all chat-detail options and the default level with the current Swift sources.
The compiled reference also compares Home's heatmap layout/hit testing, heat
palette, scope/subtitle copy, greeting and currency boundaries, plus 26 actual
SwiftUI line-box measurements with both bundled font families registered.
These are specific source/size checks, not full-screen pixel comparisons.
Day checks cover 90 popover placements, 15 inspector breakdowns, signed money
qualifiers, token boundaries, model labels and tool names/brand aliases using
the actual Swift declarations. The initial day inspector and hover card use
the existing host methods; independent request/scope and fake-socket tests
cover cancellation, stale replies and partial local breakdown failures.
Rendered pointer coverage, exact day-card appearance, and the destination
Insights query remain unfinished. See [PARITY.md](PARITY.md).

Home arrangement checks compare the original desktop Swift source for all six
sections/three presets, 256 stored layouts and 144 full/visible-list moves.
Plan checks compare 80 quota labels/percentages, 84 provider visibility/stale/
reset cases, severity colours, provider order, 56 grid widths/counts, nullable
cache defaults, plan title capitalization and four calendar figure cases.
The shared quota store is separate from Home's loading state. It compares 22
checkpoints with the original asynchronous Swift store, including shared
waiters, cancellation, the 30-second attempt throttle, late owner/settings
replies and stale retention. Another 23 transitions compare the original
login/helper lifetime update method. The runtime feeds accepted account-status
replies into this owner gate and retires older Home/calendar/day deliveries.
Account errors retain the verified identity; older cross-window status replies
cannot restore an earlier login.
Each window registers an independent Home reader for archive rows, errors,
loading and the successful-load throttle. Closing or hiding one reader cannot
cancel another window's shared vendor request; reader removal also retires its
pending deliveries. The device arrangement and vendor readings remain shared,
matching the source's per-window `HomeModel` and shared `PlanLimitsStore`.
Device checks compare 438 record/label/status/icon/identity cases and six
selection/rename/removal cases with the original bridge model, Home row
expressions, icon helper and Devices selection methods. Rows retain a device
key for navigation; the destination Devices screen and inspector remain
unported. The Home card still needs pixel, focus, keyboard and pointer review.
Continue and Pinned work now have initial GPUI cards and offline fixtures.
The identifier-only projection reads supplied directory/chat/access/cache facts
without loading transcripts or contacting peers. It compares 864 availability
states, 54 folder routes and 28 row/open scenarios against original Swift
methods, including revoked access, removed machines and ended terminals.
Durable continuity/pin codecs and disk preferences now exist under `src/work/`.
They preserve source limits, key/label validation, account origins, Codable Date
envelopes and safe local/remote restoration. Disk mutations lock, reread current
storage and replace it atomically, preserving unknown fields. Tests cover
competing file handles, private modes, symlinks and malformed-container refusal.
The compiled reference compares 198 account-origin cases, 45 identifier keys,
37 Unicode labels and eleven traces through the original stores using private
in-memory defaults. No live Mac preferences are used by those store checks.
Connected previews now bootstrap the local installation and scoped metadata on
a serialized worker lane, resolve the existing `machine.identity` public key,
and project shared pins/visits against each window's loaded local directory.
Project-menu pin creation and Home/menu unpin persist locally and update all
windows. Deliberate navigation records
the source place shape. Retired account reads cannot publish, and a helper
restart retains the same scope's verified metadata while fencing old replies.
The Linux files are `config_dir()/desktop-work.json` and `desktop-home.json`.
An absolute `TOKENSTAT_DATA_DIR` instead isolates both below
`desktop-preferences` in that directory. macOS previews and component fixtures
remain ephemeral. The loaded local conversation catalog now includes draft-aware
emptiness facts. Full chat/peer/access/saved/terminal feeds and full
destinations are still unported. Fixture pin changes use the real validation
and capacity rules against private memory; they never change retention.

The initial project row now has source-sized disclosure/hover controls,
Shift-to-remove presentation and an ellipsis/right-click menu. Row selection
and New terminal open Sessions, as the source opens its launcher rather than
starting a shell. Connected local Reveal uses GPUI's platform file manager
adapter; synthetic rows never open real folders. Pin/Unpin retain the reference,
labels and opening-time operation. The compiled reference compares 1,536
complete project/row/pin menu states and 72 original pin-reference cases,
including missing identity, remote IDs, capacity, sharing, staleness and git.
Unknown sharing/git/remote directory owners are not fabricated by the preview.
Project and Projects-section disclosures now persist through the shared GUI
preference worker. Known rows keep each window's choice; returning projects read
their saved choice, and a late read cannot reverse a click. Writes preserve
unknown fields and survive account changes/window closure. Failed writes retain
the choice and surface an error until the same key is saved successfully.
The original SidebarPreferences class and RootView setters/arrival expressions
compare in 63 traces and 1,701 checkpoints. History/server preference queries
and section-order storage are ported. Conversation history now has the initial
owner described below; server/section-order controls, full project children,
native first paint, input and accessibility remain unfinished.

Expanded projects now read title-only conversation directories through the shared
host, with per-window caches and shared simultaneous reads. The initial children
include source five/ten-row windows, held hover order, history expansion, ages,
independent running clocks, selection and captured pin/unpin menus. Loading,
retry and verified empty states stay distinct. Draft presence and the separate
pencil mark now use the private store described below; a pending initial read
retains a possibly untouched row. Initial conversation rename now uses the same
sheet as project rename, captured project routing and local pin-title updates.
Initial Fork copies through the owning host and reveals the result only while
the original route is current. Full chat reading, delete/details/previews, terminal/job children and native
acceptance remain open.
The original source compares 128 chat menus and the list/state rules separately.

```bash
cargo run --manifest-path apps/linux/Cargo.toml --example component-preview -- project children-ready-dark
python3 scripts/tests/linux-swiftui-chats.py
python3 scripts/tests/linux-swiftui-chat-mutations.py
cargo run --manifest-path apps/linux/Cargo.toml --example component-preview -- project rename-chat-ready-dark
```

The shared directory reader now invalidates at both mutation boundaries and
retries obsolete successes and failures. Cancellation retires only the waiter;
an older producer cannot erase a newer sharing slot. Each window reconciles
older lists with completed changes, then lets fresh host state supersede them.
Pending notes retain their own acceptance revision, including identical words,
and metadata replies preserve the note rather than treating absence as removal.
The compiled original owners compare in 34 traces / 616 checkpoints; original
read-actor tests and Rust owner/fake-socket checks cover cancellation, account,
peer and parameter isolation. Directory reads, rename and fork are wired; other
read methods, send/delete and the mounted active reader remain unported. Typed
directory/page/tail identities and one actual GPUI shared transport are now
available, with immutable worker-decoded replies and exact waiter leases. The
sidebar uses this pool; product timeline IO awaits the retained reader owner.
`python3 scripts/tests/linux-swiftui-chat-mutations.py --compare-gpui` exercises
it against an owned temporary host with no product window, archive or account.
Coded and legacy refusals preserve the original paging-fallback classification;
transport/decoding failures stay distinct. Cancellation and entity release also
work during a batch of completed deliveries.
Full wire records and an initial page-window foundation now have the original-
source comparison described below. Rename has ready/empty/error/saving/retry
fixtures in both themes, with original SwiftUI references. Native sheet chrome,
focus, input, accessibility and same-state GPUI pixels remain open.

The unmounted reader foundation now decodes full private conversation, event,
approval, routing and page records and retains the original bounded warm-row
cache. The page-window owner guards selection/cursor/trim races and preserves
send-context acknowledgment. It does not yet mount a transcript, composer,
background preview warmer or saved-copy reader. Existing directory warming
continues to read only `chat.list`.

```bash
python3 scripts/tests/linux-swiftui-reader.py
```

The unchanged original code compares 1,480 wire cases, 220 warm-row checkpoints,
343 context revisions and 123 newest/earlier/tail checkpoints. Exact numeric
comparison, synthetic inputs and explicit inert adapters keep the scope clear;
this is state evidence, with every native GUI/Linux gate still open. See
[PARITY.md](PARITY.md#reader-records-and-initial-page-window).

The complete pure transcript projection now follows the original coalescer,
four detail folds, image provenance and sign-in refusal presentation. It uses
the existing menu's ChatDetail identity and preserves every nested row field and
stable anchor. The original unchanged Swift code compares 370 histories and
4,440 detail/open states, plus metadata, Unicode/clipping and recovery cases.

```bash
python3 scripts/tests/linux-swiftui-transcript.py
```

The Window now commits through a guarded serial background projection lane,
with an actual GPUI executor check. The live-page transaction owner now consumes it; full model composition and
actual row, markdown, toolbar and composer views still need connection and
visual verification. See [transcript projection](PARITY.md#complete-transcript-projection).

The publication API now keeps raw events and rows together, rejects stale
replacement results and rebases tail/prepend work. Cancellation, metadata changes,
model isolation and foreground wakeups have dedicated worker tests. The original
Swift publication/page bodies compare in 26 suspended traces / 99 checkpoints.

```bash
python3 scripts/tests/linux-swiftui-publication.py --compare-gpui
```

This exercises the actual GPUI background/foreground scheduler with no window,
host or store. It does not grant native Linux or visual/input acceptance; see
[guarded publication](PARITY.md#guarded-background-publication).

The original opening/polling task owners now have retained Rust implementations
under `chat/polling.rs`, using GPUI foreground tasks and cancellable background
timers. Shared openings, bounded refreshes, exact view leases, independent lanes
and the original cadence are checked with suspended operations. The unchanged
original Swift policy compares in 88 traces / 2,964 checkpoints with exact clock
bits; actual GPUI task/timer checks open no window, host or store.

```bash
python3 scripts/tests/linux-swiftui-polling.py --compare-gpui
```

The full retained model still needs to connect these owners to the complete
original ChatView. See
[retained tasks](PARITY.md#retained-opening-and-poll-tasks).

The retained live-page owner now lives in `chat/reader.rs`. It connects shared
opening, awaited RPCs, selected-metadata observation and serial background
publication in actual GPUI entities. Cancellation waits for its own producer,
reset tails share the next opening, no-op tails avoid invalidation, and stale
selection replies cannot clear a successor's progress. The native transport
check above exercises these paths against a temporary fake host.

This owner is unmounted in the product. Full ChatModel/load/reveal/cache/status/
approval/composer/view integration and helper adoption remain open. An
interrupted opening now keeps verified rows and falls back through the current
same-scope helper. Synthetic checks also cover a second generation change during
a quiet fallback and later page retries. Remote folders retain their peer
identity even if the local helper identity changes; full helper recovery and
identity lifecycle integration remain open.
See [retained live pages](PARITY.md#awaited-transport-and-retained-live-pages).

Home's confirmed-empty Activity state now has an initial Getting Started card
and can request the first scan from the shared host. Eight synthetic state
combinations compare with the original SwiftUI card. Its scan now waits for a
guarded Insights snapshot before notifying Home; the original scan control flow
is compared with suspended synthetic responses. Sign-in, the complete Insights
model and screen, animated details and visual/input acceptance remain open;
see [Home parity](PARITY.md#initial-home-arrangement-and-plan-panels).

The initial All devices Insights route uses the per-account, per-cut host
report and provides cut selection, search, refresh, rows and a basic chart.
Its suspended ownership behavior is compared with the original model. Chart
styling, locale-sensitive search and native interactions remain unverified;
the This device Insights screen is still unported.

Fork keeps per-row copying/error lifetimes, disables duplicate copy/Delete/Shift
controls, and preserves the original route-equality rule when opening a copy.
Remote protocol 26 is checked before a mutation; an old or unreadable peer gets
the original update-computer message. The complete original task, bridge/model
methods and root callback compare in 192 synthetic outcomes, including failures,
navigation, disappearing rows and account changes. Swift route equality/hash
also exposed and corrected a canonical-Unicode difference in the Rust routes.

The actual fork failure alert uses one OK button with the cancel role and Escape
binding, with no implicit Return default. Ten native source cases and real hidden
GPUI frames match in copy, roles, wrapping and content geometry. Raw native
captures contain transparency; labelled flat previews aid inspection and do not
include native glass. Native material, active focus, Linux input/AX and pixels
remain acceptance gates.

```bash
python3 scripts/tests/linux-swiftui-fork.py
python3 scripts/tests/linux-swiftui-chat-alerts.py --compare-gpui
cargo run --manifest-path apps/linux/Cargo.toml --example component-preview -- project children-copying-dark
cargo run --manifest-path apps/linux/Cargo.toml --example component-preview -- project fork-error-unsupported-dark
```

Unsent writing has its own non-evicting store in `src/drafts/`, outside GUI
preferences. Connected Linux previews use `data_dir()/desktop-drafts`; macOS
previews use private memory, and offline fixtures perform no draft file IO.
The source-compatible records preserve message IDs, attachment metadata,
conditional send clearing, account/host/conversation separation, failed pending
edits and deletions, and the 8 MiB limit. Writes merge against the current file
under a persistent POSIX record lock, then atomically replace and synchronize
the private file. Only mark membership changes notify the small row entity;
editing an already marked draft does not rebuild the surrounding list.

`python3 scripts/tests/linux-swiftui-drafts.py` compiles the complete original
Swift draft store and original-file coordinator against temporary directories.
It compares 14 traces / 97 checkpoints, including attachment protection,
damaged-file recovery, Unicode,
queued changes, legacy IDs and quota-sensitive date encoding. Independent Swift
and Rust writers retain all 50 records; both reopen them. Two-way process checks
refuse live original-file participants and release/prune terminated ones. This is
storage evidence. The composer/send/attachment UI and original-file retention
removal owner remain unported; native pixels, focus and accessibility remain open.

Other child fixtures are empty, loading, failed, expanded, selected-tail, hover,
shift, held, decorated and copying, each with a light/dark suffix. They share inert data
with 22 original SwiftUI references and never receive a client or owner lease.
The reference manifest records source/font/asset/fixture hashes and environment.
These images do not verify GPUI pixels or Linux input/accessibility.
Local rename now has the source-shaped name sheet, save/error/retry states,
scope-gated reload and pin-label refresh without re-pinning removed shortcuts.
Local removal has confirmation, source routing, directory reload and selection
fallback. The compiled original removal method matches 504 dirty/local/remote/
failure/selection traces; fake sockets check actual RPC fields and acknowledgements.
Remote directory ownership, the actual unsaved-document close dialog, tab/editor
cleanup, saved work, sharing, disconnect, new chat, worktrees and chat deletion
remain explicit gaps. Project removal now uses an app-owned confirmation in
place of GPUI's generic Linux fallback. Its visual button order, roles,
Escape/Return behavior and content frames follow measured native SwiftUI
references. System glass/shadow/composited colours, active focus, accessibility
and real Linux input/pixels remain unaccepted. Expansion children, hover
cards, middle truncation, selected glyph variants, focus/AX, native popup
geometry and same-state Linux pixels/input still need implementation or
acceptance. The menu is not complete while those actions remain unported.
Portable tests cover draft/reset behavior, atomic preference persistence and
malformed-file preservation, cache freshness, disabled providers, stale/error
readings, retired generations and isolated fake-socket RPCs. No real vendor,
account, host or archive is used by these checks.

These Home panels and the editor still need rendered and native input checks.
Relative quota time currently has English-only provisional formatting; full
locale/calendar behavior, Account/composer UI and settings-event wiring and
credential/sync suggestions remain unported. Continue, pins, the full Devices flow
and Getting started are incomplete. Do not treat a passing source comparison
as visual or complete Home acceptance.

The owner projection consumes normalized API origins from the existing host.
It is an in-process lifetime gate using the work scope canonicalizer. Durable
saved access and full Account authentication remain unported.
The Swift comparison uses
injected readers and inert saved-access adapters; it does not touch preferences
or verify those wider subsystems. The work reference DTO and pure folder
resolver do not establish saved-copy access. The service reads the saved launch
record and default-off restoration preference, but it does not apply a late
navigation jump. The original splash/deadline/external-navigation ordering and
Startup settings UI still need porting. Normal menu quit and last-window close
give queued preference writes up to five seconds to drain, and wait for all
accepted draft operations without that preference timeout. Failed draft writes
remain failed in memory as in Swift; composer recovery still needs its UI.
Platform session
termination and force-stop behavior remain native acceptance gates.

Fixed-size day fixtures also render the actual GPUI inspector/popover code
without a host, archive or owner lock:

```sh
cargo run --manifest-path apps/linux/Cargo.toml -- --day-fixture inspector-ready-dark
cargo run --manifest-path apps/linux/Cargo.toml -- --home-fixture machines-ready-dark
cargo run --manifest-path apps/linux/Cargo.toml -- --home-fixture continue-ready-dark
cargo run --manifest-path apps/linux/Cargo.toml -- --home-fixture pinned-ready-light
python3 scripts/tests/linux-swiftui-render.py --compare-gpui-fonts
```

Inspector states are `ready`, `empty`, `loading`, `locked`, and `no-selection`;
popover states are `ready` and `loading`. Home device states are `machines-ready`
and `machines-empty`. `continue-ready`/`continue-empty` and
`pinned-ready`/`pinned-empty` use 400×360 point frames. Every name ends in `-light` or
`-dark`. The reference script requires macOS and Xcode command-line tools. It
compiles the original SwiftUI views and shared SVG catalogs into a test
harness, then renders 46 PNGs in hidden windows. The output under
`target/linux-day-visuals/` includes dimensions, hashes, locale/environment and
synthetic inputs. These images are reference evidence, not approved goldens.

Offline rename components use the native example executable:

```sh
cargo run --manifest-path apps/linux/Cargo.toml --example component-preview -- project rename-ready-dark
cargo run --manifest-path apps/linux/Cargo.toml --example component-preview -- project remove-ready-dark
python3 scripts/tests/linux-swiftui-confirmations.py --compare-gpui
```

States are `rename-ready`, `rename-empty`, `rename-error`, `rename-saving` and
`rename-retry`, each with a `-light` or `-dark` suffix. Frames are 460×250 points,
or 460×300 with an error, including during retry. They mount the actual field
and sheet without a client/host owner. The text field implements UTF-16 IME
range conversion, marked replacements, selection, clipboard, undo/redo and
horizontal scrolling. Its native keyboard, composition, candidate placement,
AX, focus and rendered Linux acceptance remain open.

Removal fixtures are `remove-ready`, `remove-long`, `remove-unicode`,
`remove-multiline`, `remove-focus-cancel` and `remove-focus-action`, each with
the same appearance suffix. Native content is 260 points wide, with height
138/186/154 for the measured message variants. The confirmation reference script
runs the original SwiftUI view in transparent, inactive owned windows. It checks
actual native roles, Return key equivalents, focused Return and cancel/remove
callbacks. `--compare-gpui` draws the real GPUI component in a hidden window and
compares exact panel/title/message/button frames, including wrapping, for eight
cases. The native content-only images omit AppKit's separate glass compositor;
these checks do not establish pixel, material, active-focus or Linux acceptance.

After preparing the GPUI fonts, `--compare-gpui-fonts` additionally checks
hidden-window rounded intrinsic widths and line boxes. The original mismatch
was a macOS face-selection error: GPUI/font-kit treated AppKit Medium's 0.23
trait as CSS 530, so a request for 500 selected Regular. The adapter corrects
that face selection on macOS while retaining logical CSS weights on Linux.
All 149 current measurement cases pass on the measured Mac, covering four
native weights, five sizes and Latin, Greek, Arabic, CJK and emoji samples,
alongside the bundled-face cases. `font-comparison.json` records the result.
The proposed macOS CI step now runs this strict comparison. Baselines,
subpixel glyph appearance, full-screen pixels and Linux font availability/
shaping remain open gates.

`examples/component-preview.rs` is a native offline fixture executable, useful
for an isolated test bundle without a shell wrapper. Its default is the dark
device card; `home NAME` and `day NAME` choose other fixtures. Invalid names
are rejected before GUI/host setup. The current native capture tool still
returns `cgWindowNotFound` for the owned fixture, so it has no visual signoff.

On Linux, the app connects to the existing host first. If it is offline, it
starts an installed user service, or the sibling `tokenstat-hostd` binary.
It does not enable a service, lingering, remote serving or peer access.
Concurrent startup requests for the same socket in this desktop process share
the attempt and its failure; a later request can retry. Requests for another
socket do not have to wait for it. Calls to the user service manager have a
deadline; a timed-out request reports that the host may still be starting
instead of starting a second host. A managed start is queued without waiting
for the service job, then the desktop waits for the socket.
An unmanaged host appends logs under
`${XDG_STATE_HOME:-~/.local/state}/tokenstat/` and rotates the previous file
at startup when it exceeds 5 MiB. Continuous log-size limits remain open.

```sh
scripts/build-linux-app.sh
```

The script produces a private development directory in `dist/`, including the
GUI, same-source host, desktop entry, user service, icon, licence and notices.
It does not install, start, publish or enable anything. The staged desktop and
service paths target `/usr/bin` for package preparation.
The desktop entry is a packaging template until the parity UI is ready.
Run `bin/tokenstat-desktop --probe-ui` explicitly to open the experiment.

## Isolated preview on macOS

The offline shell can also be started directly after the build, with synthetic
content and no host or archive access:

```sh
apps/linux/target/debug/tokenstat-linux --shell-fixture
```


macOS is only a preview environment for this client. Use separate data and
identity directories for the test daemon. The app requires an explicit socket
and `--no-spawn` on macOS so it cannot launch a second host against the normal
archive. This command prints options without opening a connection:

```sh
apps/linux/target/debug/tokenstat-linux --help
```

With an isolated daemon already running, use its socket for either a native
window or the headless diagnostic:

```sh
apps/linux/target/debug/tokenstat-linux --probe-ui --socket /path/to/test/host.sock --no-spawn
apps/linux/target/debug/tokenstat-linux --desktop-preview --socket /path/to/test/host.sock --no-spawn
apps/linux/target/debug/tokenstat-linux --socket /path/to/test/host.sock --no-spawn --doctor
```

Set `TOKENSTAT_DATA_DIR` and `TOKENSTAT_IDENTITY_DIR` to the same isolated roots
for both processes. Custom sockets alone do not isolate an identity.

## Desktop integration staging

The headless build can generate reviewable files without a GPU or a running
daemon. Executable paths are escaped separately for desktop entries and
systemd. No shell evaluates them.

```sh
cargo run --manifest-path apps/linux/Cargo.toml --no-default-features -- \
  --stage-integration target/linux-integration --installed-bin /usr/bin
```

The generated service uses `Restart=on-failure`, which allows the host to exit
cleanly when Always-on is off and the last window closes. It inherits the user
service manager's file limits instead of requesting a fixed hard limit, which a
user service may be unable to set. The existing host raises its own soft limit
within the inherited hard ceiling, and the Host view reports the measured
values. No system-wide limits, sysctl, PAM or shell profiles are changed.

Do not use `tokenstat host install` as a desktop installer. That command is the
deliberate headless always-on path and also enables remote serving and lingering.

## Acceptance goals

| Goal | Acceptance |
| --- | --- |
| SwiftUI parity | Identical app layout, all routes, menus, toolbar actions, dialogs and interaction states, verified against the SwiftUI source and reference captures |
| GUI feasibility | Native Linux build, Wayland and X11, real host reports, responsive errors and recovery |
| Host lifecycle | One identity owner, reconnect, app close/crash, user-service coexistence, optional Always-on |
| Resource and power integration | Low descriptor ceilings, child shell compatibility, inotify/task diagnostics, battery/lid and suspend/resume |
| Desktop integration | XDG directories, icon/app ID, optional login startup, portals, notifications, keyring, single-window activation |
| Feature parity | Projects and terminals, then chats, devices/SSH, account and remaining workspace tools |
| Distribution | x86_64/aarch64, measured ABI baseline, user archive, .deb/.rpm, upgrades and uninstall |
| Native release gate | GNOME/KDE/Xfce, Intel/AMD/NVIDIA/VM graphics, IME/RTL, Orca/AT-SPI, mixed DPI, reboot/logout/suspend |

First Linux targets to validate are Ubuntu LTS, Debian stable, Fedora, Arch and
openSUSE. NixOS needs a native packaging evaluation. Alpine/musl and older
graphics are separate compatibility targets. A tar archive or AppImage does
not remove libc or graphics-driver requirements.

Flatpak is a possible later GUI distribution paired with a separately
installed host. The sandbox cannot be assumed to own arbitrary host processes,
projects and user services.

The shell uses the source light/dark palette. Known gaps include remaining
Home/feature contents, complete menus and their actions, exact glyph variants,
materials and geometry, resizing/hover peeks, preferences, focus/accessibility,
terminal/chat/account flows, single-window activation, startup settings,
automated reconnect and native Linux package/runtime acceptance. The old probe
retains its own fixed dark experiment. Do not advertise either as production ready.

