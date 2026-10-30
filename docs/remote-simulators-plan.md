# Remote simulators across machines

Status: planned. The current Simulator workbench is local to its Mac. Remote
Desktop can show the Mac's screen, but it does not expose a simulator as its
own selectable, resizable stream.

## User flow

The client lists running simulators under the Mac that owns them. Opening one
shows its picture in a workbench panel. A second client may watch the same
simulator. A client with control access can tap, drag, type, and press device
buttons without controlling the Mac's desktop. The simulator stays running on
the host when a viewer closes. The panel remembers `host peer + simulator ID`
across reconnects; a different host with the same simulator ID is distinct.

## Transport and permissions

Use the existing authenticated, encrypted peer route and its direct-first,
optional relay behavior. Video frames and input are live peer traffic, never
account sync data. The host presents **View simulators** and **Control
simulators** in the same first-device access sheet as workspace and desktop
access. Control requires view. Revocation closes live streams immediately.
The host checks both the device grant and the requested simulator on every
stream open and control request.

The Mac's existing local iOS simulator surface (`SimulatorSession.swift`) and
Android emulator video path (`SimulatorVideoStream.swift`) supply frames. The
existing remote screen encoder and decoder provide the starting H.264 framing,
keyframe recovery, adaptive bitrate, and congestion feedback. Simulator input
is routed to the simulator session, not to the host's global mouse and keyboard.
On relay, start at a restrained profile and let the viewer raise quality only
within its relay allowance. Direct sessions can use a higher frame rate.

## Implementation order

1. Host catalog of running simulators with stable host-owned IDs, platform,
   device name, dimensions, and availability. A stopped simulator disappears
   without changing any other host's catalog.
2. Separate simulator grants in the existing first-device access modal and
   host policy. Include denial, revocation, account change, and an existing
   viewer losing access.
3. Capture a selected simulator to the existing streaming transport. Keep a
   keyframe on join and after route recovery; bound per-viewer buffering.
4. Show and control the stream on Mac and Windows, with host-specific panels
   and clear watch/control state. Add mobile viewing after desktop behavior is
   sound.
5. Validate iOS Simulator and Android emulator sources, rotation and resize,
   direct and relay routes, a second viewer, host sleep/offline/reconnect,
   denied access, and keyboard/touch latency. Measure relay bytes and show
   that usage in the existing connection view.

The account directory may announce that a simulator exists, but it must not
carry its frame data or input events.
