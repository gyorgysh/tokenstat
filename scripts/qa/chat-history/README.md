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

Each run retains its result, model states, screenshots and OCR results under
`target/chat-performance/history-encrypted-run-*`. CPU OCR checks visible text;
model assertions alone cannot pass the visual checks. A passing run covers
paging, interrupted reads, reconnection, a provider record split inside UTF-8,
navigation and completion. A large reply must keep its final marker visible
while following, including after reconnection. OCR matching ignores whitespace
noise but still requires the marker's characters in the captured image.
`cleanup.json` separately records whether the owned apps and simulator closed.
These checks do not establish WAN or relay UI behavior.

`account-server.cjs` provides the loopback account routes needed for native
relay setup. It uses the website's account functions and the relay fixture's
in-memory database. Run `node scripts/tests/chat-history-relay.cjs` to check
its HTTP pairing, authentication, registration and token minting. This adapter
is not yet connected to the native app runner; that runner still tests direct
connections only.
