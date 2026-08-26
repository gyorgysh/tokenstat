# Changelog

Every version of tokenstat: the CLI, desktop and mobile clients, host daemon,
and MCP server, which develop together under one version number. Stable
releases currently contain every CLI target and the macOS desktop app; Windows
desktop and Android builds remain previews. Newest first.

## [Unreleased]

### New

- Opening a computer, from its device page or from Workspaces, shows what it is doing: power, CPU, and memory read over the tunnel and not uploaded with usage, with open work and view screen beside them. On the Mac, a workspace that lives on another machine offers that machine's screen without a trip to Devices.
- Control a shared screen from an iPhone or iPad. One finger moves the pointer, tap clicks, two fingers tap for a right click and drag to scroll, long press then drag holds the button down, and pinch zooms in. A row of keys over the keyboard sends escape, tab, the arrows and sticky ctrl, opt, cmd and shift, and a pull on the bottom edge brings that row back over a full-screen picture. Driving a desktop is at sixty pictures a second and every pointer move is delivered as it happens, on the same bandwidth a session watched from an armchair costs.
- SSH is a place in the sidebar rather than a panel over Devices. Hosts, keys, snippets and trusted servers are sections you navigate to, folders nest under Hosts, the list gets the whole window and the editor opens beside it. Leaving for Home and coming back keeps you where you were, and the rest of the app stays usable throughout.
- The encrypted vault is one quiet row above the server list instead of three buttons, two of them destructive, at the top of a screen you open to add a server. Setting it up, replacing the recovery code and deleting it live one click away, each with room to say what it costs.
- Recovery is confirmed in two steps. The code is on screen to be written down, then off screen while it is typed back, so confirming cannot be done by reading.
- A saved server carries what it needs to connect: which key to use, which server to reach it through, a starting directory, environment variables, a keepalive, and a colour and folder to find it by. Snippets can ask for `{{values}}` when they run, so one snippet covers every server.
- Import servers from `~/.ssh/config`. tokenstat reads that file and never writes to it, and shows what it found before saving anything.
- Trusted servers are listed with their fingerprints, and any of them can be forgotten, so a key that changed can be confirmed again rather than quietly accepted.
- A key shows its fingerprint, and its public half can be copied in one press for pasting into a server's authorized_keys. On iPhone and iPad, a long press on a key or a snippet offers the same actions as the rest of the list: edit, copy, run a snippet on connect, delete.
- Android SSH gains search, folders on saved servers, port and starting directory on the add form, and a snippet editor with room for a real command.
- Every control is the app's purple. Switches, pickers, focus rings, selection and prominent buttons were system blue everywhere except eight hand-picked places.

- SSH typing appears as it is typed rather than a round trip later. A character is drawn locally and replaced by the server's own echo when it arrives, which makes a shell on the other side of the world feel like one in the next room. Nothing is drawn until the line has proved that it echoes, so a password prompt never shows a character of a password.

### Fixed

- A long session no longer fails with "Too many open files". The app asked the system for a fraction of the descriptors it is allowed, and the first thing to lose the race, usually a screen session opening, reported it as a problem with a file.
- The screen viewer's full-screen control is the glyph every platform draws for it. Spelled out, it was the only sentence in a row of symbols, and it reflowed the toolbar the moment it was used.
- The held-mouse-button notice no longer sits on top of the key row's own Release button and cut its last key in half. It appears where that row is not on screen, which is where a held button would otherwise be invisible.
- The encrypted vault row says how many records it holds at the trailing edge, with a placeholder while the account is asked. It used to read "not set up" until the answer arrived and then rewrite itself.
- The app no longer reports "unknown method" when this machine's background helper is older than the app. It checks the helper on launch, replaces it, and says something a person can act on if it cannot.
- Screen control can actually be turned on. The toggle was disabled as soon as the picture arrived, which was before anybody could reach it, so sessions were always view only.
- Turning on view or control asks macOS for the permission it needs, right then, with the prompt that names Tokenstat. Screen Recording used to be requested only once a stream was already failing, and Accessibility was never requested at all, so control silently did nothing. The card now says which permissions are granted, and says out loud that the app has to be open for its screen to be shared.
- Double clicks, right clicks and scrolling reach the shared Mac, rather than being flattened into a press and a drag.
- SSH vault setup no longer offers migrate (that path was never in a release). If you did not save the recovery code, or cannot open the vault, you can drop it and create a new one.
- The unpaid SSH empty state now pitches the vault the same way tasks and notes pitch their screens, with a path to plans.
- Buttons across the SSH and screen surfaces are one height and line up. A glyph no longer makes a button taller than the one beside it, and destructive actions look like actions rather than links.

## [0.6.9] - 2026-08-24

### New

- A preview Windows desktop app. Its development build installs for the current
  user, adds a Start Menu shortcut, and exercises the update path while the
  platform matures outside stable GitHub Releases.
- A preview Android client. Pair it to an account the way the iPhone does, then
  use this Mac from the phone: terminals, folders, and the rest of the remote
  surface.
- SSH from the Mac. Save hosts, open a session, keep credentials in an
  encrypted vault that can follow the account, and import machines from AWS
  and DigitalOcean.
- Share this Mac's screen with another Apple device on the account. Switch
  displays, send the system audio, copy both ways, and send a file without
  leaving the session.
- Install the host as a service on a machine that has no desktop session, so
  it answers after a reboot the same way Always-on host does on a Mac mini.

### Fixed

- Opening the Mac app on a recent macOS beta no longer aborts while the
  window is first laid out. The splash used to animate the split view in, and
  AppKit refused the extra constraint pass.

## [0.6.8] - 2026-08-21

### New

- An agent that stops to ask you something can say so. Turn notifications on
  in Account and a question waiting in a terminal reaches you the way a
  finished run does, and it takes itself back when you open that terminal.

### Fixed

- A live session's tokens and cost are counted once per request. A harness
  that rewrites a request as it streams was being added up chunk by chunk, so
  a session read about twice what the tool itself reports.
- The context bar stays empty for a tool that only records a session running
  total, rather than filling to hundreds of percent. Tokens and cost for those
  sessions are unaffected.
- A terminal no longer repaints and loses its scroll position when a notice
  appears. The live notices float over the bottom of the terminal instead of
  taking height from it, each one fades on its own rather than waiting to be
  clicked away, and the paused notice waits until output has genuinely
  stalled.
- "Needs attention" goes away when the question does. It used to sit there
  until the agent printed enough to push the prompt out of view, and opening
  the session now clears it as well.
- The plans screen no longer shows an error about a purchase nobody made,
  left behind by a transaction the App Store re-sent while the phone was
  offline or signed out.
- One Mac going to sleep no longer freezes another. Calls to a machine that
  has stopped answering used to take every connection the app had, so
  terminals stopped drawing and screens stopped filling until they gave up.
  They now have a share of their own and a time limit, and an unreachable
  machine is reported as unreachable instead of as silence.
- The tasks list arrives when the count does. The board no longer waits behind
  a report, a sync, or another machine asking this one for a report.
- A workflow no longer announces every step it takes on the way. It tells you
  how it went when it is done, once, on this Mac and on your phone.

## [0.6.7] - 2026-08-20

### New

- Four more tools are read straight off disk: Pi, Hermes Agent, Kilo Code and
  the DeepSeek Harness. Each one is counted as its own tool, so a machine
  running Kilo Code and OpenCode side by side sees two rows rather than one.
- Tell me when a run finishes. The Mac watches its own automations and
  workflows and says so when one ends, fails, or stops to ask a question. It is
  off until you turn it on, in Account, and nothing about the run leaves the
  machine. iPhone and iPad carry the same switch, which starts arriving once
  notifications are switched on for your account.

### Fixed

- Usage from a tool that keeps a SQLite database is picked up on the next scan
  instead of waiting for that database to be tidied up, which could be hours.
  This was quietly losing recent work for OpenCode, Cline, Copilot CLI and Zed.
- A machine is only called unreachable when it was answering and stopped, and
  the card names which one. A phone or tablet paired to the account no longer
  reports a computer as unreachable, and a machine that is simply off is left
  to the Machines screen to say so.
- Stop and close takes the session off screen at once rather than waiting on
  the computer to answer.
- A full-screen agent no longer swallows the window's own clicks, so a
  confirmation dialog flashes and the window keeps answering.
- The phone's terminal keys no longer cover the last lines of output, and notes
  are not pressed against the field above them.

## [0.6.6] - 2026-08-19

### New

- A left sidebar on iPad when a keyboard is attached, drawing the same folder
  tree the Mac does, with keyboard shortcuts and pointer-density spacing.
- Notes get their own screen on the client, per folder, and a folder's note
  count now shows in its summary.
- One model for what the app believes about the network. Connection trouble is
  reported once, in one place, instead of once per subsystem, and a call fails
  fast when the device is known to be offline.

### Fixed

- The network verdict clears itself when the network comes back.
- Every device row can be renamed, including the one you are sitting at.
- No on-screen keyboard key on a terminal that already has a hardware keyboard.

## [0.6.5] - 2026-08-19

### New

- Close a session straight from the sidebar.
- Harness settings sheets corrected, with compaction on a slider rather than a
  number field.

### Fixed

- OpenCode: read the version 2 schema, and count a migrated message once rather
  than twice.
- iPad: the native intro, and no split view nested inside a split view.
- The global tasks screen is gone from iOS, where it duplicated the per-folder
  boards.

## [0.6.4] - 2026-08-19

### New

- Name any device on the account, from any surface.
- Every workspace gets its own Notes section.
- iOS: a colour-highlighted file editor, and drawn empty states instead of a
  sentence explaining the emptiness.

### Fixed

- The kitty keyboard announcement no longer leaks into the terminal emulator.
- The Sessions wireframe ends when the answer lands, rather than pulsing on.

## [0.6.3] - 2026-08-19

### New

- Hermes Agent and Kilo Code in the launcher, with their official marks. Hermes
  installs without its interactive setup wizard.
- Notes get their own screen, kept per folder or unfiled.
- Harness settings open from the launch tile badge, as a form rather than a
  popover.

### Fixed

- Terminal clicks are sent as SGR mouse events, so mouse-aware programs see them.
- Recovered Claude Code rows fold into Claude Code instead of appearing as a
  separate tool.
- A session meter with nothing in it reads `0% ctx · $0.00 · 0k` rather than a
  blank.

## [0.6.2] - 2026-08-19

### New

- Add, archive, and capture tasks from the phone.
- Session metering for Codex, OpenCode, and Antigravity.
- iPad gets the phone's tab bar, and the terminal keyboard gains shift and
  back-tab.

### Changed

- A session row leads with context used, not with money.
- A note stays on the board it was written on.

### Fixed

- The host stopped rescanning every log on every poll, and the catalog's context
  windows are indexed at load. Both were paid on every single reading.
- The sidebar's board counts are cheap and quiet.
- A context reading survives the catalog not knowing the model.

## [0.6.1] - 2026-08-18

### New

- Run workflows and automations from the phone.
- The iPad gets a workspace of its own for those jobs.

### Fixed

- iOS listens for `PurchaseIntent`, so Streamlined Purchasing can be turned off.

## [0.6.0] - 2026-08-18

### New

- Workspace navigation, rebuilt. A workspace opens to its own sections in the
  sidebar, the every-folder screens fold under one Global group, and a scoped
  board says which folder it is showing.
- Open tabs are kept across launches.
- The global task board gets a workspace selector.
- iOS opens a folder to the same seven sections the Mac lists, and can read a
  change on the phone.

### Fixed

- A session is metered from when it started, not from the folder's whole
  history.
- A new session fills the empty half of a split rather than replacing the other.
- iOS reads a folder's git state instead of the snapshot it was tapped with.

## [0.5.0] - 2026-08-17

### New

- Workflows: graphs that compose agents, automations, shell commands, and a
  person gate. A library that draws them as graphs, a rebuilt builder, condition
  and bounded loop nodes, a workspace picker at run time, and live output you
  can follow.
- Designing a workflow from a prompt defaults to a cheap fast model, and
  produces a draft rather than a run.
- Automations get a rhythm and a history.
- The Devices screen is drawn as a network.

### Fixed

- The workflow editor is usable at any window size, and the canvas stays off
  iOS, where it had nothing to draw on.

## [0.4.4] - 2026-08-17

### New

- Reorder workspaces by dragging, and close tabs from the menu.
- Launcher tiles you hid stay hidden, stored on the host, so a second machine
  agrees.
- iOS gets the desktop's harness marks.

## [0.4.3] - 2026-08-16

### New

- Hide agents you do not use, archive finished cards, and reuse the dock tile.

### Fixed

- Dock relaunch after an update is hardened, and the updater waits for the
  OpenCode TUI rather than racing it.

## [0.4.2] - 2026-08-16

### New

- Run tasks in front, pin models, and fit a tiled window.

### Fixed

- Run buttons show on completed tasks, and the move labels say what they do.
- Prompt flags reach interactive Antigravity and OpenCode sessions.

## [0.4.1] - 2026-08-16

### New

- Automations can queue jobs, cards reorder, and transcripts are parsed into
  tool rows.
- Panel marks unified across the app, with save confirmation on cards.

### Fixed

- A queued job cannot race another, and it inherits the scheduler's budget.
- Runs persist before draining, and the budget is honoured rather than reported.
- Headless runs skip permission prompts instead of hanging on them.

## [0.4.0] - 2026-08-16

### New

- Automations: recurring agent jobs owned by the daemon, with live model lists,
  streamed output, and a budget each one stops at.
- Plan limits get their own share card.
- Pin today, pin a launch tab, and keep the inspector open across destinations.
- Selected local models are passed into the launchers that support them.
- Uninstalled launcher tiles hide behind a plus.

### Fixed

- Home pins and task drafts survive switching screens.
- Streamed automation text stays joined, and list timeouts are reaped.

## [0.3.13] - 2026-08-15

### Fixed

- An install that fails now says so, and the installer's working tree is cleaned
  up rather than left behind.

## [0.3.12] - 2026-08-15

### New

- Always-on host is a switch on the Devices screen, and iOS plans load fast.
- Account pages open inside the app, and deleting an account signs you out with
  a confirmation.

### Fixed

- The scheduler respects the always-on host's power policy.

## [0.3.11] - 2026-08-15

### Changed

- The host daemon stops with the app unless you asked for always-on, so a closed
  laptop cannot start remote shells.

### Fixed

- The always-on toggle fails loudly if launchd does not follow it.

## [0.3.10] - 2026-08-14

### New

- Smoother plan switching, session handling, and tunnel recovery.

### Fixed

- Live sockets stay live, closing is honest, and a live plan is reported as one.

## [0.3.9] - 2026-08-14

### New

- Native App Store subscriptions on iOS.
- Harness marks and a heatmap freshness line.
- The free plan keeps a year-shaped heatmap rather than a stub.

### Fixed

- The Claude Code login is found across Keychain items, not just the first.
- A live web plan blocks StoreKit, so nobody is sold the same thing twice.

## [0.3.8] - 2026-08-14

### New

- The Mac stays awake only for inbound remote work, and sleeps again after.
- Rebuilt product intro on iOS.

## [0.3.7] - 2026-08-13

### Changed

- Remote reach moves to Patron.
- The Legend mark is redrawn as a crest shield.

### Fixed

- A successful sync is no longer reported as a rate limit, and a row count of
  429 is a row count.
- Host silence shows in the footer instead of raising an alert.

## [0.3.6] - 2026-08-13

### New

- LM Studio and Ollama say why they are empty instead of showing nothing.

### Fixed

- The tunnel tries every resolved address, bounds its DNS, and aborts a stalled
  handshake.
- Release downloads follow redirects; snapshot fetches deliberately do not.
- A phone counts as a device slot.
- The price book refreshes at launch without needing the CLI installed.

## [0.3.5] - 2026-08-13

### New

- Edit a workspace file on iPhone and iPad.
- Legal pages open without leaving the client.

### Fixed

- The editor no longer rewrites text while an input method is composing.
- The account's plan limits stay current with no window open.
- One clock drives every relative time, and the terminal stops costing more the
  longer it runs.

## [0.3.4] - 2026-08-12

### Fixed

- Terminal output is lossless, with the backpressure gaps closed, and stays live
  through interruptions.
- The tunnel bounds its backpressure, holds one starter at a time, and clears
  held credentials on logout.
- Recovered days written by an older build can leave the machine again.

## [0.3.3] - 2026-08-12

### New

- The archive keeps seven daily copies of itself, logrotate style, because it
  cannot be rebuilt once the tools that wrote your transcripts delete them.
- Per-day and lifetime vendor totals of our own, kept next to the vendor rollup.
- A day that was worked but cannot be priced now looks like a worked day in
  every view.
- Terminal panes accept dropped files.

### Fixed

- Recovery restores only what is lost, and refuses a reading that cannot be true.

## [0.3.2] - 2026-08-12

### New

- A mobile workspace surface with a terminal, files, and ports.
- Plan limit sync, and phone reach to a host.
- Pull to refresh everywhere, at a rate a thumb cannot abuse.
- Devices are named properly, and a host opens from its page.

### Fixed

- Connect and disconnect report the truth.
- Terminals keep draining under a full-screen game, and stay responsive when you
  come back.

## [0.3.1] - 2026-08-11

### New

- The iOS client, with the devices and insights screens on a phone.
- The host can run as a client with no archive of its own.
- The account breaks down by model, harness, and day.

### Fixed

- An update is verified against the build it replaces.

## [0.3.0] - 2026-08-11

### New

- The workspace sidebar is rebuilt around live sessions, and a session reports
  whether it is actually working.
- A real About window, and long breakdowns are paged.

### Fixed

- Workspace terminals stay mounted across destinations, and keep their
  scrollback.

## [0.2.9] - 2026-08-10

### New

- The working tree review gets a tab of its own, showing who wrote each commit
  and opening the one you click.
- Automation schedules expand to wake-compatible frequencies.

### Changed

- Destructive actions ask first, and the accessibility pass that came with it
  covers the same screens.

### Fixed

- Secrets, login URLs, redirects, and updates hardened; socket requests capped
  and workspace paths contained.
- Scan and sync no longer wait on the session mutex.

## [0.2.8] - 2026-08-09

### New

- Sidebar toggle marks, shortcuts, and a hover path bubble.

### Fixed

- The white flash when switching, the ghost overlay on Cmd+B, and the stock
  sidebar toggle painting before it could be neutralised.

## [0.2.7] - 2026-08-09

### New

- A logo splash, then pulsing wireframes, then content, so the first frame is
  never an empty window.
- Retry or download by hand when an update fails.

### Fixed

- Terminals start without an empty blink, warm shells are kept ready, and a
  shell spawn never blocks on the login environment.

## [0.2.6] - 2026-08-08

### New

- Pi in the launcher.
- The console shows the moment a session is requested.

### Fixed

- Unnamed machines take a name from what this Mac knows.
- The price book reloads after the daemon refreshes it.
- The launcher catalog compiles on Windows.

## [0.2.5] - 2026-08-07

### New

- Muse in the launcher.
- An open source licenses sheet in Account.
- The price book refreshes automatically from the daemon.

### Fixed

- A Disconnect stays disconnected until an explicit Connect.
- The multiplexed tunnel stops losing channels and streams.
- The dock icon refreshes after an in-place update.

## [0.2.4] - 2026-08-07

### New

- Remote machines: a persistent multiplexed tunnel, remote terminal sessions,
  directory registration, and a host-aware launcher, so a folder on another
  machine behaves like a local one.
- Open a remote machine's localhost port in a browser tab.
- A presence light before every machine name, and account device rows.

### Fixed

- Channel buffers and proxy listeners are bounded, and targets stay loopback-only.
- A dead peer's folders drop out of the sidebar.

## [0.2.3] - 2026-08-06

### New

- Responsive layout, a floating inspector, and an agent run polish pass.

### Fixed

- An audit pass over terminal colours and app-native controls.
- Shorter lock scope, cached transcript parsing, and deduped fetches.

## [0.2.2] - 2026-08-06

### New

- Workspaces onboarding, a launcher toggle, bypass permissions, and a responsive
  layout.
- A heatmap day-detail popover on hover, sized to the display.

### Fixed

- The host, the updater, the layout, and the account flows all self-heal rather
  than needing a restart.

## [0.2.1] - 2026-08-05

### Fixed

- A crash, a lag, and seven other defects reported from v0.2.0 testing.

## [0.2.0] - 2026-08-05

### New

- The macOS desktop app. Home, Insights, workspaces with a file tree and git
  history, agent sessions in a real terminal owned by a host daemon, and an
  in-app browser.
- Every screen draws as a wireframe while it loads.
- The app offers to move itself into Applications on first launch.
- An expired Claude Code login is renewed rather than reported.

### Fixed

- Bridge calls get their own threads, a timeout, and a lock.
- Folders and terminals stay off the session lock, and the PTY output buffer is
  trimmed in blocks rather than on every read.

## [0.1.3] - 2026-08-03

### New

- A model catalog: publisher, context window, capabilities, and public benchmark
  scores for the models in your archive, with faster rate lookup behind it.
- Colour and box drawing degrade on terminals that cannot do them.

### Fixed

- Every HTTP client has a connect timeout.

## [0.1.2] - 2026-08-02

### New

- List rates are fetched as a hosted snapshot rather than shipped in the binary.
- Cache write tiers are emitted, and Cursor's automatic pricing is corrected.

## [0.1.1] - 2026-07-31

### Fixed

- The installer runs under dash on Linux, on macOS's bash 3.2, and detects the
  architecture on Windows without relying on RuntimeInformation.
- Scheduled sync is hardened and repairs a previous install.

## [0.1.0] - 2026-07-30

### New

- First release. A local usage archive with parsers for every supported AI
  coding tool, one normalized schema, and reports by day, week, month, model,
  project, and session.
- A full-screen interactive client that refreshes the archive on open.
- Vendor fetches for the sources that cannot be read off disk, and opt-in
  profile sync to tokenstat.ai.
- An MCP server over the same core, so an agent can query the archive.
