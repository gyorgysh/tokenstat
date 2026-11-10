<!-- SPDX-License-Identifier: LicenseRef-tokenstat-source-available -->

# Desktop surface inventory

This is the working port ledger for [the parity requirement](PARITY.md).
All rows remain unapproved for visual parity. “Initial” means code exists;
it does not mean the complete behavior or rendered appearance is accepted.
“Unported” includes routes currently displaying an explicit preview message.

The route and root presenter inventory below has been read against the desktop
branches of SwiftUI. Nested feature menus, sheets, dynamic conditions and
interaction fixtures still need individual expansion. This is **not yet the
complete reachable-menu inventory** required for signoff. Do not infer coverage
of a nested surface from coverage of its parent screen.

## Shared shell and menus

| Surface and entry point | SwiftUI specification | Linux owner and current state |
| --- | --- | --- |
| Main window, floating/flat rail, title band, pane resizing and full screen | [RootView](../mac/Sources/App/RootView.swift), [ShellChrome](../mac/Sources/App/ShellChrome.swift), [DesktopWorkbenchState](../mac/Sources/App/DesktopWorkbenchState.swift) | [desktop.rs](src/desktop.rs), [layout.rs](src/layout.rs): initial; retained panes, root state restoration, full screen and native window chrome unverified |
| Rail, global/workspace/SSH selection and inspector availability | [Route](../mac/Sources/App/Route.swift), `RootView.openRail`, `openSection`, `inspectorContent` | [navigation.rs](src/navigation.rs), generated [design.rs](src/design.rs): initial; actual feature destinations mostly unported |
| Application/File/Edit/View/Window/Help menus and bindings | [TokenstatApp.commands](../mac/Sources/App/TokenstatApp.swift), [ChatDetailSettings](../mac/Sources/Features/Account/ChatDetailSettings.swift) | [commands.rs](src/commands.rs), [menus.rs](src/menus.rs), `desktop.rs`: initial menu model/input; native roles, dynamic focused target and many actions unported |
| About window | [AboutView](../mac/Sources/App/AboutView.swift), `TokenstatApp.aboutWindowID` | Unported; menu action reports a gap |
| Account footer menu: signed out/in, syncing/cooldown, update checking | `RootView.accountMenuItems`, [NativeMenuTrigger](../mac/Sources/Design/NativeMenuTrigger.swift) | `commands.rs`, `desktop.rs`: 16 source/state cases compared; sign-in/out, sync, update and full visual/input acceptance open |
| Repository/machine/sidebar grouping, section menus, new chat, search | `RootView.leftSidebar`, `sidebarSectionMenu`, sidebar row types, [SidebarPreferences](../mac/Sources/App/SidebarPreferences.swift) | `desktop.rs`, [desktop_data.rs](src/desktop_data.rs), [sidebar.rs](src/sidebar.rs): project/Projects-section persistence and full store semantics wired, 63 original store/window traces compared. Initial conversation children/history disclosure now present. Remote grouping, server/full chat owners, section-order UI, badges, new chat/search and full rows remain incomplete |
| Repository row menu and rename/share/worktree/remove confirmations | `RootView.projectActions`, `WorkspaceRow.menu`, `RemoveWorkspaceConfirm`, `RemoveAllChatsConfirm`; [SidebarRowActions](../mac/Sources/App/SidebarRowActions.swift) | [project_menu.rs](src/project_menu.rs), [project_rows.rs](src/desktop/project_rows.rs): 1,536 complete original menu snapshots and 72 original reference cases compared. Initial row/disclosure/hover/Shift control and captured pin/unpin dispatch; most destinations/confirmations, full data owners, children, hover cards, input/AX and pixels remain open. See project menu ledger below |
| Conversation row menu, rename/fork/delete/share/cache actions | `RootView.chatHistoryList`, `ChatSidebarConversationRow.menu` | [chat/menu.rs](src/chat/menu.rs), [chat_rows.rs](src/desktop/chat_rows.rs): all 128 source menu states compared; captured pin/unpin wired. Rename/fork/delete/details/preview/confirmations and native input/pixels remain open. See conversation ledger below |
| Local terminal and SSH session/host row menus | `RootView` terminal/SSH sidebar rows, `CloseSessionConfirm`, `CloseSSHSessionsConfirm` | Unported; retain running and ended scrollback, close-one/all confirmations |
| Common cards, buttons, segment pickers, check discs, empty states, sheets | [Theme](../mac/Sources/Design/Theme.swift), [ThemeCheckDisc](../mac/Sources/Design/ThemeCheckDisc.swift), [ThemedSheet](../mac/Sources/Design/ThemedSheet.swift), [ActionIcon](../mac/Sources/Design/ActionIcon.swift) | [presentation.rs](src/presentation.rs), [symbols.rs](src/symbols.rs): initial; SF geometry, system font shaping, materials, focus, motion and AX open |

## Destinations and their inspectors

These rows account for every `GlobalSection`, `WorkspaceSection` and SSH route
in `Route.swift`. Mac history is an inspector tab, and workspace panes stay
mounted while hidden; an empty branch of `nonWorkspaceDetail` is not an empty
feature to omit.

| Route / reachable surface | SwiftUI detail and inspector | Linux status / required states |
| --- | --- | --- |
| Global Home | [HomeView](../mac/Sources/Features/Home/HomeView.swift), [HomeInspector](../mac/Sources/Features/Home/HomeInspector.swift) | Initial; see Home breakdown below |
| Global New chat | `RootView.newChatPage`, [ChatStartPage](../mac/Sources/Features/Workspaces/Chat/ChatStartPage.swift) | Unported: agent/project/machine selection, setup and sending states; no inspector |
| Global Insights | [InsightsView](../mac/Sources/Features/Insights/InsightsView.swift), `ScopedInsightsInspector`, [InspectorView](../mac/Sources/Features/Insights/InspectorView.swift), [ClientInsightsModel](../mac/Sources/Client/ClientInsightsModel.swift) | Initial All devices route in [insights_account.rs](src/desktop/insights_account.rs), using [account.rs](src/insights/account.rs) per-cut/account cache and `account.report` transport (11 original held-reply checkpoints). The initial view has cut/search/refresh/rows, basic chart and inspector; 27 original day positions compare. The initial This device route in [insights_local.rs](src/desktop/insights_local.rs) has period/tabs, day focus/back, scan, explicit remote fetch, ranking, pagination and basic inspector; its owner is in [insights.rs](src/insights.rs) and [fetch.rs](src/insights/fetch.rs). These are early implementations: both scopes still need exact charts, inspector/content/layout, control/input/AX/pixels, real GPUI lifecycle and account transitions; locale-sensitive search/date/age also remain open. |
| Global Devices | [MachinesView](../mac/Sources/Features/Machines/MachinesView.swift), [MachinesInspector](../mac/Sources/Features/Machines/MachinesInspector.swift) | Unported: account/local/remote presence, requests, permission states, wake/reconnect/update, screen view |
| Global Teams | [TeamManagementView](../mac/Sources/Features/Teams/TeamManagementView.swift), [TeamModels.TeamSection](../mac/Sources/Features/Teams/TeamModels.swift) | Unported: tier-gated creation, sections, organization/project selection, roles, shared chats, requests and editors; no root inspector |
| Global Account | [AccountView](../mac/Sources/Features/Account/AccountView.swift), [AccountModel](../mac/Sources/Features/Account/AccountModel.swift) | Unported: signed out/in, Account/Plan limits/This Mac panes, sync/sign-out review, machine list, provider switches, host/launch, terminal/models/forge, notifications, saved work/privacy/licences/deletion; no inspector |
| Global + workspace Tasks | [TodoView](../mac/Sources/Features/Todo/TodoView.swift), [TodoInspector](../mac/Sources/Features/Todo/TodoInspector.swift) | Unported: project scope, board/list/filter, selection, draft/editor, run/delegate/results, errors and deletion |
| Global + workspace Notes | [NotesView](../mac/Sources/Features/Todo/NotesView.swift), [NoteMarkdownEditor](../mac/Sources/Features/Todo/NoteMarkdownEditor.swift) | Unported: selection/draft/formatting/search, unsaved recovery, conversion and deletion; no root inspector on Mac |
| Global + workspace Workflows | [WorkflowsView](../mac/Sources/Features/Workflows/WorkflowsView.swift), [WorkflowsInspector](../mac/Sources/Features/Workflows/WorkflowsInspector.swift) | Unported: recipes/list, graph editor, step fields, validation, drafts, run/history/results and destructive actions |
| Global + workspace Automations | [AutomationsView](../mac/Sources/Features/Automations/AutomationsView.swift), [AutomationsInspector](../mac/Sources/Features/Automations/AutomationsInspector.swift) | Unported: jobs, editor/schedule, enablement, active/history/run transcript/review, errors and deletion |
| All projects overview | [WorkspacesOverviewView](../mac/Sources/Features/Workspaces/WorkspacesOverviewView.swift), `RootView.WorkspacesOverviewPlaceholder` | Unported: local/remote cards, directory loading/error/retry, add/open, badges and sharing |
| Workspace Terminals | [WorkspacesView](../mac/Sources/Features/Workspaces/WorkspacesView.swift), [WorkspaceInspector](../mac/Sources/Features/Workspaces/WorkspaceInspector.swift) | Unported: launcher, tabs/splits, running/ended output, input/selection/copy/paste, close/reconnect and retained state |
| Workspace Chats | [ChatView](../mac/Sources/Features/Workspaces/Chat/ChatView.swift), `WorkspaceInspector` | Full wire/warm-row/page-window and complete pure coalescer/auth/image/fold foundations have source coverage ([reader](PARITY.md#reader-records-and-initial-page-window), [projection](PARITY.md#complete-transcript-projection)). Guarded worker/publication now has source and actual GPUI scheduling coverage ([publication](PARITY.md#guarded-background-publication)). [reader.rs](src/chat/reader.rs) now connects actual GPUI opening/awaited transport/metadata/atomic paging transactions, with independent native reader checks. Unported: full load/reveal/helper adoption and mounted conversation/overview/streaming/fold controls, composer, setup, usage/limits, attachments, approvals, questions, queue/steer, errors/recovery and sharing |
| Workspace Changes | [ChatChangesWorkbenchView](../mac/Sources/Features/Workspaces/Chat/ChatChangesWorkbenchView.swift), [WorkingTreeReviewView](../mac/Sources/Features/Workspaces/WorkingTreeReviewView.swift), `WorkspaceInspector` | Unported: working tree/turn/commit review, filters, staged/unstaged state, diff navigation, git actions and recovery |
| Workspace History | `WorkspaceInspector` history tab, [CommitView](../mac/Sources/Features/Workspaces/CommitView.swift), [DiffDocumentView](../mac/Sources/Features/Workspaces/DiffDocumentView.swift) | Unported: inspector-only entry, commit selection, graph, pagination, diff and reviews |
| Workspace Pull requests | [PullsView](../mac/Sources/Features/Workspaces/Pulls/PullsView.swift), [PullDetailView](../mac/Sources/Features/Workspaces/Pulls/PullDetailView.swift) | Unported: list/filter, forge authentication, details, reviews/comments/checks/diff/actions; preserve repository identity |
| Workspace Files | [WorkspaceFilesView](../mac/Sources/Features/Workspaces/WorkspaceFilesView.swift), [EditorView](../mac/Sources/Features/Workspaces/EditorView.swift), `WorkspaceInspector` | Unported: tree/context menus, loading/errors, editors, unsaved changes, search and file mutations |
| Workspace Browser | [ProjectBrowserView](../mac/Sources/Features/Workspaces/ProjectBrowserView.swift), [BrowserView](../mac/Sources/Features/Workspaces/BrowserView.swift), `WorkspaceInspector` | Unported: tabs/history/address/navigation, permissions/downloads, external links, retained WebKit-equivalent surface |
| SSH Hosts (all / folder) | [SSHSectionView](../mac/Sources/Features/Machines/SSHSectionView.swift), [SSHInspector](../mac/Sources/Features/Machines/SSHInspector.swift), [SSHLibraryEditors](../mac/Sources/Features/Machines/SSHLibraryEditors.swift) | Unported: folders/filter, host editor, vault/auth/host trust and connection states |
| SSH Keys | `SSHSectionView`, `SSHInspector`, [SSHVaultView](../mac/Sources/Features/Machines/SSHVaultView.swift) | Unported: generation/import/unlock, secure storage, sync/recovery, rename/remove/password sheets |
| SSH Snippets | `SSHSectionView`, `SSHInspector`, [SSHCommandPalette](../mac/Sources/Features/Machines/SSHCommandPalette.swift) | Unported: snippet editor, variables/startup/preview/run and confirmation |
| SSH Trusted servers | `SSHSectionView`, `SSHInspector` | Unported: known host selection, trust/key change/removal and confirmation |
| SSH live terminals for a saved host | [SSHTerminalPane](../mac/Sources/Features/Machines/SSHTerminalPane.swift), [SSHSessionInspector](../mac/Sources/Features/Machines/SSHSessionInspector.swift), [SSHLiveTerminal](../mac/Sources/Features/Machines/SSHLiveTerminal.swift) | Unported: tabs/split/scrollback, palette/snippets, reconnect/input, deleted-record fallback and close-all |

## Project menu ledger

Order and conditions below come from `RootView.projectActions`, with Rename
inserted by `WorkspaceRow.menu`; `SidebarPinAction.items` owns capacity.
The pure menu matches 1,536 original snapshots. The connected adapter currently
has local directory/pin facts; sharing, git and remote stale owners are open.
Every unported action remains visible when its supplied source facts permit it.
No row below has native input, AX or pixel signoff.

| Item / trigger | Source condition | Linux behavior / open work |
| --- | --- | --- |
| Rename | Row is not stale; first item | [project_dialogs.rs](src/desktop/project_dialogs.rs), [project_edit.rs](src/project_edit.rs), [input_field.rs](src/input_field.rs): initial local sheet/save/error/retry, scope-gated reload and atomic refresh of an existing pin. Remote directory owner, native sheet chrome/input/AX/pixels open; ten offline/source visual states |
| Pin to Home / Unpin from Home | Resolved scope/host/workspace reference | Captured operation/reference/labels; shared persisted worker. Scope/readiness/error and native input acceptance open |
| Eight-pin explanation | Not already pinned and scoped count ≥ 8 | Disabled action after disabled Pin; re-pinning/unpin remain available; store independently refuses ninth pin |
| Saved work on this device | Same resolved reference | Visible; saved-folder sheet/access/cache flow unported |
| Separator | Always after reference block | Preserved, including adjacent/leading source separators |
| Open shared project | Local folder with local publications | Visible with supplied sharing facts; selection/open flow unported |
| New private chat | Same local-publication condition | Visible with supplied facts; chat creation unported |
| Share project | Local folder | Visible; sharing sheet unported |
| Stop sharing | Local active or cleanup-pending publications | Destructive metadata retained; confirmation and host mutation unported |
| Separator | Local folder, after sharing block | Preserved |
| Reveal in Finder | Local folder | Source copy retained; connected platform file-manager reveal. Fixtures stay inert; Linux behavior unverified |
| Disconnect from computer | Remote with nonempty peer ID; nil label uses source fallback | Visible with supplied facts; notification/disconnect and stale-directory retention unported |
| Early end | Remote peer is stale | Suppresses all following items; pin/saved/disconnect remain above |
| Separator | After local reveal / nonstale remote block | Preserved |
| New chat | Nonstale tail | Visible; real new-chat/draft behavior unported |
| New terminal | Nonstale tail | Opens Sessions without spawning a shell; actual launcher/catalog/session flow unported |
| Worktrees | Git `isRepo == true` | Visible with supplied git facts; worktree sheet unported |
| Delete all chats | Nonstale tail | Destructive metadata retained; confirmation, running-chat and deletion flow unported |
| Separator | Before Remove | Preserved |
| Remove from tokenstat | Nonstale tail | Initial local confirmation, existing host removal, reload and selected-folder fallback. [confirmation.rs](src/confirmation.rs)/[confirmation_view.rs](src/desktop/confirmation_view.rs) replace generic GPUI fallback; eight actual native/GPUI content-frame comparisons, source roles/key equivalents/focused Return/callbacks checked. Glass/shadows/composited colours, active focus/AX/Linux input/pixels, remote directory, dirty-close prompt and tab/editor cleanup remain open; 504 original removal method traces and fake RPC checks still apply |
| Shift-to-remove row control | Hovered and not stale | Same captured Remove path and confirmation; remaining gates above apply |
| Project row / disclosure / compose / share seats | `RootView.projectRow`, `WorkspaceRow` | Initial source sizes/weights/hover; row opens Sessions and reveals/persists its disclosure, other targets use captured folder. Projects-section and project expansion use the shared worker with per-window state and source returning-ID defaults. Conversation children now have an initial read/list owner; terminal/job children, reorder, summaries, hover cards, selected glyphs, truncation, first paint and native interactions remain open |

## Conversation child ledger

All rows remain without visual/native-input signoff. The source puts live work
under a project; it does not repeat its section tabs here. Twenty-two original
SwiftUI references cover eleven inert states in both appearances. The corresponding
GPUI fixtures are not approved captures.

| Surface / condition | Source | Linux owner and open work |
| --- | --- | --- |
| Directory mount, initial loading/retry/empty | `projectChildren`, `warmWorkspacePreviews(includeMessages:false)`, `sidebarDirectoryPresentation` | [chat/directory.rs](src/chat/directory.rs), `chat_rows.rs`: scoped title-only reads, independent caches, shared in-flight transport and cancellation/retirement fences. Full ChatModel/current-transcript/live-event integration remains open |
| Five/ten-row window, held order and footer | `ChatHistoryWindow`, `RootView.holdingOrder`, `chatHistoryList` | [chat/history.rs](src/chat/history.rs): 220 windows, 550 steps and 20 orders compared. Source history preferences wired; keyboard/mouse/disappearance timing, full overview and input/AX/pixels open |
| Title/mark/status and selection | `ChatSidebarConversationRow`, `CompactAge`, `TurnElapsedText`, `ChatDraftMark` | Initial 30-point fitted rows, source text roles, reserved controls, pull/draft seats, per-row one-second clocks and route metadata. [draft_marks.rs](src/desktop/draft_marks.rs) now uses real private store membership, independent mark invalidation and no seat for a missing mark. Full wire DTO now has original-source decoding coverage; active chat ownership, precise glyph/baseline/truncation/focus/power/AX and pixels remain open |
| Unsent writing and draft-aware filtering | `ChatDraftStore`, `OriginalFileCoordination`, `ChatModel.isUnused` | [drafts.rs](src/drafts.rs) and `drafts/`: non-evicting scoped records, stable message IDs, latest-file merge/conditional deletion, pending failure/retry, private atomic disk IO and app-owned draining. 14 complete original-source traces / 97 checkpoints; 50 mixed-process records reopened by both implementations, two-way live/dead leases. Local loaded catalog supplies Home facts. Composer/send/attachment/retry UI, original removal owner, native filesystem/session/input/AX/pixels remain open |
| Rename | Always present; disabled for shared chats | [chat_mutations.rs](src/desktop/chat_mutations.rs) and shared `project_dialogs.rs`: initial sheet, trim/disable/saving/error/retry, captured local/remote host update, owner fencing, note-preserving publication and existing-pin title refresh. Ten source references and matching offline states. Active-reader send/context-revision bookkeeping, native sheet/input/AX/pixels remain open |
| Read/mutation reconciliation | `ChatReadFlights`, `ChatListMutations`, `ChatSteerOverlay`, `publishSidebarConversation` | [flights.rs](src/chat/flights.rs), [list_mutations.rs](src/chat/list_mutations.rs), [steer_overlay.rs](src/chat/steer_overlay.rs), directory acceptance: obsolete result/error retries, no completed cache, isolated owners and exact mutation/note boundaries. 34 original traces/616 checkpoints plus original actor continuations and Rust directory/fake RPC tests. Directory/rename wired; [query.rs](src/chat/query.rs) and [transport.rs](src/chat/transport.rs) now provide typed directory/page/tail requests and one actual GPUI pool with immutable replies, coded refusals and exact/batched leases. Owned native fake-host checks cover this boundary. Retained timeline controller, remaining read methods and mutation/send consumers remain open |
| Opening, polling and view lifetimes | `ChatOpeningRead`, `ChatPollLane`, `ChatPollWatcher`, `ChatPollCadence` | [polling.rs](src/chat/polling.rs) and child modules: shared producers, revision-retired bounded passes, exact queued watcher leases, retained self/timer cancellation and cadence. Original async tests, portable suspended scheduler and actual GPUI task/timer checks; 88 strict cadence traces/2,964 checkpoints. Full retained ChatModel/transport/publication/status/approval/view composition remains open |
| Pin / Unpin | Reference resolved; capacity rules independent of sharing/running | Captured explicit operation/reference/title/folder name; shared metadata worker and fixture memory. Full Home chat/draft projection and native interactions open |
| Fork / Forking | Disabled for shared, running or copying | [chat_mutations.rs](src/desktop/chat_mutations.rs), [actions.rs](src/chat/actions.rs): initial captured local/remote copy, source protocol-26 gate, duplicate/lifetime/error fencing, metadata publication and route-equality reveal. 192 original task/bridge/model/root outcomes; copying fixture and native failure alert with ten actual GPUI/native frame comparisons. Full active-reader/reveal, transient cancellation messaging, simultaneous native presentation, input/AX/materials and pixels remain open |
| Separator, Delete chat | After Fork; delete disabled for shared/running/copying | Source order, role and enablement retained. Delete confirmation and actual transcript removal unported; Shift control reports same gap |
| Details and hover previews | Info seat always reserved; preview dwell 180ms when unselected | Info/control seats present. Details card/usage/inspection/identities, preview cache/reads, native popover/focus/AX still unported |
| Live terminals, SSH shells, automation jobs, workflow runs | Before/after chats in `projectChildren` | Unported owners, selection, context menus, close confirmations and retained output. Conversation-empty hints lack these owners until they join this composition |

## Home detail ledger

| Surface / trigger | Source | Linux owner and evidence / open work |
| --- | --- | --- |
| Identity/greeting/profile/year figures | `HomeView.profile`, `HomeModel`; [Greeting](../mac/Sources/Design/Greeting.swift) | [home_view.rs](src/desktop/home_view.rs), [home.rs](src/home.rs): initial; greeting/currency source checks; full pixels/account actions open |
| Today / last 7 days / busiest panels | `HomeView.usageSummary`, `figurePanel`, `HomeModel.todayValue`, `weekValue` | [home_panels.rs](src/desktop/home_panels.rs): initial; four compiled calendar cases including empty/missing/saturated; default Balanced hides Usage |
| Activity grid, local/all-device scope, history lock, refresh | [HeatmapView](../mac/Sources/Features/Home/HeatmapView.swift), `HomeView.activity` | `home_view.rs`, `home.rs`: initial; geometry/data/scope checks; pointer issue in upper-right cells, AX, reduced motion and pixels open |
| Day hover | [DayDetailPopover](../mac/Sources/Features/Home/DayDetailPopover.swift) | [day_view.rs](src/desktop/day_view.rs), [home/day.rs](src/home/day.rs): ready/loading fixtures; source reference PNGs exist, visual signoff open |
| Pinned day inspector | `HomeInspector` | `day_view.rs`, `home/day.rs`: ready/empty/loading/locked/no-selection fixtures; formatting/grouping/RPC checks; initial focused-day Insights destination exists but is not parity-verified |
| Vendor quota + subscription usage panels | [PlanLimitsCard](../mac/Sources/Features/Insights/PlanLimitsCard.swift), [PlanUsageCard](../mac/Sources/Features/Insights/PlanUsageCard.swift), [PlanLimitsStore](../mac/Sources/Features/Home/PlanLimitsStore.swift), [PlanLimitsOrder](../mac/Sources/Features/Home/PlanLimitsOrder.swift) | `home_panels.rs`, [home/plans.rs](src/home/plans.rs), [shared store](src/home/plans/store.rs), [home_shared.rs](src/desktop/home_shared.rs): initial; cache/live/error/stale, waiters/throttle/settings/owner state and fake RPC checks; 22 original async store checkpoints and 23 login/helper transitions compared via [account_state.rs](src/account_state.rs); localized time, Account/composer/settings-event wiring, full auth/routing, animated progress, tooltips and pixels open |
| Customize Home toolbar / clear-home button | [DesktopHomeEditor](../mac/Sources/Features/Home/DesktopHomeEditor.swift), [HomeLayout](../mac/Sources/Features/Home/HomeLayout.swift), [HomeLayoutPreview](../mac/Sources/Features/Home/HomeLayoutPreview.swift) | [home_editor.rs](src/desktop/home_editor.rs), [home/layout.rs](src/home/layout.rs): initial draft/presets/toggle/reorder/reset/undo/Done/Cancel, off-thread atomic preferences; compiled normalize/move coverage; native sheet/focus scrolling, drag/input, AX announcements, motion, pixels and persistence-on-Linux open |
| All sections hidden | `HomeView.clearHome` | `home_panels.rs`: initial clear card/customize entry; visual/input check open |
| Continue | [DesktopHomeWork](../mac/Sources/Features/Home/DesktopHomeWork.swift), `RootView.recentHomeWork` | [home_work.rs](src/desktop/home_work.rs), [home/work.rs](src/home/work.rs), [work/destination.rs](src/work/destination.rs): initial rows/projection/current-state open gate, 864 availability/54 route/28 original row/open scenarios; ready/empty light/dark fixtures and source PNGs. Durable core in [continuity.rs](src/work/continuity.rs)/[preferences.rs](src/work/preferences.rs), with canonical scope/key support and source traces; [service.rs](src/work/service.rs)/[work_metadata.rs](src/desktop/work_metadata.rs) load scoped local metadata off-thread with stale-owner fences and per-window directory projection. Loaded local conversations now include private draft-aware facts; full chat/peer/access/cache feeds, actual destinations and input/AX/pixels remain unported or unverified |
| Pinned work + pin menus | [DesktopPinnedWorkSection](../mac/Sources/Features/Home/DesktopPinnedWorkSection.swift), `RootView.openPin` | Initial card/subtitles/open-vs-unpin targets in `home_work.rs`; source gates include account/access/saved/terminal state. [pins.rs](src/work/pins.rs) provides durable validation/capacity/key/label behavior; connected project pin/unpin and Home unpin use the shared worker (Mac/fixtures stay ephemeral). Complete loaded model feeds, conversation/terminal pin entry points, actual destinations and native input/pixels remain unported or unverified |
| Machines preview | [DesktopHomeMachines](../mac/Sources/Features/Home/DesktopHomeWork.swift), `HomeView.sectionView`, `onOpenMachine` | [home_devices.rs](src/desktop/home_devices.rs), [devices.rs](src/devices.rs): initial account rows, tri-state status, tooltip and keyed selection; 438 original model/row/icon cases and six selection cases compared; ready/empty light/dark GPUI fixtures plus source PNGs; pixels/input/AX and destination Devices screen unported or unverified |
| Getting started | [GettingStartedCard](../mac/Sources/Features/Home/GettingStartedCard.swift), [GettingStartedRail](../mac/Sources/Design/GettingStartedRail.swift), [InsightsModel.scan](../mac/Sources/Features/Insights/InsightsModel.swift) | Initial Home card and first-scan host action in [home_getting_started.rs](src/desktop/home_getting_started.rs) / [scan.rs](src/home/scan.rs): 8 source card states / 24 steps and action closures compared, strict synthetic host scan and guarded [Insights snapshot](src/insights.rs) refresh. The original scan body also compares across held success/error cases with controlled refresh/timer stubs. Sign-in/Account, complete Insights owner/UI, actual GPUI interleavings and error presentation, animated halo/grid, reduced motion, native control/input/AX and visual/pixel acceptance remain open. The current ghost grid is static. |
| Limits sharing suggestion | `HomeView` sync hint | Unported: signed-in/opt-in/dismissed/visible-provider conditions, persistent dismissal and Account action |
| Platform credential notice | [UsageKeychainNotice](../mac/Sources/Features/Home/UsageKeychainNotice.swift), [UsageKeychainNoticePolicy](../mac/Sources/Features/Home/UsageKeychainNoticePolicy.swift) | Linux equivalent unresolved; preserve explicit permission/recovery behavior where applicable, without invoking macOS credentials |

## Root presentations outside route switches

| Presenter / trigger | SwiftUI content | Linux status |
| --- | --- | --- |
| Share project | [TeamFolderShareView](../mac/Sources/Features/Teams/TeamFolderShareView.swift) via `RootView.sharingProject` | Unported; includes team management/open-project callbacks |
| Create worktree | [ProjectWorktreeSheet](../mac/Sources/Features/Workspaces/AddWorkspaceSheet.swift) via `worktreeProject` | Unported; local/remote protocol gate and returned-project selection |
| Saved conversation | [DesktopSavedConversation](../mac/Sources/Features/Work/DesktopSavedWork.swift) via `savedConversation` | Unported; reading/caching/availability and follow-on presentations |
| Chat link destination | [ChatLinkOpenSheet](../mac/Sources/Features/Workspaces/Chat/ChatLinkOpenSheet.swift) via `pendingChatLink` | Unported; remembered destination, cancellation and scope fence |
| Saved folder cache settings | [WorkFolderCacheSettings](../mac/Sources/Features/Work/WorkFolderCacheSettings.swift) via `savedFolder` | Unported; available/removed/remote states and cache changes |
| Search work | [DesktopWorkSearchPresentation](../mac/Sources/Features/Work/DesktopWorkSearchPresentation.swift) | Unported; global shortcut, query/results, selection/open and dismissal |
| Add project | [AddWorkspaceSheet](../mac/Sources/Features/Workspaces/AddWorkspaceSheet.swift) | Initial generic local folder chooser only; actual local/remote/add sheet, draft and continuation unported |
| SSH connect from any route | [SSHConnectForm](../mac/Sources/Features/Machines/SSHLibraryEditors.swift) | Unported; credentials/trust, error/retry, session adoption and startup snippets |
| Incoming device access request | [DeviceAccessRequestSheet](../mac/Sources/Features/Machines/DeviceAccessRequestSheet.swift) | Unported; grant/reject/expiry/arrival while on any screen |
| Git sync sheet host | [GitSyncPresentation](../mac/Sources/Features/Workspaces/GitSyncPresentation.swift), [GitPushView](../mac/Sources/Features/Workspaces/GitPushView.swift), [GitPullView](../mac/Sources/Features/Workspaces/GitPullView.swift), [GitLFSSetupView](../mac/Sources/Features/Workspaces/GitLFSSetupView.swift) | Unported; enumerate each active/result/auth/conflict/LFS branch |
| Desktop open/deep-link unavailable alert | `RootView` alert, [DesktopOpenRequest](../mac/Sources/App/DesktopOpenRequest.swift) | Unported; external activation/ownership/delayed resolution and error recovery |

## Expansion and acceptance work

For each unported family, expand this ledger to one row per concrete menu,
popover, sheet and dialog before its implementation is considered complete.
Record each item's identifier, label, glyph, shortcut, order/separators,
selection, visibility/enablement expression, action, destructive confirmation,
state fixture and owning Linux file. Read conditional desktop branches; a text
search alone cannot establish desktop reachability.

Immediate expansion owners include composer/model/permission/slash/setup and
transcript menus under `Features/Workspaces/Chat`, terminal/tab/file/browser/git
menus under `Features/Workspaces`, and feature-local editors/context menus in
Tasks, Notes, Workflows, Automations, Teams, Devices, SSH and Account. Saved-work
handoff/original-files/viewed-change/cache and unsent-writing sheets under
`Features/Work` are also unported. Simulator panes and remote host capability
gates reachable from the desktop workbench must be individually audited.

Every implemented row still needs the same synthetic fixture rendered by both
frontends at fixed size, scale and appearance, plus input/keyboard/focus and
accessibility checks. The measured system-medium selection issue is corrected
and all 149 current rounded width/line-box cases pass on macOS. Baseline/glyph
pixels, Linux font behavior and the unavailable preview capture environment
remain separate gates; a font-metric pass is not pixel signoff.
Native Linux Wayland/X11, IME/AT-SPI, distro/GPU, lifecycle/resource-limit,
startup/session/power and packaging gates remain open separately.
