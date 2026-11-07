# Chat control gestures

The fixture uses the production swipe modifier without accounts, networking or FFI. UI tests cover directional tab gestures, tap cancellation, top-edge message taps and touch isolation from a presented sheet.

Generate with `xcodegen generate --spec apps/mac/Tests/ChatControls/project.yml`, then run scheme `ChatControlsQA` on an iPhone simulator with `xcodebuild test`. The project supports iOS 17 and later.
