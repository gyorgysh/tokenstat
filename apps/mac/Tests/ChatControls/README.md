# Chat control gestures

The fixture uses the production swipe modifiers without accounts, networking or FFI. UI tests cover directional tab gestures, tap cancellation, top-edge message taps and touch isolation from a presented sheet. With hidden chrome, leading-edge Back returns an in-place reader to its list without also popping the containing screen, dismisses a pushed reader, and closes a full-screen reader through its owner. Visible chrome keeps the system's navigation gesture. Content swipes, vertical edge drags and short edge drags leave the reader open.

Generate with `xcodegen generate --spec apps/mac/Tests/ChatControls/project.yml`, then run scheme `ChatControlsQA` on an iPhone simulator with `xcodebuild test`. The project supports iOS 17 and later.
