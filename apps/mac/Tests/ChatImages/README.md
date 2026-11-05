These tests use the production image viewport with a generated image. They need no host, account or network connection.

Generate the iOS test project from the repository root:

```sh
mkdir -p target/chat-image-tests
xcodegen generate --spec apps/mac/Tests/ChatImages/project.yml
xcodebuild -project apps/mac/Tests/ChatImages/ImageQA.xcodeproj -scheme ImageQA \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath target/chat-image-tests/build -parallel-testing-enabled NO test
```

The tests locate a red marker in screenshots to check pinch and double-tap anchoring. They also check fitted swipes, zoomed panning, reset, and pinching back to fit before switching images.

The macOS native geometry check runs without moving the mouse or showing a window:

```sh
swiftc -swift-version 5 -parse-as-library \
  apps/mac/Sources/Features/Workspaces/Chat/ChatImageViewerGeometry.swift \
  apps/mac/Sources/Features/Workspaces/Chat/ChatImageViewport.swift \
  apps/mac/Tests/ChatImages/MacViewportTests.swift -o target/chat-image-tests/mac-viewport
target/chat-image-tests/mac-viewport
```
