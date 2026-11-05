These iOS tests mount the production model viewer inside a scrollable transcript and load a small OBJ cube with the bundled renderer. They need no host, account or network connection.

From the repository root:

```sh
xcodegen generate --spec apps/mac/Tests/ChatModels/project.yml
xcodebuild -project apps/mac/Tests/ChatModels/ModelQA.xcodeproj -scheme ModelQA \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath target/chat-model-tests/build -parallel-testing-enabled NO test
```

The tests check rendered pixels, pinch zoom, reset, orbit gestures, transcript scrolling, unmounting and recovery after an oversized file. Full-screen pixel checks also verify that surrounding chat text remains visible after pinching. A test-only JavaScript probe counts WebGL draw calls to verify that rendering stops after an orbit settles. It leaves the renderer and its controls intact.

The fixture fixes the model background to dark so the pixel check can distinguish the white cube. It measures the enclosing native scroll view's offset to check that model gestures stay inside the viewer.
