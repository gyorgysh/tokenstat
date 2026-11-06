# Native image gestures

This offline app uses the shipping iOS pager, image scroll view and geometry.
Only image loading is replaced with synthetic pixels. It needs no account,
FFI library or network, and uses its own app identifier. Tests exercise real
pinch, pan, swipe and button gestures, including pinch immediately after
paging, canceled swipes, zoomed edge pans and Reduced Motion. Pixel checks
verify that pinch and double-tap keep the image's focal point.

Generate the project with XcodeGen:

```sh
python3 scripts/tests/prepare-image-pager-qa.py
```

Choose an available iPhone simulator, then run:

```sh
xcodebuild -project target/chat-performance/image-pager-native/ImagePagerQA.xcodeproj \
  -scheme ImagePagerQA -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
  -derivedDataPath target/chat-performance/image-pager-native/build \
  -resultBundlePath target/chat-performance/image-pager-native/gestures.xcresult \
  -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO test
```

Use a new result bundle path for each run. The fixture does not create, erase
or shut down a simulator. It does not test downloading, image decoding, relay
consent, physical-device frame rate or Mac/Android image transitions.
