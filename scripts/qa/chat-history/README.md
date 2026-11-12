# Native history checks

This fixture opens the shipping `ChatModel`, Mac `ChatView` and iPhone
`ClientChatThread` against a disposable host. It seeds an archive over 1 MiB,
streams replies from a controlled Grok protocol process, and cuts encrypted
connections while both clients watch the chat. It uses fresh identities,
separate app identifiers and private data directories. It does not run a model
or restart the installed host.

On Apple Silicon, build the current FFI libraries and generate the QA project:

```sh
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --profile release-ffi -p tokenstat-ffi --target aarch64-apple-darwin
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --profile release-ffi -p tokenstat-ffi --target aarch64-apple-ios-sim --no-default-features
python3 scripts/tests/prepare-history-apple-qa.py
```

Build both targets (XcodeGen and the SwiftTerm package are required):

```sh
xcodebuild -project target/chat-performance/history-encrypted-native/HistoryQA.xcodeproj -scheme HistoryMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath target/chat-performance/history-encrypted-native/mac -jobs 2 build
xcodebuild -project target/chat-performance/history-encrypted-native/HistoryQA.xcodeproj -scheme HistoryPhone -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath target/chat-performance/history-encrypted-native/phone -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

Choose a simulator UDID from `xcrun simctl list devices available`. Then run:

```sh
python3 scripts/tests/chat-history-native.py --simulator YOUR_SIMULATOR_UDID --desktop-local
python3 scripts/tests/chat-history-native.py --simulator YOUR_SIMULATOR_UDID
```

The first mode uses the host's local socket on Mac and an encrypted connection
on iPhone. The second gives each client its own encrypted route. Traffic stays
on this computer; an active private network interface is required. Relay and
fallback are disabled. The simulator is never erased; it is shut down afterward
only if this script booted it.

If Launch Services cannot start the isolated Mac app, `--direct-launch` runs
its executable with the same private environment. A direct launch may not open
a window in every desktop session; the visual checks still require one.

Each run retains its result, model states, screenshots and OCR results under
`target/chat-performance/history-encrypted-run-*`. CPU OCR checks visible text;
model assertions alone cannot pass the visual checks. A passing run covers
paging, interrupted reads, reconnection, a provider record split inside UTF-8,
navigation and completion. A large reply must keep its final marker visible
while following, including after reconnection. OCR matching ignores whitespace
noise but still requires the marker's characters in the captured image.
Each reader also refuses a latest-page read and verifies that the previously
loaded conversation remains visible, then resumes normal reads.

`--desktop-only --retained-stress` keeps the Mac chat mounted as the app does,
repeatedly hides it, changes its width, streams text, and checks the latest
message after bringing it forward. Captures use AppKit's bitmap rendering;
they do not establish that the window compositor repainted without input.
`--desktop-only --automation-compact` renders a synthetic automation transcript
with the shared compact tool rows for visual inspection.
`cleanup.json` separately records whether the owned apps and simulator closed.
These checks do not establish WAN or relay UI behavior.

Use `--search-only` to check that a search request opens the first step of a
collapsed tool group and scrolls its text into view. It streams two completed
tool steps followed by a long reply, renders a change to Minimal detail, then
searches back to the first step. Each app starts at Standard detail so saved
QA preferences cannot change the test. Detail changes and search requests
are separate viewport choices and must not be issued in the same action.
This mode checks mounted-conversation search placement; it does not exercise
the search sheet or substitute for the full reconnect run. Add `--desktop-only`
for a Mac-only check.

`account-server.cjs` provides the loopback account routes needed for native
relay setup. It uses the website's account functions and the relay fixture's
in-memory database. Run `node scripts/tests/chat-history-relay.cjs` to check
its HTTP pairing, device-code approval, authentication, registration and token
minting. The controller service approves device codes against its disposable
account, so native QA apps can use their normal device login calls. Run `chat-history-native.py --simulator YOUR_SIMULATOR_UDID --relay --desktop-local`
to connect the iPhone through that relay while the Mac uses its owned host
socket. The runner starts and stops the service, verifies relay payload with
zero direct payload, and cuts the phone's relay connection during streaming.
Omit `--desktop-local` to use a separate disposable desktop daemon. Both native
readers then use independent relay connections; the test checks the desktop's
outbound route and interrupts each reader while the other keeps receiving.
The desktop app reaches only its owned daemon socket; the installed host is
not involved. This three-device setup uses a Patron-tier account in the in-memory
database. The local desktop plus iPhone setup still uses a Free account.

The relay service can also run under a controller:

```sh
node scripts/tests/chat-history-relay.cjs --serve /absolute/private/fixture-root
```

The root must already exist with mode 0700. The service writes `relay.json`
with mode 0600, containing loopback endpoints and disposable pairing codes.
Creating `stop` in that root closes both listeners and writes relay metering
to `relay-result.json`. A 15-minute deadline also stops an abandoned fixture.
