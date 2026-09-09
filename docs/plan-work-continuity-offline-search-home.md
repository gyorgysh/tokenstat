# Work continuity, offline access, search, and a personal Home

Status: slices 1 (identifier routing and scope), 2 (drafts, desktop place
restoration and reading marks), 3 (durable sends) and 8 (personal Home on phone
and iPad) have committed implementations. Slice 2 is undergoing acceptance
review. Pins (this milestone) add the `pinnedWork` Home section with an
account-scoped shelf of up to eight folders/conversations, pin entry points on
Continue rows and the phone thread, and cache pinning so pinned copies survive
age eviction. Full typed availability resolution, mobile route restoration,
offline content, handoff, search, desktop Home customization and desktop pins
remain open.
Date: 2026-09-09. Current branch: main. Reconcile code and this implementation
record before starting each slice. One commit per validated milestone.

## 1. Outcome and scope

Make tokenstat a dependable place to return to AI work. A person should find
what matters, resume the correct conversation, read saved work when a machine
is unavailable, and arrange Home around their own priorities. Preserve the
suite's usage-tracking value; do not turn Home into a mandatory task dashboard.

Priority order:

1. Correctness foundations: stable ownership, durable drafts, reliable send receipts.
2. Same-device continuity, then explicit cross-device handoff.
3. Offline conversations and reviewed changes with honest freshness.
4. Search across locally available work, with optional live host results.
5. Personal Home with reorderable sections, sensible defaults and accessible editing.

Home layout work can proceed after the shared identity contract is defined;
its useful first version does not depend on remote search or cloud sync.

This plan does not authorize publishing, provisioning infrastructure, or building
a new cloud content archive. A unified attention inbox and task-completion review
are adjacent follow-ups, not hidden prerequisites for these four workstreams.

### User journeys

- Leave a half-written reply on a Mac, reopen that conversation after relaunch,
  and find the text, staged attachments and reading position intact.
- Open Continue on iPhone, choose the work from the Mac, and arrive at the same
  conversation. If the host is unavailable, open the saved copy when one exists.
- Read a previously opened conversation in airplane mode, draft a reply, and
  choose Send when connectivity returns. A reconnect never invents consent.
- Search for a phrase without remembering its machine or folder. See which
  results are saved here and which came from currently reachable machines.
- Move usage and limits above Continue, or put Continue and pinned folders first.
  The arrangement survives relaunch, rotation and switching between tabs/sidebar.

## 2. Existing implementation to reuse

| Area | Existing source | Implication |
| --- | --- | --- |
| Mobile Home | apps/mac/Sources/Client/ClientHomeView.swift | Currently renders Continue, machines, totals, activity and limits in fixed order. Preserve its account-plane loading contract. |
| Desktop Home | apps/mac/Sources/Features/Home/HomeView.swift, HomeModel.swift | Share section identities and preference semantics; retain desktop scope controls and existing model ownership. |
| Recent destinations | apps/mac/Sources/Client/ClientRecentPlaces.swift, ClientContinueSection.swift, ClientSavedPlaceView.swift | Already bounded and account-scoped. Store labels and references, not transcript content, here. |
| Navigation | apps/mac/Sources/Client/ClientNavigation.swift, apps/mac/Sources/App/Route.swift, RootView.swift | Current layout swaps preserve folder/destination, not a complete typed route. Introduce stable references above layout-specific views. |
| Chat and pending sends | apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift, ChatQueueStrip.swift | Queue persistence exists, but keys use conversation ID and removal precedes send acknowledgement. Migrate ownership and delivery semantics before expanding offline behavior. |
| Composer/attachments | ChatDraftView.swift, ChatInbox.swift in the same Chat directory | Reuse attachment limits and preview handling; host attachment IDs alone cannot reconstruct offline staging. |
| Chat storage/protocol | crates/tokenstat-host/src/chat.rs, chat_turn.rs, dispatch.rs | Host owns accepted conversation history. Extend this path, not a Swift-only send implementation. |
| Bridge | apps/mac/Sources/Bridge/Bridge.swift, Models.swift; crates/tokenstat-ffi/src/abi.rs | All clients need the same versioned contract, including client-only builds. |
| Tab customization | apps/mac/Sources/Client/ClientTabCustomization.swift | Reuse interaction patterns and theme controls, but Home section preferences are a separate model. |
| Notifications | apps/mac/Sources/App/RunNotifications.swift | Notification, search and Continue should resolve the same destination type. |
| Existing encrypted sync | crates/tokenstat-sync/src/vault.rs | Review its patterns, but do not put work content into SSH-vault records or aggregate-profile payloads. |
| Guard rails | scripts/check-home-account-plane.sh, check-sample-offline.sh, run-swift-tests.sh | Extend coverage to new sources; do not remove the Home/no-peer boundary to accommodate a new card. |

The usage archive remains counters-only. Transcript caching and search belong
in a distinct work-data store. Never put conversation text into tokenstat-core's
archive or existing sealed aggregate sync payloads.

## 3. Shared identities and ownership

Introduce a Codable WorkReference on Apple and matching Rust DTOs:

- accountScope: canonical account origin plus stable account identity when the
  account API exposes one. Until then reuse the explicit origin/handle scope;
  do not claim a handle survives renaming. Account renames require migration.
- hostIdentity: the verified public machine identity, not display name/IP.
- workspaceID: the host's raw stable identifier, not a UI-prefixed route string.
- kind: workspace, conversation, terminal, commit, savedDiff.
- itemID and optional anchor: stable message/event ID, commit hash, diff revision.
- local-only scope: an explicit local identity namespace for signed-out desktop
  work. Never silently assign it to the next signed-in account.

File suggestions: new Features/Work/WorkReference.swift and
WorkDestinationResolver.swift; new host work_contracts.rs for wire DTOs.

Every async operation captures scope and a generation at start. Completion can
write only to that scope; changing selection must not turn host acceptance into
send failure. Resolve raw IDs at the boundary. A duplicate conversation ID on
two machines must never share a queue, cache, read marker or draft.

One resolver serves Continue, search, pins, notifications and handoff. Its typed
outcomes are live, savedCopy, reconnecting, accessRequired, hostRemoved,
itemDeleted, unsupportedHost and unavailable. A missing conversation must not
open another conversation with a similar name. A restored terminal is a link
to a still-existing session, never a request to spawn a replacement shell.

## 4. Continuity

### 4.1 Local restoration first

Add WorkContinuityStore.swift and ChatDraftStore.swift under Features/Work.
Persist a small versioned route record, per-conversation draft and read marker.
Do not serialize SwiftUI view trees, mutable conversation models or navigation
hashes. Keep the store above tab/split view lifetime.

Draft fields: WorkReference, draftID, revision, text, staged attachments,
updatedAt, and originatingDeviceID. Reading position: stable event ID plus
within-message offset and followsLatest boolean. Pixel offsets alone are not
portable across device sizes or text scaling.

Save edits after a 300 ms debounce, on navigation/background transitions and
before sending. Persist the outgoing text before clearing the composer. A save
failure leaves the draft visible and offers Retry; it must not say Saved.
Restore local data before connecting; refresh does not replace a nonempty draft.
Restoring a route never automatically sends, opens a shell or changes a branch.

Migrate legacy per-conversation UserDefaults queues only when their original
host/account ownership can be established from existing state. Ambiguous items
must be recoverable as local unsent drafts, never auto-delivered to the current
account. Remove old records only after a verified successful migration. Do not
copy plaintext queues indefinitely into a second store.

### 4.2 Durable sends and acknowledgement

Before enabling retry after disconnection, add an idempotent send contract:

- chat.send accepts clientMessageID, originatingDeviceID and expected conversation
  revision, alongside existing text and attachment references.
- Dedupe scope is authenticated device + conversation + clientMessageID.
  Bind the key to a payload digest; reuse with different text is a conflict.
- Host persists acceptance and its event/turn reference before replying. Repeated
  requests return the existing receipt and never start a second agent turn.
- Add a bounded receipt/status read to reconcile a lost response.
- Persist pending launch state so a crash between acceptance and starting the
  agent is visible. On recovery do not blindly execute a possibly started turn;
  reconcile the runner identity or report needsRecovery for explicit review.
- Define receipt retention (initially 30 days) and reject automatic replay after
  that window. A missing old receipt is not proof the message was never run.

Client states: draft -> queuedLocally -> sending -> accepted. A transport timeout
moves sending to deliveryUnknown; first query the receipt on reconnect. Explicit
host refusal becomes failed with a recoverable draft. Rendering a different
conversation does not alter the receipt or requeue an accepted message.

Keep client outbox ownership on the originating device in the first version.
Cross-device copies of a draft are not two independently draining outboxes.
Migrate the current busy-turn queue into this model; keep its existing 20-item
cap and reorder UI. Use one in-flight send per conversation. Stop/Send now must
reconcile the stopped turn and the selected message separately.

Offline Send is an explicit “Send when connected” action with a visible waiting
row and Cancel. Ordinary draft editing does not enroll a message for sending.
Delivery requires the same verified host/account, current authorization, valid
attachments and a compatible protocol. Expired permissions leave the item waiting
for user action. Reconnect alone does not grant new execution permissions.

Implementation: chat.rs / dispatch.rs, new host chat_receipts.rs, Bridge DTOs,
ChatModel.swift and a new ChatOutboxStore.swift. Review event persistence and
runner recovery together; a receipt table alone is insufficient.

### 4.3 Cross-device handoff

First version: the authorized workspace host stores lightweight continuation
metadata and optional explicitly shared drafts. New work.continuity.get/put
methods are workspace-authorized and bounded. Do not expose them through the
unauthenticated pairing surface. A user chooses “Continue on another device”;
the next device offers “Continue from Mac” rather than jumping its current view.

Shared draft writes use compare-and-swap revisions. Conflicting edits preserve
both versions with device/time labels and actions Use this / Keep mine / Copy.
Never silently replace text or append the same queued send twice. Read position
is per device by default; handoff imports an anchor only when explicitly chosen.

Host-mediated handoff needs the host reachable. Recently used destinations can
be shown from local metadata even when it is asleep, but previously unseen text
cannot be fetched from it. State this in Help and empty states.

Future optional account relay of end-to-end encrypted continuation records is a
separate server project: requires key distribution/recovery, retention, deletion,
quota and conflict APIs. It is not part of aggregate sync and is not necessary
for the initial continuity milestone. No cross-device offline availability claim
until that project is implemented and tested.

Acceptance: relaunch, account switch, view swap and device handoff preserve the
correct draft; an accepted send with a lost response produces one agent turn;
concurrent edits lose no text; a deleted target never receives a replay.

## 5. Useful offline work

### 5.1 Storage and privacy

Create a separate versioned work cache, with shared Rust storage semantics in
new tokenstat-host/src/work_cache.rs, available in client-only builds. Use the
existing platform path/key-storage abstractions; sensitive cache operations are
local-client-only and must be rejected over remote dispatch. Swift-facing
WorkCacheStore.swift coordinates reads through the FFI, not ad hoc remote calls.

Cache selected, already-authorized data: conversation metadata, paginated rendered
message inputs, explicitly viewed diffs and small attachment previews. Exclude
raw terminal scrollback, secrets, environment dumps, full repositories and
unopened file contents by default. Retain source revisions and capture timestamps.

Initial policy: recent opened work auto-saves on this device, with a clear setting
and first-use explanation; 100 MB / 30 days default, configurable off. Explicit
“Keep offline” pins survive age eviction, but remain within a configurable hard
storage budget (initially 500 MB). Show space needed and allow choosing what to
remove rather than silently discarding pins. Unsent drafts are separate durable
user data and must never be evicted with cache entries.

Use authenticated encryption for sensitive records, with a per-account/device
key protected by platform secure storage. Keep labels/snippets encrypted too.
No sensitive UserDefaults payloads. On Apple, use platform file protection;
exclude reconstructible caches from backup and define draft backup separately.
If a platform has no usable secure storage, disable persistent sensitive cache
with an explanation; do not silently fall back to plaintext. Validate the exact
platform implementation before enabling that platform's cache UI.

Account sign-out removes cache keys, records, previews and search indexes for
that scope. Warn about unsent drafts and offer export before completing sign-out;
never sign the user back in or send drafts as part of cleanup. Switching accounts
unmounts the old scope immediately. Explicit access revocation purges affected
content as soon as known. An offline device cannot learn immediate revocation:
document that downloaded copies remain readable until reconnection or deletion.

### 5.2 Reading and drafting

Open saved content immediately with an inline banner: “Saved on this iPhone ·
Updated 2 hours ago.” While attempting a connection say “Checking for updates…”
without removing content. Differentiate offline phone, unavailable host and
access denied. A stale snapshot never presents a running indicator as live.

Allow reading, copying, local search and drafting. Disable live mutations with
a nearby reason and recovery action. Never permit commit, branch change, terminal
input or approval against a stale snapshot. On reconnect, a changed diff requires
a fresh view before the user acts. Display omitted/truncated messages and missing
attachments explicitly; a cache miss is not an empty conversation.

Revalidate by host identity, conversation revision and event cursor. If the stream
was replaced or truncated, invalidate the incompatible range and fetch again.
Keep old saved content visible until replacement is complete, then update without
jumping the scroll position. Preserve optimistic/draft rows independently.

Per-project “Save recent work on this device” can disable caching for sensitive
folders. Settings show bytes, pinned items, retention and Clear saved work. Clear
saved work does not delete source conversations or unsent drafts.

Acceptance: airplane mode after app termination still opens saved work; zero
network calls are required to draw it; account switching exposes no snippets;
stale diffs cannot mutate a repository; disk-full leaves source work and drafts
intact; eviction updates search results atomically.

## 6. Search across work

### 6.1 Scope and presentation

Offer a persistent search action in the main toolbar and Home. macOS uses a
command-palette-style surface with Cmd+K after checking shortcut conflicts; iOS
uses a full-height search sheet, iPad adapts to available width. Search is also
reachable by keyboard and VoiceOver, even if every optional Home card is hidden.

Initial scope: registered/pinned folders, conversation titles, cached conversation
text, and viewed commit/diff metadata. Do not imply full repository code search.
Label the search field “Search work”; scope chips All / Conversations / Folders /
Changes, plus a machine filter. Empty query shows recent searches and destinations
only if enabled; Clear removes query history. Never log query text as telemetry.

Rows contain an entity icon, title, short matched excerpt, folder and machine,
plus Saved or Live and freshness where relevant. Highlight matches without
flattening accessibility text. Avoid syntax-highlighting entire diff previews.
Group by relevance, not one large section per machine; filters narrow scope.
Opening a result uses WorkDestinationResolver and a stable event/commit anchor.

Local results appear first. A separate “Search connected machines” action opts
into querying selected authorized hosts; do not wake/fan out to every machine
while the person types. Retain the user's choice only for the current search
session. Show coverage: “Saved work on this device; 2 of 3 selected machines
answered.” A failed host is partial coverage, not zero matches. Preserve visible
results during retries. Do not reorder the row under a pointer/key selection as
late results arrive; offer an updated-results indicator.

### 6.2 Index and protocol

Add host work_search.rs for authorized live searches and local cache-index
integration. Do not extend the counters archive schema with transcript text.
Use existing SQLite capabilities only after verifying bundled full-text support;
keep an index abstraction so its storage does not force plaintext token leakage.

For the first bounded encrypted cache, decrypt eligible records into a disposable
in-memory full-text index on unlock, in background batches. Persist no plaintext
FTS tables/WAL/temp files; verify SQLite temporary-storage behavior. If measured
memory/startup costs exceed budgets, adopt encrypted-at-rest full-text storage as
an explicit dependency decision, not a hidden fallback to plaintext. Cache-disabled
mode indexes metadata only in memory. The host can build its own private index
from its existing authorized local work store, with restrictive file permissions.

Index stable entity keys, content revision, scope and deletion tombstones.
Index cached pages as partial coverage, not complete conversations. Commit metadata
uses immutable hashes; working diffs carry source revision and snapshot identity.
Purge index entries in the same logical operation as cache removal/revocation.
Bound queries, excerpts and results. Initial limits: 512-character query, 50-row
page, 200 displayed rows, 240-character excerpt, two concurrent host queries.
Escape normal queries as literal terms; no regex or user-supplied SQL in v1.

Proposed work.search request: query, entityKinds, workspace filter, cursor, limit.
Response: typed hits with WorkReference, revision, excerpt, score, source and
coverage; opaque cursor bound to query/scope/index generation. Authorization must
filter candidates before generating snippets or counts. Deletion and revocation
must prevent a stale index from returning content the live store would deny.

Debounce remote entry by 250 ms after explicit live-search opt-in. Cancel superseded
requests and reject late results by query generation. Offline search remains
fully functional over saved content. Normalize Unicode; preserve original text
and use deterministic tie-breaks (relevance, recency, stable identity). Unit-test
matching offsets for composed characters and emoji.

Acceptance: a conversation can be found without knowing its host; offline cached
text is searchable; unauthorized content never appears in counts or excerpts;
partial coverage is visible; opening a result lands at the matching message;
deleted cache records disappear without rebuilding the entire app.

## 7. A personal Home

### 7.1 Information hierarchy

Keep greeting, global search and essential account/connectivity notices outside
the customizable section list. Notices must be compact and tied to an action;
do not repeat one offline warning in every card.

Stable initial section IDs:

| Section | Default contents | Data source |
| --- | --- | --- |
| continue | Up to four recent destinations, optional “From another device” offer | Local continuity metadata; already-fetched account data |
| pinnedWork | User-selected folders/conversations, maximum eight in Home | Local scoped pins |
| machines | Compact machine availability and an Open action | Existing account machine directory |
| usageSummary | Today and this week with existing value qualifiers | HomeModel |
| activity | Existing heatmap | HomeModel |
| limits | Existing provider limits with freshness | HomeModel |

Keep setup/sample guidance contextual to confirmed empty state; absence of cached
activity is not proof of a new user. An attention card is a future section only
when trustworthy read/resolved-state semantics exist; do not synthesize an inbox
from stale running flags.

Default preset “Balanced”: Continue, pinned work if populated, machines, usage,
activity, limits. “Work first”: Continue, pins, machines, limits, usage, activity.
“Usage first”: usage, limits, activity, Continue, pins, machines. These are starting
arrangements, not modes that alter features, billing or execution behavior.

### 7.2 Customization interaction

Home toolbar menu -> Customize Home. Present a themed sheet with a live miniature
preview, preset picker and ordered rows. Each row has an icon, section name,
visibility toggle and reorder handle. Offer Move up/down accessibility actions
and keyboard equivalents; drag must never be the only way to reorder.

Edit a working copy. Done applies atomically; Cancel discards; Reset restores the
Balanced preset in the working copy with an Undo opportunity. Presets change
order/visibility only, not pinned content or cache settings. Reordering from the
main Home is available only in explicit edit mode so normal scrolling cannot move
cards accidentally. Hidden sections are listed under Hidden, easy to restore.

Allow every optional card to be hidden. Keep a useful empty customization state:
“Your Home is clear” with Customize Home, while search/navigation remain visible.
Account/security notices cannot be hidden. Do not force a favorite card back on
because it has fresh data. Empty optional sections collapse without losing their
saved order; the editor shows their position and explains why they are empty.

Phone: one column, full-width cards. iPad/Mac: use deterministic rows at sufficient
width; wide activity spans both columns, compact cards may pair in order. Reading
and keyboard order must match stored order. Avoid masonry and auto-sorting, which
make positions unpredictable. At large text sizes collapse to one column. Do not
reset customization when rotating or attaching a keyboard.

### 7.3 Preferences and integration

New shared HomeSection.swift, HomeLayoutPreferences.swift and
HomeCustomizationView.swift under Features/Home. Refactor ClientHomeView and
HomeView into section rendering using their existing data models; do not create
a second HomeModel per card. Keep platform wrappers for presentation differences.

Preference schema v1: ordered stable section IDs, hidden IDs, optional density,
lastPreset and schemaVersion. Normalize duplicates/unknown IDs, append future
sections without disturbing chosen positions, and preserve safe defaults on
corruption. Layout is per device and per account/local scope; a desktop's order
must not overwrite the phone's. Optional “Use this arrangement on another device”
can come later as an explicit import, not silent sync. Pins are account-scoped
content references and remain separate from device layout settings.

Home never dials peers to render Continue/pins. Each section consumes local or
account-plane data and refreshes independently. A hidden expensive section does
not start its load solely because it exists in the model. Retain existing shared
fetches where several visible cards need them; cancellation must not cancel a
request still used elsewhere. Pull-to-refresh does not scan remote hosts.

Reuse Theme.Space, Theme fonts, ClientType, cardSurface and existing action icon
vocabulary. Selection and toggles use Theme.accent. Provide 44-point touch targets,
visible keyboard focus, readable contrast, reduced-motion transitions and localized
strings without truncating technical recovery actions. Drag animations move cards;
network refresh never animates unrelated sections into a new order.

Acceptance: arrange/hide/restore/relaunch works; unknown future IDs and duplicate
stored IDs normalize safely; VoiceOver can perform every edit; Done/Cancel do what
they say; Home draws in airplane mode with stable saved content; account switch
never reveals another account's pins; all layouts work at narrow split-view sizes.

## 8. Platform and protocol rollout

Apple first: shared models and stores serve macOS/iOS/iPadOS; presentation follows
platform conventions. Keep no-default-features host/FFI builds working. Methods
that read/write the device cache are not remote methods. Host search/continuity
methods go through normal workspace authorization and remote method policy.

Add capability negotiation and update PROTOCOL_VERSION/bridge/client contracts
consistently when methods become available. Older hosts can open existing work;
show a scoped update explanation only for unsupported continuity/search features.
Never fall back from idempotent send to unsafe replay on an older host.

Windows and Android receive matching DTOs/capability handling before advertising
support, then native Home/search/restoration UI. Integration entry points:
apps/windows/Pages/HomePage.cs and apps/android/.../ui/TokenstatApp.kt plus
workspace/ChatPullsSections.kt. Inspect current native model ownership at that
slice; do not copy Swift persistence code into each front end. Reuse shared Rust
cache/search contracts and native secure key storage. Preview status does not
justify decoding failures when a host returns additive fields.

## 9. Implementation slices and exit gates

| Slice | Work | Depends on | Exit evidence |
| --- | --- | --- | --- |
| 0 | Clone reservation fix, truthful update guidance, formatting | Existing implementation | Concurrent-start regression tests; update JSON test; relevant Rust checks |
| 1 | WorkReference, resolver, scope migration design | None | Duplicate IDs across hosts/accounts; stale completion rejection; route restoration tests |
| 2 | Local drafts/read anchors and route restore | 1 | Relaunch/background/layout-swap walkthrough; no draft loss on save error |
| 3 | Durable receipts/outbox reconciliation | 1, 2 | Lost-response and crash-window tests; one accepted message produces at most one launch |
| 4 | Encrypted cache, settings, offline reader | 1, 2 | Airplane-mode cold launch, quota/eviction, secure deletion and account isolation |
| 5 | Host-mediated explicit handoff and draft conflicts | 1–3 | Two-device conflict/handoff test; unavailable-host messaging |
| 6 | Local work search and coverage UI | 4 | Seeded search corpus, authorization and Unicode tests, measured latency |
| 7 | Opt-in live host search | 6 | Partial host failure/cancellation; permission-filtered snippets and counts |
| 8 | Home sections, presets, edit sheet, pins | 1; integrates 2/4 as available | Layout normalization tests; keyboard/VoiceOver and size matrix |
| 9 | Native parity, performance and documentation | Relevant preceding slices | Platform builds, physical-device review, honest feature availability |

Each slice is independently reviewable and has its own implementation/validation
record. Do not enable offline queued sending before slice 3 passes. Home layout
can ship earlier without waiting for handoff or live search. Update this plan's
status per slice with actual evidence, not only screenshots or commit titles.

## 10. Verification and measurement

Automated tests must exercise outcomes, not source-text snapshots alone:

- Injected storage/account/clock for Swift state tests; no real credentials.
- Rust host tests for concurrent duplicate sends, digest conflicts, access changes,
  acceptance/launch crash recovery, cursor invalidation and query limits.
- Cache tests for corruption, quota, failed write, key unavailability, deletion,
  revocation and stale async completions after account switch.
- End-to-end harness: two clients and one disposable host; drop a response after
  durable acceptance, reconnect, assert one launch and one displayed message.
- A second harness disconnects the host, restarts the client, searches saved text,
  edits a draft and reconnects without auto-sending that draft.
- Full host/FFI feature matrix, Swift state runner, bridge/home/sample/privacy
  guards, native Apple builds; native Windows/Android checks when their slices land.

Physical-device matrix: iPhone narrow/large text, iPad portrait/landscape and narrow
split, iPad keyboard attach/detach, Mac multiwindow. Test VoiceOver, keyboard-only,
Reduce Motion, dark/light themes, network loss, sleeping host, deleted conversation,
expired authentication, active-account switch, low disk and attachment eviction.

Initial performance budgets are acceptance targets, not claims about current code:
local Home content visible within 200 ms after its view mounts; cached conversation
first page within 300 ms; local search p95 under 100 ms after debounce on a 10,000
message fixture; bounded background index rebuild with cancellation. Measure cold
launch separately, record device/build/dataset, and keep the UI usable while indexing.
Load test near the 100 MB cache cap and on a low-memory phone before selecting the
final indexing strategy. No transcript/query telemetry; use aggregate local timing
and synthetic fixtures for performance diagnosis.

## 11. Layout sketches and interaction details

These sketches define hierarchy, not a new visual theme. Implement with existing
cards, typography and spacing; review rendered screens before accepting the slice.

```text
Phone Home                          Customize Home
Good morning, …        Search  …    Cancel                    Done
[compact connection notice]         Preset: Balanced / Work / Usage
Continue                            [small layout preview]
[Project · conversation · saved]     Visible
[Project · conversation · live ]     ≡ Continue             [on]
Pinned work                         ≡ Pinned work          [on]
[folder] [conversation]              ≡ Machines             [on]
Machines                            ≡ Usage                [on]
[Mac · last seen …]                  ≡ Activity             [on]
[Today          ][This week    ]     Hidden
Activity                            + Limits
[existing heatmap]                  Reset arrangement
```

```text
Wide Home
Greeting                                      Search   Customize
[one compact account/connection notice, only when relevant]
[Continue                         ][Pinned work                    ]
[Machines                         ][Usage summary                  ]
[Activity heatmap spanning the available content width              ]
[Limits                                                            ]
```

A moved card keeps its height contract and stable identity. Do not rebuild chat
models when a card moves. In the editor, announce “Activity moved to position 2”
and return focus to that row. Applying an arrangement preserves Home scroll
position where possible; do not jump to the top after every preference change.

Search opening behavior: autofocus only on explicit Search, not when returning
from a result. Escape dismisses; arrow keys select results; Return opens; Cmd+Return
may open in a new Mac window only if the existing window-routing model supports
it. Back returns to the same query, filters, selected row and scroll position.
A deleted match displays a small unavailable state with Back to results, not a
blank detail. Search query history is off for sensitive-work scopes.

Offline conversation behavior: keep the composer in its usual location, label it
“Draft saved on this device” only after persistence succeeds, and keep unavailable
attachment previews as named placeholders with Remove/Locate actions. A waiting
send is a separate visible row; editing the composer does not mutate an in-flight
message. A “Delivery not confirmed” row offers Check status before any resend.

Handoff offer: show folder, conversation, source device and last update. Use Open
as the primary action; dismissing the offer does not delete the source draft.
If two versions exist, compare text in a readable sheet, preserving line breaks;
no automatic merge of prompt instructions. Choosing one retains the other as a
recoverable draft until the user explicitly removes it.

## 12. Decisions fixed by this plan and remaining implementation checks

Fixed: preserve the account-plane Home boundary; user-controlled section order;
local drafts are durable user data; cache eviction cannot remove drafts; explicit
handoff; no silent draft conflict resolution; no replay without receipt support;
no cloud transcript archive in this work; no plaintext cache fallback.

Check before implementation: account immutable-ID availability; existing secure
key storage on each platform; event-ID stability and cursor reset semantics;
chat runner crash recovery and receipts' transaction boundary; FTS/temp-storage
capability; existing keyboard shortcut conflicts. Record findings in the relevant
slice. These are technical discovery tasks, not reasons to stop all independent work.

Update Help/privacy copy when offline storage actually ships: explain what stays
on this device, what reaches a host, how to clear it, and what is unavailable when
a machine is asleep. Product messaging must not promise cross-device offline data
that the implemented transport cannot supply.


## 13. Immediate-fix record

Implemented alongside this plan (2026-09-09): clone starts reserve a bounded
permit before spawning and retain the target claim through completion; failed
starts release their reservations. Update output reports a changed daemon binary
and advises an explicit restart after active sessions, including structured JSON.
Formatting findings from the preceding review were corrected. These fixes do not
implement the feature slices above. Release workflow changes are outside this
product-focused task.

Repository convention: /docs/ is gitignored. This plan is explicitly tracked
at the user’s request; the ignore rule remains unchanged for other documents.

Validation for the immediate fixes: 795 tests passed across tokenstat-host,
tokenstat-cli and tokenstat-sync (all features, locked dependencies); no failures.
All-target/all-feature Clippy passed for those crates, client-only host Clippy
passed, and workspace formatting plus diff whitespace checks passed. No Apple
feature UI was implemented or visually validated in this task.


## 14. Continuity implementation checkpoint (2026-09-09)

First increment of slice 1:

- Added identifier-only WorkReference and matching Rust DTOs with explicit wire keys.
- Added a pure WorkDestinationResolver and routed existing chat loads/deletions
  through it. A resolved local peer stays nil even while remote work is open.
- Added a bounded WorkContinuityStore, used by ChatModel to remember the last
  selected conversation per account origin/handle, verified host identity and
  raw workspace ID. Shared storage is reread on write so multiple windows do not
  overwrite each other's entries. Data contains identifiers only.
- AccountModel publishes already-loaded account scope; unknown account state
  cannot claim signed-out work. Local identity comes from machine.identity.
  Mac chat reloads when scope changes; stale transcript results are rejected.
- Old global last-selected IDs remain untouched and are not auto-migrated,
  because their original account cannot be established reliably.
- Fixed the preceding review's notification-ordering bug with one serialized
  state-and-scheduling helper, covered by a concurrent regression test.

This is not the complete slice 1 resolver UI: typed availability outcomes,
notification/Continue/search integration and full route restoration still remain.
No new host method, outbox replay, draft persistence or content cache is enabled.
Next increment: protected durable local drafts and stable read anchors, after
routing all owners through the reference contract; receipt-based sending remains
its own subsequent slice. Keep the acceptance gates in section 9.


## 15. Implementation record, 2026-09-09

One commit per milestone on `v1.0`, each built on both Apple platforms, run
through the ten check scripts and the standalone Swift executables, and tried
by hand in the running app or the simulator rather than only compiled.

| Slice | Commit | What landed |
| --- | --- | --- |
| 1 | `27db5d29` | `WorkReference`, `WorkDestinationResolver`, `WorkContinuityStore`, `WorkSessionContext`, host `work_contracts`. Remembered conversations are keyed by account, verified machine identity and raw workspace id; multiwindow writes merge; old unscoped ids are left alone. |
| 2 (drafts) | `4243e59c` | `ChatDraftStore`, `ChatDraftTransition`, `ChatDraftNotice`. The composer's words belong to the conversation, survive relaunch with their staged files, and are kept until a send is answered. Both chat lists mark conversations holding unsent words. |
| 3 | `04ce0564` | `chat_receipts`, `clientMessageId` on `chat.send`, `chat.receipt`, protocol 10 across all four mirrors, `RemoteHostFeature.confirmedSend`, and the client's unconfirmed-send reconciliation. |
| 8 | `03d63fe2` | `HomeLayout`, `ClientHomeEditor`, `ClientHomeView` rendering sections in order. Presets, reorder by drag and by VoiceOver, every card hideable, a clear-Home state. |

Decisions taken while implementing, which differ from or refine this plan:

- **Sign-out does not delete drafts.** Section 5.1's purge needs the warning
  and export flow first; deleting somebody's unsent writing without it is worse
  than keeping it for the account it belongs to.
- **Home layout is per device only**, not per account scope (section 7.3). The
  account scope is unknown for the first moments of a launch, and keying layout
  to it would reflow Home on every cold start. Pins stay account-scoped.
- **`pinnedWork` is not a section yet.** Pins do not exist, and an always-empty
  card is worse than no card. `HomeLayout.normalize` appends later additions at
  the end, so adding it will not disturb an arrangement somebody chose.
- **The receipt check runs before the already-responding guard.** The case
  receipts exist for is an answer lost while the turn it started is still
  running, and the busy refusal would report a failure where the truth is that
  the message was taken.
- **A pending receipt is settled against the transcript**, comparing the
  pre-compose prompt as a prefix, because the stored row is the composed turn
  and can carry attachment names after it.

## 16. Continuity acceptance review, 2026-09-09

Recovered commits omitted from the earlier status:

- `a6d0858b`: scoped desktop place restoration with rebuilt folder routes.
- `1e84e56e`: launcher preview ownership fix plus shared reading marks and
  transcript restoration on both Apple platforms.

The next milestone addresses reading-position task ownership. Delayed saves
capture the reference and selection generation, restoration checks both after
each suspension, and cancelled restoration cannot fall through to Jump to latest.
The restoration task follows the scoped reference, including a different machine
or account with the same conversation ID. Manual scrolling interrupts restoration.

Remaining acceptance work is explicit: physical-device reading/background/layout
walkthroughs, within-message positioning for long rows, and restoring anchors
outside the loaded event range. Do not mark these complete from a compile alone.
The draft store also needs review before offline expansion: it currently truncates
long text and evicts old drafts at 400 entries, and its write limit does not match
its read limit. These violate the plan's durable-writing contract.

The first Mac walkthrough caught a real contract mismatch: display IDs carry
kind prefixes (`text-s123`, `user-s123`) but the reading validator accepted only
bare `s123`. The correction accepts known, sequence-backed row IDs and uses
archive positions for tool/edit IDs when provided. Legacy call-ID/occurrence
rows remain intentionally ineligible because prepending pages can change them.
The walk also clarified that `follow.scrolling` includes driven layout motion,
so restoration must use the existing reader-abandonment signal instead.

Reading ownership/row-identity correction committed as `dc2ab28a` on `main`.
Both Apple builds and 13 Swift test executables passed. Mac screenshot review
confirmed the themed controls. The follow-up AX navigation lost its window
while the app remained alive doing layout, so complete scroll/switch/return
acceptance is still open. Do not present that walkthrough as passed.
