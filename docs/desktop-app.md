# tokenstat desktop: plan for the base app

Status: proposed. Mac first, Windows deferred, iPad and iPhone designed for but
not built yet. See [`licensing.md`](licensing.md) for the App Store dependency.

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

- Not an IDE. There is no editor, no language server, no debugger. It opens
  files in your real editor.
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

The second thing that follows from the existing core: the app is a **fleet**
view, not a machine view. The sidebar groups workspaces by where they run, and
a workspace on another machine looks and behaves the same as a local one. That
is what makes "remote management" true rather than aspirational, and it is why
the host daemon in the architecture below is not over-engineering.

## Information architecture

Three columns, standard macOS split view, native window chrome.

**Left rail: what exists.**

- Workspaces, Automations, Fleet, Insights
- The workspace list grouped by host: this Mac, each connected machine, cloud
  runners later. Each row carries its branch, its diff stat, and its spend.
- A live-vs-idle dot per workspace, driven by the host daemon.

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
- Diff stat against the base branch, per-file add and delete counts.
- Actions that hand off rather than replace: open in editor, run, create PR.

**Insights** is where the existing reporting lives: spend by model, project,
tool and period, across the fleet. It is the CLI's report surface, redesigned
for a window and for more than one machine.

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
remote case, which belongs with M6 rather than here.

**M4. Workspaces.** Folder picker, file tree, git status and graph, the Files
and Changes panels. Still no terminal. Product identity gets decided here, so
give it room.

**M5. Sessions.** SwiftTerm over host PTY sessions, agent launch profiles, the
tab bar, and the live per-session meter. This is the milestone the product is
actually for.

**M6. Fleet.** A second machine's workspaces in the same sidebar. Once this
works, the iPad client is mostly a layout exercise.

Windows sits after M6 and needs a real audience check before it starts. When it
comes it is a UI shell over the same daemon, not a rewrite. That is the whole
reason for the split.

## Risks and open decisions

- **Distribution.** The Mac app almost certainly cannot be sandboxed, because
  a sandboxed app cannot spawn arbitrary user binaries or read arbitrary
  project directories without severe entitlement contortions. That means
  Developer ID and notarized from tokenstat.ai, not the Mac App Store. The
  signing identity already exists. Confirm this before M1 ships, because it
  changes the installer story.
- **Where the meter's numbers come from during a live session.** The archive is
  built by scanning logs after the fact. A live per-session meter needs either
  a tail-follow mode on the active log or a scan triggered on file change.
  Decide before M5, and prototype it during M4 to be sure the latency is
  acceptable.
- **The remote transport.** M6 needs authenticated machine-to-machine
  connections. Whether that is direct, relayed through tokenstat.ai, or both,
  is a product and privacy decision that touches the sync privacy claim. It
  needs its own document, and the answer should not be improvised at M6.
- **Repository boundary.** `WORKLOG.md` currently says the native client lives
  outside this repository. That predates this plan. The shared crates clearly
  belong here. Decide whether `apps/mac/` does too, or whether the Swift side
  gets its own repository consuming published crates. Recommendation: same
  repository, because for the first year the crate and app changes will land
  together far more often than not.
