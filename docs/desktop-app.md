# tokenstat desktop: plan for the base app

Status: active. M0 through M5 are built on macOS. M6 onward is planned. Windows
is deferred, and iPad and iPhone are designed for but not built yet. See
[`licensing.md`](licensing.md) for the App Store dependency.

"Fleet" was the working name for the machines surface. It is called **Machines**
now, in the UI and here. One less coined word to explain.

## What it is

**Remote management and monitoring for AI agentic workflows.**

You keep several agents working across several machines. Some run on this Mac,
some on a server, some in the cloud. Today you find out what they cost after
the fact, from a CLI, one machine at a time, and you find out what they are
doing by having a terminal tab open for each one. The app collapses both into
one surface: start the work, watch it run, and see what it is burning while it
burns.

The repository already has the hard half. `Engine` normalizes every agent's log
format into one schema, prices it, and aggregates it, and `tokenstat-sync`
already carries that across machines. What is missing is the ability to
*start* and *watch* the work, rather than only account for it afterwards.

## What it is not

- Not a full IDE. It has a real code editor for workspace files, with syntax
  highlighting, line numbers, find and a diff-aware gutter, but no language
  server, no completion and no debugger. It can also hand a file to your real
  editor.
- Not a CLI wrapper. It does not reimplement `tokenstat report` as a window.
- Not a port of the TUI. The TUI stays, and stays good. The GUI is a different
  information design, not the same panels with mouse support.
- Not a chat client. It runs the agent CLIs you already use, in a terminal,
  as themselves.

## The thing only this app can do

Every comparable tool shows workspaces, terminals and diffs. None of them know
what any of it cost, because none of them own a normalized cross-tool usage
archive. tokenstat does.

So the rule for the whole design: **no surface shows work without showing what
it is burning.** A workspace row carries its spend. An agent tab carries a live
session meter. An automation carries a budget and stops when it hits it. The
diff panel says what those 1,128 added lines cost to generate.

The second thing that follows from the existing core: the app is a view of
**every machine at once**, not of this one. The sidebar groups workspaces by
where they run, and
a workspace on another machine looks and behaves the same as a local one. That
is what makes "remote management" true rather than aspirational, and it is why
the host daemon in the architecture below is not over-engineering.

## Information architecture

Three columns, standard macOS split view, native window chrome.

**Left rail: what exists.**

- Home, Automations, Machines, Insights, then the workspace folders below them.
- There is no "Workspaces" row among the destinations. The folder list *is* that
  navigation, and a row that only selects the first folder is a row that repeats
  the list under it. The destinations group carries no section label either: the
  app had a `WORKSPACE` label over the destinations, a `Workspaces` destination
  and a `WORKSPACES` folder section, which is three headings for two ideas.
- The workspace list grouped by host: this Mac, each connected machine, cloud
  runners later. Each row carries its branch, its diff stat, and its spend.
- A live-vs-idle dot per workspace, driven by the host daemon.

**Home** is what the window opens on. Not Insights, and not an empty Workspaces
pane on a fresh install. The question people have when they open the app is what
they have left before they start work, and that is a different question from
what they spent last month:

- Profile: avatar, handle, plan, sync state.
- The activity heatmap and the streaks beside it, on the accent ramp rather than
  the CLI's terminal colours. Clicking a day filters Insights to that day.
- Plan limits and archive-backed Plan usage, moved here from Insights, because
  "what is left of the allowance" is the same question as the rest of this
  screen and it was buried under two report tables.
- Today and this week, plus any running sessions.

Insights keeps the reporting: periods, breakdowns by model, project, tool and
session, the split tables and the inspector.

**Center: what is happening.**

- One tab per agent session: claude, codex, cursor-agent, opencode, copilot,
  amp, gemini. Tabs are sessions, not tools, so two Claude sessions on
  different branches are two tabs.
- The tab bar carries a per-session token and cost meter that updates as the
  session runs. This is the single most distinctive element in the product and
  it should be designed first, not bolted on.
- Below it, the terminal. The agent CLI runs as itself, unwrapped.

**Right: what changed.**

- Files, Changes, Review, matching what a reviewer actually does in order.
- A focused code editor with explicit Save, kept separate from the terminal.
- Diff stat against the base branch, per-file add and delete counts.
- Actions that hand off rather than replace: open in editor, run, create PR.

**Insights** is where the existing reporting lives: spend by model, project,
tool and period, across every machine. It is the CLI's report surface,
redesigned for a window and for more than one machine. The plan limit and plan
usage cards that grew here belong to Home, above.

## Architecture

Mac first does not mean Mac only. The split below costs almost nothing now and
is what makes iPad, iPhone and Windows additive rather than rewrites.

```
crates/tokenstat-core/       unchanged, no network              shared
crates/tokenstat-sync/       gained device_start/device_poll    shared
crates/tokenstat-workspace/  NEW  workspace model, git status,
                                  graph, file tree, discovery   shared
crates/tokenstat-pty/        NEW  portable-pty sessions,
                                  agent launch profiles         desktop only
crates/tokenstat-highlight/  NEW  tree-sitter spans for the editor.
                                  Kinds, not colours.           shared
crates/tokenstat-host/       DONE protocol, session, dispatch,
                                  and a unix socket daemon. Gains
                                  workspaces and PTYs at M4/M5,
                                  and a network transport later.
crates/tokenstat-ffi/        DONE C ABI bridge, JSON in and out.
                                  Links a network stack, which core
                                  must never do. Watch that boundary.
crates/tokenstat-cli/        unchanged, becomes one more client
apps/mac/                    DONE SwiftUI universal app
```

Three decisions worth stating explicitly.

**The Mac app is a client of a local daemon, from day one.** Not for IPC's
sake. iOS and iPadOS cannot fork or exec, so a mobile client can never run an
agent locally and is inherently remote. Building the Mac app as a monolith
means rewriting it when mobile lands. Building it against a socket means the
iPad app is the same SwiftUI code pointed at a different address. It also gives
Automations somewhere to live that survives the window being closed, which they
need anyway.

**The bridge speaks the daemon's protocol, not a generated binding.** The first
draft of this plan called for UniFFI. It was dropped before implementation, in
favour of a C ABI carrying JSON: `tokenstat_ffi_call(method, params) -> json`,
using the same method names and the same response envelope the daemon will use.

That buys three things. Moving a front end from in-process to remote becomes a
change of transport rather than a rewrite of the client layer. One set of wire
types gets tested instead of two. And the dependency budget stays at zero,
since `serde_json` is already in the tree, with no version-matched codegen
binary in the build. What it costs is compile-time type checking across the
boundary, which `dto.rs` and the Swift `Codable` structs recover most of by
being the only definition of the shape on each side.

**Two channels, deliberately.** Control plane through the bridge: reports,
workspaces, git status, auth. Data plane raw over the socket: PTY bytes. Do not
route per-keystroke terminal output through the JSON bridge.

**SwiftTerm for the terminal.** It runs on macOS and iOS, and it can be driven
from an arbitrary byte stream rather than only from a local PTY, so one view
renders a local session and a remote one with no branch in the UI layer. Rust
owns the process through `portable-pty`. Writing a Metal text grid instead is a
month of work to land slightly behind SwiftTerm, and worth reconsidering only
if measurement shows it cannot keep up.

## Milestones

Each one is meant to be independently shippable, so the project survives being
interrupted.

**M0. Licence.** Land the exception while authorship is still sole. Blocks
nothing else, but gets impossible later. See [`licensing.md`](licensing.md).

**M1. Read-only window. Built.** `tokenstat-ffi` plus a SwiftUI universal app
showing Insights and nothing else: reports, charts, scan. No terminal, no
workspaces, no daemon. It proved the bridge, the Xcode and Cargo build
integration, and the visual language, for very little money, and its figures
were checked row by row against `tokenstat models` on the same archive.

Still open before it could ship to anyone: an app icon, a Sparkle-style update
path or an installer, a Developer ID signed build in the release workflow, and
a decision on whether the window should open on Insights or on Workspaces once
the latter exists.

**M2. Account. Built.** Sign in, profile, machines, sync status and sync now.

This milestone was planned around `ASWebAuthenticationSession` and Keychain
work in Swift. Both turned out to be wrong, in useful ways:

- **The auth is a device-code grant (RFC 8628), not redirect-based OAuth.**
  `ASWebAuthenticationSession` exists to catch a redirect back to a custom URL
  scheme, and there is no redirect here. The right shape is the one the CLI
  already uses: ask the server for a code, show it, open the system browser,
  poll until it is confirmed. So the app shows the user code and polls.
- **The token was already in the Keychain**, written by `tokenstat-sync`. The
  app needed to store nothing. Better than the plan: the app and the CLI read
  one entry, so signing in on either signs in both, and there is no second
  copy of a credential to leak or to go stale.

What did need building was splitting `profile::login` into `device_start` and
`device_poll`. The original owned stdout and the clock, printing the code and
blocking until confirmation, which a window cannot do. `login` now composes the
two halves, so the CLI is unchanged.

**M3. The daemon. Built.** `tokenstat-host` now owns the protocol, the session
and the dispatch. `tokenstat-ffi` is a transport over it rather than the place
methods live, and `tokenstat-host::server` is a second transport over the same
function, so a method cannot exist over one and be missing from the other.

Line-delimited JSON over a unix socket at `<data dir>/host.sock`, mode 0600,
with request ids echoed back. Verified against the live archive: the daemon
returns the same 9.01B tokens and 1193 sessions the app shows.

**Lifetime is launchd's**, via `scripts/install-host-agent.sh`, as a user agent
with `KeepAlive` and `RunAtLoad`. A daemon the app spawns dies with the window,
and an Automation that stops when you close a window is not an automation. A
user agent rather than a system daemon because it runs as you, reads your logs,
and has no business existing before you log in.

Still to do: the app talks to the in-process bridge, not the socket. That is
deliberate. Pointing it at the socket means deciding what happens when no host
is running, and the honest answer is a local fast path with the socket as the
remote case, which belongs with Machines rather than here.

**M4. Workspaces.** Folder picker, file tree, git status and graph, the Files
and Changes panels. Still no terminal. Product identity gets decided here, so
give it room.

**M5. Sessions. Built.** SwiftTerm runs host-owned PTY sessions in the
Workspaces pane, with a session strip and agent launch profiles. Keystrokes,
output, resize, focus, scrollback, and multiple sessions all work through the
host's `pty.*` methods over the existing bridge. The terminal stays mounted
while tabs switch, so changing sessions does not restart or resize the process.

A file opens in the centre pane beside the sessions, with an explicit Save. That
much shipped with M5. It was a bare `TextEditor`, which is why the editor is its
own milestone below rather than a line in this one.

The live per-session token and list-rate value meter is still open. It is
intentionally separate from the session surface because the archive is
scan-after-the-fact, while a meter needs tail-follow or scan-on-change data.

**M6. The editor.** `TextEditor` cannot carry a gutter, a find bar, per-document
undo or a highlighted line, so the first move is an `NSTextView` behind an
`NSViewRepresentable` and everything else follows from that.

Highlighting is computed in Rust, not Swift. `tokenstat-highlight` returns typed
spans over the bridge and the app maps a span kind to a theme colour, so the
iPad and Windows clients inherit it instead of reimplementing it, and there is
no Swift dependency to put through `check-app-licences.sh`. The crate returns
**kinds, never colours**: a highlighter that knows about the theme is a
highlighter that has to ship a theme.

The scope is a good editor and not an IDE: highlighting, line numbers,
find and replace, auto-indent, bracket and quote pairing, comment toggle, and
changed-line marks in the gutter read from the diff the app already parses.
No language server, no completion, no refactoring.

Two performance rules, because both failure modes are easy to reach. Highlight
runs off the main actor on a short debounce, never per keystroke. Above a size
threshold a file opens unhighlighted and *says so*, rather than opening slowly.

**M7. Home and the polish pass.** The heatmap the CLI already draws, moved to
core so the app can draw it too, plus the Home screen described above and one
pass over the visual language. See "The polish pass" below for what that means
concretely, because "make it nicer" is not a milestone anyone can finish.

**M8. Machines.** A second machine's workspaces in the same sidebar. Once this
works, the iPad client is mostly a layout exercise. It needs the remote
transport decision written down first, and that decision is listed under open
risks below rather than improvised here.

**M9. Automations.** Recurring agent jobs owned by the daemon, each with a
budget it stops at rather than one it reports after. The daemon already runs
under launchd, so they have somewhere to live with the window closed. The rule
from `CLAUDE.md` is unchanged and load bearing: nothing in `gitwrite` runs on a
timer. An automation may run an agent, and the agent may ask a person.

**M10. Ship it.** App icon, an update path, a Developer ID signed and notarized
build in the release workflow, and an installer. The signing identity already
exists. Until this milestone the app is a thing that builds, not a thing anyone
can install.

Windows sits after M8 and needs a real audience check before it starts. When it
comes it is a UI shell over the same daemon, not a rewrite. That is the whole
reason for the split.

## The polish pass

Collected from reading the app rather than from taste, so each of these is a
place where two surfaces disagree and one of them has to change.

- **Errors have three treatments**: a red-tinted bar in the editor, `Banner` in
  Insights, orange caption text in the sidebar footer. One `Banner` with a
  severity, used everywhere.
- **The accent barely appears.** It marks selection and a couple of icons and
  nothing else. `Theme` gains a soft accent, a five-step heat ramp derived from
  the accent for the heatmap, and semantic success, warning and danger, so the
  green dot on a live session and the orange on an unsaved file stop being
  literal `Color` values written at the call site.
- **Every screen builds its own header.** One `ScreenHeader`.
- **`Card` is used in Insights and nowhere else.** Home, Account and the
  inspector adopt it, so the app has one panel and one corner radius.
- **Selection is expressed twice.** The sidebar has the accent bar, `TabStrip`
  has a top rule, the inspector tabs have neither. Pick one and apply it.
- **Empty states disagree.** `NotBuiltYet` is right, and the empty workspace,
  the empty folder list and a chart with no rows each look like something else.

## Risks and open decisions

- **Distribution.** The Mac app almost certainly cannot be sandboxed, because
  a sandboxed app cannot spawn arbitrary user binaries or read arbitrary
  project directories without severe entitlement contortions. That means
  Developer ID and notarized from tokenstat.ai, not the Mac App Store. The
  signing identity already exists. Confirm this before M1 ships, because it
  changes the installer story.
- **Where the meter's numbers come from during a live session.** The archive is
  built by scanning logs after the fact. The next meter slice needs either a
  tail-follow mode on the active log or a scan triggered on file change. It must
  preserve the parser boundary and never store conversation text.
- **The remote transport.** M8 needs authenticated machine-to-machine
  connections. Whether that is direct, relayed through tokenstat.ai, or both,
  is a product and privacy decision that touches the sync privacy claim. It
  needs its own document, written before the milestone starts rather than
  during it.
- **Tree-sitter's weight on the app's licence check.** The editor's grammars are
  a new set of third-party crates inside what `apps/mac` links, which is exactly
  the boundary `check-app-licences.sh` guards. The common grammars are MIT or
  Apache-2.0 and fine. Check each one as it is added rather than at the end,
  because the fix for a copyleft grammar is dropping that language.
- **Repository boundary.** `WORKLOG.md` currently says the native client lives
  outside this repository. That predates this plan. The shared crates clearly
  belong here. Decide whether `apps/mac/` does too, or whether the Swift side
  gets its own repository consuming published crates. Recommendation: same
  repository, because for the first year the crate and app changes will land
  together far more often than not.
