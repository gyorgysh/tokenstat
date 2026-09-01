# Changelog

Every version of tokenstat: the CLI, desktop and mobile clients, host daemon,
and MCP server, which develop together under one version number. Stable
releases currently contain every CLI target and the macOS desktop app; Windows
desktop and Android builds remain previews. Newest first.

The Unreleased section is always the complete, person-facing delta from the
latest `v<version>` tag to `main`. Work that has not appeared in a shipped app
still belongs there. When a release is tagged, close that delta under its
version and begin the next one, rather than reconstructing release notes from
commits at the end.

## [0.7.3] - Unreleased

### Fixed

- A newer phone that opens Chat or Pull requests on an older desktop now says
  which computer needs an update and shows a calm animated waiting state. It
  no longer starts loading a feature the host cannot answer and leaves an
  "unknown method" error behind.

- A pull request whose diff contains a diff, such as a patch fixture or a
  document quoting one, showed a file it does not touch and cut the real file's
  changes in half.
- A GitHub connection signed itself out every few hours. When GitHub renewed an
  authorization without issuing a fresh renewal token, the one already held was
  overwritten with nothing, and the next renewal had nothing to work with.
- A dropped network request said "pull requests are not connected" and offered
  a sign-in, for a connection that was fine.
- Reading a pull request no longer asks the machine who you are three times
  over. A credential is resolved once a minute rather than once per request,
  which on a machine authenticated through git's own credential helper removes
  a subprocess and a round trip from every read.
- Creating a branch from a starting point that begins with a dash is refused
  rather than handed to git as an option. The branch name was already checked;
  the starting point was not, and `--discard-changes` in that position throws
  away uncommitted work.
- The pull-request daemon caches for detail, timeline and diff are pruned. They
  were only ever added to, so a machine left running kept every diff it had
  ever shown.
- Grok replies read with doubled spaces ("I'll  run  that  command"). It sends
  a separator space between tokens and the next token's own leading space, and
  both were laid end to end.
- Every tool in a chat drew twice. A tool's start and its end are joined by a
  call id, and the id was written under one name and read under another, so no
  end ever found its start: one row sat running until the turn closed it, and
  a second row appeared beside it with the result. The same mismatch emptied
  every timestamp, which is what a tool's duration is measured from, and left
  cached tokens and cost reading zero on every conversation. On the archive
  here that was 186 tools drawn as 372 rows.
- Chat records one truthful end to a turn. Agent CLIs may call their own tool
  stream "cancelled" even when the process exits successfully; that no longer
  becomes a second failed turn or says the person pressed Stop. The host now
  owns the final `ok`, `error`, or `stopped` outcome, and an explicit Stop is
  kept distinct from a failure on macOS and iOS.
- Choosing no persona lasted exactly one conversation. A workspace with no
  default read as one nobody had set up yet, so the next chat quietly made a
  fresh persona and inherited it. A workspace can now say it wants none, and
  that answer is kept. Personas has a "New chats here" row that shows which
  persona new conversations inherit and offers "No persona" alongside them,
  replacing the "Make default" button, which could only ever say yes to
  whichever persona happened to be open.
- Committing and pushing say what happened. The panel used to print git's own
  success output, which is addressed to a script: "To <remote>" and
  "abc1234..def5678 main to main" are both true and neither answers the
  question you asked by pressing the button. It now leads with the answer and
  quotes git underneath, and a failure still shows git's words in full,
  because those name the file, the hook or the conflict.
- The bar the commit and push buttons sit in, and the one under a day in
  Insights, stand on the app's footer surface instead of on the content's own
  background. The rule above each of them separated nothing, so both read as
  loose parts at the bottom of a panel rather than as a place where the
  actions live. Opening a day is the accent now, since it is the reason that
  panel has a footer at all.
- Text fields across Workflows, Tasks, Automations, Devices, the browser bar
  and the harness settings sit on the app's own surface instead of the
  platform's grey bezel, which on a dark panel belonged to no part of the
  design. A field asked to hold a paragraph is now as tall as it was asked to
  be: the describe box in Workflows showed one line whatever it was given.
- Chat in a Git folder shows the branch beside the folder name, and switches
  branches from there, the same control the workspace already had. Chat is not
  drawn inside the workspace surface, so it never inherited that header and a
  conversation about a repository could not say which branch it was about.
- A chat in the sidebar no longer jumps when the pointer reaches it. The
  remove button used to be inserted into the row on hover, which made the row
  taller and the title narrower at that moment and shifted every row under it.
  The space is always there now.
- A conversation with an agent that cannot resume its own session said "Handed
  to <agent>" after every single reply, describing a switch that never
  happened. Two causes, both fixed. Antigravity and opencode do report a
  session, but each puts it somewhere tokenstat was not looking, so no
  conversation ever recorded one and every turn started an agent with no
  memory of what had been said. And a summary handed to the same agent again is
  plumbing rather than a handover, so it no longer appears on the timeline: the
  row is for a conversation that actually changed hands. What an agent was told
  is still written beside the conversation either way.

### Added

- A long conversation opens on its newest page instead of on its beginning,
  and reads backwards a page at a time as you scroll. The page before the
  oldest message is fetched as you approach it and slotted in without moving
  the line you were reading, and the top of the transcript says plainly
  whether there is more or whether that is where the conversation starts.
  Chats also stop re-reading their whole history four times a second while an
  agent is working. The cost card still covers the whole conversation, counted
  once when it opens rather than folded from the part on screen.
- An SSH session suggests as you type. A short panel appears under the cursor
  with the folders and files the server itself reports for the path being
  written, the folders this session has already been in, the commands it has
  already run, and the saved commands that match the line. A bare `cd ` offers
  what is in the folder you are standing in. Press Down to step into the list,
  then Tab or Return to type that row at the prompt, and Escape to put it away
  for the rest of the line. Until you step in, Up is still the shell's history,
  Tab is still the shell's own completion, and Return still runs the line.
  Choosing a row finishes the line and leaves it for you to read: nothing is
  ever run for you. A saved command with placeholders asks for them first, and
  the values are still never stored. What a session remembers of itself lives
  in memory until it closes and is never written anywhere, and nothing is
  offered on, or remembered from, a line the server is not echoing, so a
  password prompt is left alone. On a phone and an iPad the rows are chosen by
  touch and no key is taken from the shell.
- Pull requests, on Mac, use the same reading room as everything else: the wide
  work lane for diffs and checks, and content that starts at the window's
  leading edge rather than floating in the middle of it. One rule now, shared
  with Chat, instead of a measurement per screen.
- Pull requests join the workspace launcher, beside Chat, Files, Browser,
  Changes and Tasks, with the count of what is open on it.
- Chat on Mac now uses the pull-request workspace's wider reading room: prose
  is larger and aligned by speaker at a comfortable measure, while tools,
  diffs, files, approvals, and the composer can use the desktop's extra width.
- Moving between workspace or SSH sections no longer reopens a Mac inspector
  that the person deliberately closed.
- The Mac's existing notification switch now covers Chat. A conversation can
  banner when it needs an answer or its turn ends, primes without replaying old
  work, stays silent for Stop, and removes a waiting banner when the person
  opens or answers that conversation.
- Chat can notify a signed-in phone when a turn finishes or fails, using two
  fixed content-free reasons composed into sentences by the account server.
  Stop stays silent, and a burst of unanswered approvals in one conversation
  sends one waiting notification rather than spending the whole notify budget.
- A Git-enabled workspace gains a Pull requests section that begins with its
  connection. Connecting uses the tokenstat GitHub App through the device flow:
  the app shows a one-time code, GitHub's page opens, and the answer stays on
  the machine that owns the workspace. Where git already holds a GitHub
  credential for this host, that credential is used instead and the screen says
  so, and a token can be pasted for GitHub Enterprise or by preference. Which
  of the three answered is always visible. Selecting the repositories tokenstat
  may open happens on GitHub, and a workspace whose repository is not selected
  says exactly that rather than showing an empty list.
- Pull requests continue into a complete native review workspace. Browse open,
  merged, closed and draft work by relationship; read Markdown conversations
  and review activity; inspect multi-file diffs and checks; comment, approve or
  request changes; mark a draft ready; close, reopen, merge, or safely check a
  pull request out as a local branch. Network reads stay cached and every
  repository-changing operation follows an explicit labelled press.
- The workspace branch chip searches, switches and creates branches, including
  a clear distinction between local and remote-tracking branches.
- Sidebar badges show cached open pull-request counts without making a request
  while drawing navigation. Account names the GitHub host, account, and exact
  credential source in use; it always offers an explicit tokenstat GitHub App
  connection even when a credential borrowed from git already works, then
  exposes repository selection and sign-out for the app-owned grant.
- The Windows preview gains the pull-request list, conversation, lazy diff,
  checks, review actions, connection status, and branch controls in WinUI.
- A workspace Chat section talks to the agents already installed for that
  folder. Conversations persist and resume. The composer sits at the bottom
  of the conversation: Return sends, Shift+Return inserts a newline, Escape
  stops a running turn, and one field picks agent, model and effort. Plan,
  execute and bypass sit as pills beside it. Full setup stays in the
  inspector (Setup on the phone). A message sends what you wrote and nothing
  else: an agent's own brief travels as a system prompt where its CLI has
  one, so a conversation no longer opens by describing tokenstat's own
  plumbing. Instructions in the inspector holds that brief, editable, beside
  the one rule tokenstat adds and the exact words it sends.
- Default mode in Chat really does stop a tool and ask. The card appears in
  the conversation where the agent paused, the composer is replaced by the
  question so a waiting turn cannot be missed, and Deny refuses the call
  rather than letting it through. Claude Code, Codex, Grok Build,
  Antigravity and OpenCode all ask; Cursor cannot, and its chats say so
  instead of offering a switch that does nothing. A card shows how long is
  left and refuses on its own rather than holding a turn open forever, and
  the answer stays on the conversation afterwards. Always allow remembers
  one tool or one command prefix, for that conversation only, and the
  inspector lists what it remembered. A paired phone can answer the same
  card, and whichever surface answers first wins.
- A persona's name reaches its agent, so you can call it by the name on the
  screen. Chats used to show you Lumen while the agent behind it had never
  been told it was anybody, and "Lumen, look at this again" was addressed to
  nobody. The line tokenstat sends is visible in Instructions with everything
  else it adds.
- The starting brief a new folder's persona comes with is sharper about how to
  work: read the call sites and the tests before changing something, treat
  failures as seriously as the happy path, reproduce a bug before fixing it,
  read what a passing suite actually asserts, and finish when the change is
  verified rather than when the edit is typed. Existing starters nobody has
  edited pick it up; a brief with a single word of your own in it is left
  exactly as you wrote it.
- Personas are a name and a brief now, and nothing else. They used to carry an
  agent, a model, an effort, a mode and an autonomy, all of which already live
  on the conversation, so a persona went stale and could only be used with the
  one agent it named. The same persona now works with whichever agent a chat is
  on, and survives that chat being handed to another. Existing personas keep
  their name and brief; the duplicated settings simply go.
- A persona can be written for you. Say what it should be good at in a
  sentence, pick which installed agent drafts it, and edit the name and brief
  that come back before anything is saved. Nothing is saved without a press,
  the draft runs one short turn in a temporary folder and never touches your
  project, and a draft that fails leaves your own words in the field.
- Every persona and every conversation has a face: a small character drawn from
  its own identity, so it exists the moment the persona does and stays the same
  through renames and edits. It is one creature in different moods rather than
  a set of icons, and it replaces the three dots that used to mean "working".
  The character has weight. It breathes at rest, churns and looks up while an
  agent thinks, narrows its eyes and hammers away while a tool runs, talks
  while a reply streams in, goes wide-eyed in amber when a turn is waiting on
  you, jumps when one lands, and melts into a puddle when one fails. It can
  also bounce, keep a ball in the air, dance, and fall asleep. Because it is
  simulated rather than drawn frame by frame, a change of mood carries the
  motion across instead of cutting, and it never leaves the seat it sits in,
  so a streaming transcript stays where you left it. Two personas do not move
  alike: how firm the body is and where it dents come from the same identity
  as its colour, which is sampled from tokenstat's own accent range so a row
  of personas still reads as one family. In the persona editor you can poke
  it. Everything stops for Reduce Motion and whenever the window is not in
  front.
- A persona can belong to every folder instead of the one it was made in.
  The switch is on the persona itself, beside its name.
- A new folder's starting persona is drawn from a much longer list of names,
  so folders stop arriving as the same handful of characters.
- An empty chat shows the character of the persona that folder's next
  conversation will actually have, and nothing else, rather than a bubble with
  three pulsing dots ringed by four agent marks. It has things to
  do: it reads the paper, plays something handheld, bounces off the walls,
  dances, keeps a ball up, walks the floor, and every so often gives up and has
  a nap. What it picks, and for how long, is different every time, so the
  screen you look at while deciding whether to start is never the same loop
  twice. A long wait gets the same treatment: thinking is a creature turning
  something over on the spot or walking the floor, not one pose held for a
  minute.
- One activity becomes the next rather than replacing it. Both are running for
  half a second: the forces on the body crossfade, the expression crossfades
  with them, whatever was being held shrinks away before the next thing grows
  in, and the character blinks as it changes its mind. Falling asleep and then
  waking up to dance is one continuous movement, with nothing in it that reads
  as a cut.
- Changing agent mid-conversation no longer starts from nothing. The incoming
  agent is handed a summary folded from the conversation itself: what was
  asked, which files changed, which commands ran, what you refused, and where
  it was left. It is sent once, to an agent that has no session of its own to
  resume, never on an ordinary continuation. The transcript shows where the
  conversation changed hands and will show you the exact summary that was
  sent, and the same text is kept beside the chat as `brain.md`. Like the rest
  of a conversation, none of it is eligible for sync.
- Chat also brings a grok Standard turn that keeps its output format, Cursor
  without a named model using Auto, and a tool call that no longer blanks
  the transcript or stays Running after the turn ends. The phone is a list
  first, then a transcript with a glass composer. Windows has the same list,
  composer, transcript, approvals and cost meter. Sidebar badges show how
  many chats a folder holds. Token cost is a quiet in/out bar, and a
  plan-covered turn is not drawn as money charged.

### Changed

- Insights now arrives in one snapshot rather than nine separate requests,
  reducing bridge work and making the charts settle together. Slow host calls
  and slow Insights aggregates leave private local timing records, with method
  and elapsed time only, so a real slow machine can be investigated without
  recording projects, prompts, paths, or report values.
- Scans and workspace status checks now take a share of the computer's own CPU
  capacity instead of using one fixed concurrency limit. Older laptops retain
  room for the app and active agents, while newer Macs can use their available
  parallelism.

- Pull-request list and detail screens use the same fixed app chrome as the
  rest of the Mac: folder scope and sidebar control on the left, contextual
  actions and the inspector toggle at the far right. WinUI's native accent,
  focus and action controls use tokenstat violet instead of the system blue.

### Fixed

- The Mac app no longer aborts when entering or leaving full screen from the
  traffic lights. A second sidebar toggle that appeared next to those lights
  on a narrow window is gone, so only the app's own mark remains.

## [0.7.2] - 2026-08-28

### Added

- An account with nothing on it says what to do next. Home draws a numbered
  rail instead of an empty grid: on the Mac the first step arrives done, because
  you are looking at the app, and the rest is a scan and an optional account.
  On the phone it is signing in, already done, and adding a computer. Under it,
  the shape of the heatmap that is coming.

### Changed

- Signing in from the Mac opens the approval on its own, in a sheet over the
  app, rather than dropping you into the whole website to press one button.
- The phone's empty screens offer a way to the first step instead of only
  confirming there is nothing there.

### Fixed

- The App Review demo account can open a workspace, not only watch a screen.

## [0.7.1] - 2026-08-27

### Added

- A device can ask for screen access from its own screen, and the computer it
  asked says so: a toast with a way to the question while the app is open, a
  notification carrying the answers when it is not, and a card in Devices for
  whoever let either go. View only and Full access are separate answers, and
  either can be taken back afterwards. Request access used to send a
  notification that could not carry which device was asking and never reached a
  Mac at all, so nothing happened and the switch was hard to find.
- Watching a screen over a direct connection now looks far better. A LAN or
  router-mapped link is your own bandwidth, so the picture is wider, sharper
  and keyframed twice as often on it, where the relay stays exactly as frugal
  as before. A Quality menu in the viewer picks between automatic, sharp,
  smooth and data saver, and changing it never interrupts the picture.
- On a phone, a computer that has not answered yet shows what it is waiting on
  and connects on its own the moment somebody approves it, rather than leaving
  a screen that never changes.
- Reaching another of your computers across the same network now asks for the
  Local Network permission it needs. Without it iOS refused every direct dial
  silently and every session fell back to the relay, which is slower and
  further away than the machine in the next room.
- A computer now lets each device open its work by name. Signing in on a new
  phone no longer reaches the folders, files, terminals and agents on every
  machine on the account: that is a separate yes, given on the computer being
  asked. **Devices you already use will ask again after this update**, once
  each, from a screen with a Request access button on it. Pairing a device by
  typing its code still grants it in the same step, because that already is
  somebody saying yes to one device by name.
- Workspaces has a Chat section under Sessions, on the Mac and on the phone.
  It is empty and says so: a friendlier way to talk to the agents in a folder
  is coming, and this is where it will be.

### Changed

- Open work and View screen on a device now read as the buttons they are, with
  a glyph and a surface of their own instead of plain text and a chevron.
- Devices lists everything still waiting on you in one place, and one card
  there now covers all three permissions a device can hold: workspaces,
  watching the screen, and driving it.
- Syncing refreshes the numbers it just changed. The heatmap, the day under
  the pointer and the pinned day all re-read, where they used to keep pre-sync
  figures for up to ten minutes.

## [0.7.0] - 2026-08-27

### Fixed

- Turning on control while watching a remote desktop no longer drops the
  session. Control is now handed over on the stream that is already running,
  so the picture never stops, where it used to close the stream and open a new
  one. Those two raced each other: one screen session is allowed at a time, and
  the new one usually arrived before the old one had finished closing, so it
  was refused and the app spent the next half minute reconnecting.
- The relay understands the same handover, so a device reopening the same
  desktop takes over from itself instead of being turned away. A second
  desktop on one account is still one too many, and says so.
- A screen session that a viewer left without closing frees up in seconds
  rather than in up to a minute.
- Dragging a window, or dragging to select text, follows the pointer instead
  of jumping to its new place when the button comes up.
- Input arrives in the order it was made. A fast drag could previously deliver
  a movement after the release that ended it, leaving the far end holding a
  button down.
- A phone coming back to the foreground reconnects to the relay when it finds
  it has fallen off, instead of looking connected while every call to it says
  the machine is not there.
- Reaching a machine no longer waits on a local network address that has
  stopped answering. The address is remembered from the network it worked on,
  and off that network it was tried first on every call.

## [0.6.9] - 2026-08-26

Everything since 0.6.8, which is the last release anybody received.

### New

- SSH from the Mac, the iPhone and the iPad, as a place in the sidebar rather
  than a panel over Devices. Hosts, keys, snippets and trusted servers are
  sections you navigate to, folders nest under Hosts, the list gets the whole
  window and the editor opens beside it. Leaving for Home and coming back keeps
  you where you were, and the rest of the app stays usable throughout.
- A saved server carries what it needs to connect: which key to use, which
  server to reach it through, a starting directory, environment variables, a
  keepalive, and a colour and folder to find it by. Snippets can ask for
  `{{values}}` when they run, so one snippet covers every server.
- Import servers from `~/.ssh/config`, from AWS and from DigitalOcean.
  tokenstat reads that file and never writes to it, and shows what it found
  before saving anything.
- Credentials live in an encrypted vault that can follow the account. Setting
  one up takes the servers, folders, keys and snippets already saved on this
  device with it, syncing runs both ways, and Sync now says when it last ran.
  It is one quiet row above the server list, saying how many records it holds,
  with
  setting it up, replacing the recovery code and deleting it one click away and
  each with room to say what it costs. Recovery is confirmed in two steps: the
  code is on screen to be written down, then off screen while it is typed back,
  so confirming cannot be done by reading. The vault is a Supporter feature and
  says so as a plan rather than as a locked door: on Free the row reads "not
  syncing", the screen explains that your servers and keys are saved on this
  device and work exactly as they do now, and the button on it opens plans
  instead of doing nothing. A vault that outlives the plan that made it stays
  readable and says out loud that it has stopped receiving changes. Deleting it
  on one device removes it from every other one, rather than leaving a second
  device offering to change the password of a vault that is gone.
- Trusted servers are listed with their fingerprints and any of them can be
  forgotten, so a key that changed can be confirmed again rather than quietly
  accepted. A key shows its own fingerprint, and its public half can be copied
  in one press for pasting into a server's authorized_keys. On iPhone and iPad
  a long press on a key or a snippet offers edit, copy, run on connect and
  delete.
- SSH typing appears as it is typed rather than a round trip later. A character
  is drawn locally and replaced by the server's own echo when it arrives, which
  makes a shell on the other side of the world feel like one in the next room.
  Nothing is drawn until the line has proved that it echoes, so a password
  prompt never shows a character of a password.
- Share this Mac's screen with another Apple device on the account. Switch
  displays, send the system audio, copy both ways, and send a file without
  leaving the session. macOS is asked for Screen Recording and Accessibility at
  the moment you turn view or control on, with the prompt that names tokenstat,
  and the card says which permissions are granted and that the app has to be
  open for its screen to be shared.
- Control that screen from an iPhone or iPad. One finger moves the pointer, tap
  clicks, two fingers tap for a right click and drag to scroll, long press then
  drag holds the button down, and pinch zooms in. A row of keys over the
  keyboard sends escape, tab, the arrows and sticky ctrl, opt, cmd and shift,
  and a pull on the bottom edge brings that row back over a full-screen
  picture. Driving a desktop is at sixty pictures a second and every pointer
  move is delivered as it happens, on the same bandwidth a session watched from
  an armchair costs.
- Notes get an inspector on the Mac, so a note written on a phone can be read
  and edited on the computer instead of only on the device it was typed on.
  Deleting one asks first, and clearing the title keeps the edits made in the
  same visit rather than refusing the whole save.
- Opening a computer, from its device page or from Workspaces, shows what it is
  doing: power, CPU and memory read over the tunnel and not uploaded with
  usage, with open work and view screen beside them. On the Mac, a workspace
  that lives on another machine offers that machine's screen without a trip to
  Devices.
- A preview Windows desktop app. Its development build installs for the current
  user, adds a Start Menu shortcut, and exercises the update path while the
  platform matures outside stable GitHub Releases.
- A preview Android client. Pair it to an account the way the iPhone does, then
  use this Mac from the phone: terminals, folders, and the rest of the remote
  surface. Android SSH gains search, folders on saved servers, port and
  starting directory on the add form, and a snippet editor with room for a real
  command.
- Install the host as a service on a machine that has no desktop session, so it
  answers after a reboot the same way Always-on host does on a Mac mini.
- Every control is the app's purple. Switches, pickers, focus rings, selection
  and prominent buttons were system blue everywhere except eight hand-picked
  places.
- The app is set in its own typefaces, the same two the website uses. Manrope
  for everything you read as language, and JetBrains Mono for terminals, code,
  commands and model identifiers, where a lowercase l and a digit 1 have to be
  different pictures. Both are bundled, so a Mac and an iPhone showing the same
  screen now show the same screen. Sizes are unchanged and all of it still
  scales with your text size setting.

### Fixed

- A long session no longer fails with "Too many open files". The app asked the
  system for a fraction of the descriptors it is allowed, and the first thing
  to lose the race reported it as a problem with a file. Connections to another
  machine are also closed once they have been idle for a minute, rather than
  being held for as long as the app is open.
- The app no longer reports "unknown method" when this machine's background
  helper is older than the app. It checks the helper on launch, replaces it,
  and says something a person can act on if it cannot.
- Opening the Mac app on a recent macOS beta no longer aborts while the window
  is first laid out. The splash used to animate the split view in, and AppKit
  refused the extra constraint pass.

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
