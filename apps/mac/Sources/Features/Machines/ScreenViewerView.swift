// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import AVFoundation
import CoreMedia
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Legend screen viewer. H.264 is decoded entirely at this endpoint by the
/// system display layer; the relay and account service see encrypted bytes.
struct ScreenViewerView: View {
    @Environment(\.dismiss) private var dismiss
    #if !os(macOS)
    @Environment(ClientStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let peer: String
    let name: String
    let tier: String?
    @State private var model = ScreenViewerModel()
    @State private var controlling = false
    @State private var muted = false
    @State private var importingFile = false
    @State private var zoom: CGFloat = 1
    /// Local displacement of a magnified picture while merely viewing it.
    /// Control mode follows the remote pointer instead and keeps this at zero.
    @State private var viewOffset: CGSize = .zero
    /// Slow the pointer right down, for a target a few pixels across.
    @State private var fine = false
    /// The left button is held, so the next drag drags. A toggle rather than
    /// only a long press, because a long press cannot be held while the other
    /// hand does anything and is not visible anywhere on screen.
    @State private var dragLatched = false
    @State private var heldModifiers: UInt64 = 0
    @State private var keyboardWanted = false
    #if os(macOS)
    @State private var mode: ScreenPointerMode = .direct
    @State private var viewerIsFullScreen = false
    #else
    @State private var mode: ScreenPointerMode = .trackpad
    /// The chrome is hidden and the picture has the whole display.
    ///
    /// A phone showing somebody's desktop wants every pixel: the navigation
    /// bar, the status bar and the transport line together are a strip off the
    /// top of a picture that is already smaller than the thing it is showing.
    /// A tap on the picture brings them back.
    @State private var immersive = false
    /// Whether the last rotation into landscape has already been acted on, so
    /// leaving immersive mode by hand is not undone on the next redraw.
    @State private var appliedLandscape = false
    /// The key row has been pulled up over a picture that otherwise has the
    /// whole display.
    ///
    /// Full screen and landscape both hide the row, and in control mode that
    /// left the only click, right click and modifier keys on the phone behind
    /// a trip out of full screen and back. The row is what somebody
    /// controlling a desktop reaches for most, so it gets a way up that does
    /// not cost the picture: a grab handle on the bottom edge, dragged or
    /// tapped.
    @State private var keysRevealed = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The input surface scales with the picture, so a pinch changes
            // what a finger can reach without changing what a tap means: the
            // surface reports its own coordinates, which stay normalized.
            ScreenVideoSurface(layer: model.decoder.layer)
                .aspectRatio(model.aspectRatio, contentMode: .fit)
                .overlay { inputSurface }
                .overlay { pointerMark }
                .scaleEffect(zoom, anchor: pointerAnchor)
                .offset(viewOffset)
                .clipped()
            if model.state != .streaming {
                overlayStatus
            }
        }
        .clipped()
        .navigationTitle(name)
        .safeAreaInset(edge: .top) {
            // Turned sideways, a phone has very little height and every line
            // of it is picture somebody rotated the device to see. The
            // transport is worth a line in portrait and is not worth one here,
            // and it is not worth one with the chrome hidden either.
            if !isCompactHeight, !isImmersive {
                HStack(spacing: 6) {
                    Circle().fill(model.transport == "direct" ? Theme.success : Theme.warning).frame(width: 7, height: 7)
                    Text(model.transport == "direct" ? "Direct connection" : "Encrypted relay")
                }
                .font(Theme.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
        .toolbar {
            // The Mac's viewer is a window and needs its own way out. A phone
            // pushed this screen and already has a back control an inch to the
            // left of this one, so a second close button was two controls for
            // one job in a row that had no space to spare.
            #if os(macOS)
            ToolbarItem(placement: .cancellationAction) {
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close screen viewer")
            }
            #endif
            if model.displays.count > 1 {
                ToolbarItem {
                    Picker("Display", selection: Binding(
                        get: { model.selectedDisplay ?? 0 },
                        set: { model.selectDisplay($0) }
                    )) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            ToolbarItem {
                if controlling {
                    if model.transferProgress == nil {
                        Button("Send file", .upload) { importingFile = true }
                    } else {
                        Button("Cancel transfer", .stop) { model.cancelTransfer() }
                    }
                }
            }
            ToolbarItem {
                Toggle(isOn: $muted) { Label("Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2") }
                    .onChange(of: muted) { _, value in model.audio.muted = value }
            }
            ToolbarItem {
                Toggle(isOn: $controlling) { Label("Control", systemImage: "cursorarrow.motionlines") }
                    .disabled(model.state == .connecting)
            }
            ToolbarItem {
                Picker("Quality", selection: Binding(
                    get: { model.quality },
                    set: { choice in Task { await model.setQuality(choice) } }
                )) {
                    ForEach(ScreenQualityChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .help("How much of the connection this picture may use")
            }
            if controlling {
                ToolbarItem {
                    Picker("Pointer", selection: $mode) {
                        ForEach(ScreenPointerMode.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if zoom > 1.01 {
                ToolbarItem {
                    Button("Fit", .collapse) {
                        withAnimation {
                            zoom = 1
                            viewOffset = .zero
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            #if os(macOS)
            ToolbarItem {
                // The glyph alone here too. Spelled out it was the only
                // sentence in a row of symbols, and "Exit full screen" is long
                // enough that the toolbar reflowed the moment somebody used
                // it. The title stays as the help tag and the accessibility
                // label, which is where a word belongs on a Mac toolbar.
                Button(
                    viewerIsFullScreen ? "Exit full screen" : "Full screen",
                    viewerIsFullScreen ? .exitFullScreen : .enterFullScreen
                ) {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .labelStyle(.iconOnly)
                .help(viewerIsFullScreen ? "Return this viewer to its window" : "Fill this display")
            }
            #else
            ToolbarItem {
                // The glyph alone. Spelled out, it was the only word in a row
                // of icons and took about half the bar on a phone, which on
                // the screen with the least room to spare is the one place a
                // label cannot afford to be a word. The title stays as the
                // accessibility label and the iPad tooltip.
                Button("Full screen", .enterFullScreen) {
                    withAnimation { immersive = true }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Full screen")
            }
            #endif
            #if !os(macOS)
            if controlling {
                ToolbarItem {
                    Toggle(isOn: $keyboardWanted) { Label("Keyboard", systemImage: "keyboard") }
                }
            }
            #endif
        }
        // Control is a property of the session, so changing it reopens the
        // stream rather than being refused.
        .onChange(of: controlling) { _, wanted in
            viewOffset = .zero
            #if !os(macOS)
            // Handing control back leaves nothing on the key row worth
            // showing, so a row pulled up over the picture goes with it.
            if !wanted { keysRevealed = false }
            #endif
            // Handing control back with the button still latched down would
            // leave the far end holding a click nothing here can release.
            if !wanted, dragLatched {
                model.press(false)
                dragLatched = false
            }
            Task {
                await model.setControl(wanted)
                if !model.isControlling { controlling = false }
            }
        }
        .task { await start() }
        .onDisappear {
            if dragLatched { model.press(false) }
            model.stop()
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            model.sendFile(url)
        }
        .overlay(alignment: .bottom) {
            if let progress = model.transferProgress {
                ProgressView(value: progress).padding().background(.ultraThinMaterial, in: Capsule())
            }
        }
        // Said once, not twice.
        //
        // The key row's first button already reads "Release" while the button
        // is down, so this capsule sat on top of it saying the same thing in
        // more words, over a strip too narrow for both: the row's last keycap
        // was cut in half to make room for a control that was already on the
        // row. It belongs to the shapes that have no key row instead, which
        // are exactly the ones where a held button would otherwise be
        // invisible.
        .overlay(alignment: .bottom) {
            if dragLatched, !showsKeyBar {
                HStack(spacing: Theme.Space.s) {
                    Text("Holding the left button")
                    Button("Release", .move) {
                        model.press(false)
                        dragLatched = false
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                }
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.accent, in: Capsule())
                .padding(.bottom, Theme.Space.s)
            }
        }
        #if os(macOS)
        // Only full screen is read here; the width and the titlebar inset
        // have no viewer of their own, so they are given constants rather
        // than bindings that would invalidate this view on every resize.
        .background {
            WindowScreenObserver(
                contentWidth: .constant(0),
                isFullScreen: $viewerIsFullScreen,
                titlebarInset: .constant(0)
            )
        }
        #endif
        #if !os(macOS)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        // And the app's own tab bar. Hiding the navigation bar and leaving
        // Home / Workspaces / Insights / Devices across the bottom is most of
        // a strip of somebody's desktop still spent on chrome, on the screen
        // that asked for the whole display.
        .toolbar(immersive ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        // A tap on the picture brings the chrome back, but only while merely
        // watching. In control mode a tap is a click on the far end, and the
        // gesture here is a separate recogniser watching the same touches
        // rather than something the input surface can consume: every click
        // would have dropped out of full screen as well as clicking. So
        // control mode gets the corner button below instead, and this is for
        // the mode where a tap means nothing else.
        .onTapGesture {
            guard immersive, !controlling else { return }
            withAnimation { immersive = false }
        }
        // The way out that works in either mode.
        //
        // Hiding the chrome hides the button that hid it, so without this the
        // only way back in control mode would be a gesture that also clicks
        // somebody's desktop. Quiet enough not to be part of the picture, and
        // always in the same corner.
        .overlay(alignment: .topTrailing) {
            if immersive {
                Button("Exit full screen", .exitFullScreen) {
                    withAnimation { immersive = false }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .labelStyle(.iconOnly)
                .padding(Theme.Space.m)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Full screen and landscape are the shapes somebody chose for the
            // picture, so the key row does not take a strip of either by
            // default. It is still what control mode reaches for most, so it
            // is one pull away rather than a rotation and a trip out of full
            // screen away.
            if controlling {
                VStack(spacing: 0) {
                    // The way back to the key row, for the two shapes that
                    // hide it.
                    //
                    // A tap on the picture cannot do this job: in control
                    // mode a tap is a click on somebody's desktop. So the
                    // handle is its own small surface on the bottom edge, out
                    // of the picture's way, and it answers to a tap or a drag
                    // the way a sheet's grabber does. In portrait with the
                    // chrome up the row is furniture and needs no handle.
                    if !keyBarIsFurniture { keyBarHandle }
                    if showsKeyBar { keyBar }
                }
            }
        }
        // Rotating a phone onto its side is asking for the picture, so going
        // sideways hides the chrome once. Turning it back shows it again.
        // Tracked, so leaving immersive mode by hand while still in landscape
        // is not undone by the next redraw.
        .onChange(of: isCompactHeight) { _, compact in
            keysRevealed = false
            if compact {
                keyboardWanted = false
                guard !appliedLandscape else { return }
                appliedLandscape = true
                withAnimation { immersive = true }
            } else {
                appliedLandscape = false
                withAnimation { immersive = false }
            }
        }
        // The orientation the screen opened in never arrives as a change, so
        // opening the viewer with the phone already sideways left the chrome
        // up over a landscape picture: the one case the whole thing is for.
        // Applied once on arrival, then `onChange` keeps up with it.
        .onAppear {
            if isCompactHeight {
                appliedLandscape = true
                immersive = true
            }
        }
        // A screen somebody is watching must not dim under them.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    /// Whether the chrome is hidden and the picture has the whole display.
    /// Always false on the Mac, which fills a display by going full screen.
    private var isImmersive: Bool {
        #if os(macOS)
        false
        #else
        immersive
        #endif
    }

    /// Whether the key row is on screen.
    ///
    /// It has a place of its own in portrait with the chrome up. Full screen
    /// and landscape take that place away, and there it appears only because
    /// somebody pulled the handle on the bottom edge.
    private var showsKeyBar: Bool {
        #if os(macOS)
        false
        #else
        keyBarIsFurniture || keysRevealed
        #endif
    }

    /// Whether the key row has a place of its own rather than being pulled up
    /// over the picture. Portrait with the chrome showing, and nothing else.
    private var keyBarIsFurniture: Bool {
        #if os(macOS)
        false
        #else
        !isCompactHeight && !immersive
        #endif
    }

    /// A phone on its side. iPad and Mac never report this, so nothing there
    /// changes shape.
    private var isCompactHeight: Bool {
        #if os(macOS)
        false
        #else
        verticalSizeClass == .compact
        #endif
    }

    private func start() async { await model.start(peer: peer, tier: tier, control: controlling) }

    /// Cover over the black backing until a picture is on it, or until the
    /// session has said why there will not be one.
    @ViewBuilder
    private var overlayStatus: some View {
        VStack(spacing: Theme.Space.m) {
            if model.state == .connecting {
                ProgressView()
                Text(model.message)
                    .font(Theme.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            } else if model.needsLegend {
                legendRequired
            } else {
                Text(model.message)
                    .font(Theme.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 8) {
                    readiness("Legend plan", ready: tier?.lowercased() == "legend")
                    readiness("Signed in and paired", ready: true)
                    readiness("Host online", ready: !model.message.localizedCaseInsensitiveContains("offline"))
                    readiness("Per-device screen permission", ready: !model.needsPermission)
                    readiness(
                        controlling ? "Screen Recording and Accessibility" : "Screen Recording on the host",
                        ready: !model.message.localizedCaseInsensitiveContains("recording")
                    )
                }
                .padding(Theme.Space.m)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                if model.needsPermission {
                    Button("Request access", .approve) { Task { await model.requestAccess() } }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(model.isRequesting)
                    if let notice = model.requestNotice {
                        Text(notice)
                            .font(Theme.caption)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Try again", .refresh) { Task { await start() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        .contentShape(Rectangle())
    }

    /// The viewer opened on a plan that does not include the screen. A
    /// checklist of other causes would send somebody hunting permissions they
    /// do not need to grant.
    private var legendRequired: some View {
        VStack(spacing: Theme.Space.m) {
            #if os(macOS)
            TierMark(tier: "legend", size: 36)
            #else
            ClientEmptyArt(kind: .screen)
            #endif
            Text("Screen access is on Legend")
                .font(Theme.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Mouse and keyboard never travel without the picture, and the picture is end-to-end encrypted between your devices. Legend is the plan that includes it.")
                .font(Theme.callout)
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.center)
            plansButton
        }
    }

    @ViewBuilder
    private var plansButton: some View {
        #if os(macOS)
        Link("See plans", destination: URL(string: "https://tokenstat.ai/pricing")!)
            .buttonStyle(AccentButtonStyle())
        #else
        Button("See plans", .plans) { store.showPaywall = true }
            .buttonStyle(AccentButtonStyle())
        #endif
    }

    private func readiness(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(Theme.callout)
            .foregroundStyle(ready ? Theme.success : Color.white.opacity(0.72))
    }

    private var actions: ScreenInputActions {
        ScreenInputActions(
            move: { model.move(to: $0) },
            nudge: { delta, size in
                model.nudge(by: delta, in: size, sensitivity: pointerSensitivity)
            },
            click: { button, count in model.click(button: button, count: count) },
            press: { model.press($0) },
            scroll: { model.scroll(by: $0) },
            panView: { delta, size in
                viewOffset = clamped(
                    CGSize(width: viewOffset.width + delta.width, height: viewOffset.height + delta.height),
                    in: size,
                    at: zoom
                )
            },
            text: { text, flags in model.sendText(text, flags: flags) },
            key: { code, down, flags in model.sendKey(code, down: down, flags: flags) },
            magnify: { factor, size in
                let previous = zoom
                let next = min(max(previous * factor, 1), Self.maxZoom)
                zoom = next
                if controlling || next <= 1.01 {
                    viewOffset = .zero
                } else {
                    let ratio = previous > 0 ? next / previous : 1
                    viewOffset = clamped(
                        CGSize(width: viewOffset.width * ratio, height: viewOffset.height * ratio),
                        in: size,
                        at: next
                    )
                }
            }
        )
    }

    private var inputSurface: some View {
        #if os(macOS)
        ScreenInputSurface(
            actions: actions,
            enabled: controlling,
            mode: mode,
            zoomed: zoom > 1.01
        )
        #else
        ScreenInputSurface(
            actions: actions,
            enabled: controlling,
            mode: mode,
            zoomed: zoom > 1.01,
            heldModifiers: $heldModifiers,
            keyboardWanted: $keyboardWanted
        )
        #endif
    }

    /// How far the pointer travels for a finger's worth of drag.
    ///
    /// Divided by the zoom, so magnifying the picture magnifies the precision
    /// with it: at 4x a finger crosses a quarter as much of the remote screen,
    /// which is the whole reason to zoom in on a control too small to hit.
    /// Fine takes another third off that, for the last few pixels.
    private var pointerSensitivity: CGFloat {
        let base: CGFloat = 1.6
        return base / max(1, zoom) * (fine ? 0.35 : 1)
    }

    /// The most the picture can be magnified.
    ///
    /// Four was not enough on a phone looking at a large display: a menu bar
    /// item is a couple of points across at fit, and no amount of steadiness
    /// makes that reachable.
    static let maxZoom: CGFloat = 8

    /// Where the picture grows from when it is zoomed. Following the pointer
    /// means control mode never needs a separate pan gesture: moving the
    /// pointer to an edge brings that edge into view. View mode grows from the
    /// centre and uses the local pan gesture instead.
    private var pointerAnchor: UnitPoint {
        controlling ? UnitPoint(x: model.cursor.x, y: model.cursor.y) : .center
    }

    /// Keep local panning inside the part of a scaled picture that can exist
    /// beyond its fitted bounds. At fit there is nowhere to pan.
    private func clamped(_ offset: CGSize, in size: CGSize, at zoom: CGFloat) -> CGSize {
        let horizontal = max(0, size.width * (zoom - 1) / 2)
        let vertical = max(0, size.height * (zoom - 1) / 2)
        return CGSize(
            width: min(max(offset.width, -horizontal), horizontal),
            height: min(max(offset.height, -vertical), vertical)
        )
    }

    #if !os(macOS)
    /// The row of keys and pointer buttons a touch screen has no other way to
    /// send.
    private var keyBar: some View {
        ScreenKeyBar(
            modifiers: $heldModifiers,
            send: { code, flags in
                model.sendKey(code, down: true, flags: flags)
                model.sendKey(code, down: false, flags: flags)
            },
            pointer: ScreenPointerControls(
                fine: fine,
                dragLatched: dragLatched,
                zoom: zoom,
                click: { button, count in model.click(button: button, count: count) },
                toggleDrag: {
                    dragLatched.toggle()
                    model.press(dragLatched)
                },
                toggleFine: { fine.toggle() },
                resetZoom: {
                    withAnimation {
                        zoom = 1
                        viewOffset = .zero
                    }
                }
            )
        )
    }

    /// The grab handle that pulls the key row up over a full-screen picture.
    ///
    /// Deliberately quiet and deliberately small. It sits on the bottom edge
    /// where a phone already expects a handle, it is a couple of points of
    /// picture at most, and it is the only part of the screen in control mode
    /// that a touch does not send to the far end.
    private var keyBarHandle: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: 44, height: 4)
            Image(systemName: keysRevealed ? "chevron.down" : "chevron.up")
                .font(Theme.font(9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        // The handle is 4 points tall and a thumb is not. The padding is the
        // target, so the strip that answers is a proper 44.
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { keysRevealed.toggle() } }
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    guard abs(value.translation.height) > 8 else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        keysRevealed = value.translation.height < 0
                    }
                }
        )
        .accessibilityLabel(keysRevealed ? "Hide the key row" : "Show the key row")
        .accessibilityAddTraits(.isButton)
    }
    #endif

    /// Trackpad mode hides the finger from the pointer, so the pointer has to
    /// be visible. Direct mode does not need it: the finger is the pointer.
    @ViewBuilder
    private var pointerMark: some View {
        if controlling, mode == .trackpad {
            GeometryReader { geometry in
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .frame(width: 22, height: 22)
                    .position(
                        x: model.cursor.x * geometry.size.width,
                        y: model.cursor.y * geometry.size.height
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor @Observable
private final class ScreenViewerModel {
    enum State { case idle, connecting, streaming, failed }
    var state: State = .idle
    var message = "Connecting…"
    var aspectRatio: CGFloat = 16 / 9
    var displays: [ScreenDisplay] = []
    var selectedDisplay: UInt32?
    var transferProgress: Double?
    var transport = "relay"
    /// Where the pointer is, normalized. The client owns this because trackpad
    /// mode has no other way to know, and because a phone has to draw it.
    var cursor = CGPoint(x: 0.5, y: 0.5)
    let decoder = ScreenH264Decoder()
    let audio = ScreenAudioPlayer()
    private var session: ScreenViewerSession?
    private var task: Task<Void, Never>?
    private var pointerIsDown = false
    private var peer = ""
    private var transferTask: Task<Void, Never>?
    /// The in-flight close of the session `stop` just ended. See `awaitClose`.
    private var closeTask: Task<Void, Never>?
    /// The last input send, so the next one can queue behind it. See `send`.
    private var inputTail: Task<Void, Never>?
    /// The "still watching" beat. See `startHeartbeat`.
    private var heartbeatTask: Task<Void, Never>?
    private var clipboardChangeCount = -1
    private var requestedTier: String?
    private var requestedControl = false
    private var reconnectAttempts = 0
    /// When the transport connected, used only to bound the wait for the
    /// first decodable picture.
    private var connectedSince: Date?
    /// When the current session started streaming.
    ///
    /// The attempt counter used to reset on the first decoded frame, so a
    /// session that died a second after its first frame reset the budget every
    /// time and reconnected forever. That is the loop behind the endless
    /// pair-then-close churn in the relay log. A session has to actually last
    /// before it counts as recovered.
    private var streamingSince: Date?
    /// How long a session has to hold up before the budget is given back.
    private static let stableAfter: TimeInterval = 12
    private var stopped = false
    /// What came back from asking, kept apart from `message` on purpose.
    ///
    /// `message` is why the session is not running, and the checklist reads it
    /// word by word. Writing an outcome into it would tell the checklist the
    /// permission had arrived and take the button away in the same breath.
    private(set) var requestNotice: String?
    private(set) var isRequesting = false
    /// What the picture is asked to be worth. Automatic lets the host read the
    /// route, which is the right answer for almost everybody: a direct link
    /// pays for a much better picture out of the person's own bandwidth, and
    /// the relay stays where it was.
    var quality: ScreenQualityChoice = .auto
    var needsPermission: Bool {
        let value = message.lowercased()
        return value.contains("permission") || value.contains("screen access") || value.contains("allowed")
    }
    /// The session never started because the plan does not include it.
    var needsLegend: Bool {
        message.localizedCaseInsensitiveContains("legend plan")
    }

    /// Ask the computer itself, then nudge the owner's phone.
    ///
    /// The ask is the part that matters and the part that can fail usefully:
    /// it travels the tunnel, so the host learns which device is asking and
    /// can queue it for a person. The push afterwards is best effort and
    /// carries no device id at all, which is why it was never enough on its
    /// own. A host that is asleep cannot be asked, and says so.
    func requestAccess() async {
        isRequesting = true
        defer { isRequesting = false }
        do {
            var answer = try await Bridge.askScreenAccess(peer: peer, control: requestedControl)
            // Already allowed to watch, and still not running: what is missing
            // is the mouse. Asking for exactly what the Control toggle happened
            // to say left somebody who had been granted View only pressing a
            // button that answered "this device already has access" forever,
            // with no way from here to ask for the rest.
            if answer.granted == true, !requestedControl {
                answer = try await Bridge.askScreenAccess(peer: peer, control: true)
            }
            if answer.granted == true {
                requestNotice = "This device already has access. Press Try again."
                return
            }
            requestNotice = "Asked. Approve this device on that computer."
        } catch {
            requestNotice = error.localizedDescription
            return
        }
        // Best effort, and never the reason the request failed. Somebody with
        // no phone registered has still asked the computer itself.
        if let sent = try? await Bridge.requestScreenAccess(), sent.signedIn, sent.enabled, sent.sent > 0 {
            requestNotice = "Asked. A notification went to your other devices."
        }
    }

    func start(peer: String, tier: String?, control: Bool) async {
        stop()
        stopped = false
        startHeartbeat()
        self.peer = peer
        requestedTier = tier
        requestedControl = control
        reconnectAttempts = 0
        requestNotice = nil
        state = .connecting
        message = "Connecting…"
        await connect()
    }

    private func connect() async {
        // Whatever the last session left behind has to be gone before this one
        // dials: the relay allows one screen channel per account.
        await awaitClose()
        let tier = requestedTier
        let control = requestedControl
        guard tier?.lowercased() == "legend" else {
            state = .failed
            message = "Screen access requires the Legend plan."
            return
        }
        do {
            let identity = try await Bridge.machineIdentity()
            let capability = try await Bridge.onPeer(
                peer,
                "screen.capability.issue",
                ["peerId": identity.key, "control": control, "tier": tier ?? ""],
                as: ScreenCapability.self
            )
            let session = try await Bridge.screenViewerOpen(
                peer: peer,
                capability: capability.token,
                control: control,
                quality: quality
            )
            self.session = session
            transport = session.transport
            connectedSince = Date()
            streamingSince = nil
            // Connected is not the same as a picture. Marking streaming here
            // hid the overlay and left a black rectangle that still accepted
            // mouse and keyboard, because input is a side channel.
            state = .connecting
            message = "Waiting for the first picture…"
            task = Task { [weak self] in await self?.readLoop(session.id) }
        } catch {
            let reason = error.localizedDescription
            if actionable(reason) { state = .failed; message = reason }
            else { reconnect(after: reason) }
        }
    }

    func stop() {
        stopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel()
        task = nil
        if let id = session?.id {
            // Kept, not discarded. `connect` waits on it before dialling: the
            // relay allows one screen channel per account, so a fresh dial
            // that overtakes the close of the old one is refused with
            // `screen_already_open`, and the retry ladder that follows is the
            // reconnect storm this used to produce.
            closeTask = Task { await Bridge.screenViewerClose(id: id) }
        }
        session = nil
        pointerIsDown = false
        inputTail = nil
        decoder.reset()
        audio.reset()
        transferTask?.cancel()
        transferTask = nil
    }

    /// Wait for the previous session's close to land before dialling again.
    ///
    /// `screen.viewer.close` is local work: it drops the registry entry and
    /// closes the writer, which puts a CH_CLOSE on the tunnel's writer thread.
    /// The bridge caps it at ten seconds either way, so this cannot become the
    /// thing that hangs a reconnect.
    private func awaitClose() async {
        guard let closing = closeTask else { return }
        closeTask = nil
        await closing.value
    }

    private func readLoop(_ id: String) async {
        while !Task.isCancelled {
            do {
                let read = try await Bridge.screenViewerRead(id: id)
                if let encoded = read.metadata, let data = Data(base64Encoded: encoded),
                   let metadata = try? JSONDecoder().decode(ScreenMetadata.self, from: data)
                {
                    if metadata.type == "displays", let values = metadata.displays {
                        displays = values
                        selectedDisplay = metadata.selected
                    } else if metadata.type == "clipboard", let text = metadata.text,
                              requestedControl {
                        applyClipboard(text)
                    }
                }
                if let encoded = read.frame, let data = Data(base64Encoded: encoded),
                   let frame = ScreenEncodedFrame(data)
                {
                    aspectRatio = CGFloat(frame.width) / CGFloat(max(1, frame.height))
                    if decoder.decode(frame) {
                        if let since = streamingSince {
                            if Date().timeIntervalSince(since) > Self.stableAfter {
                                reconnectAttempts = 0
                            }
                        } else {
                            // Stability starts with a picture, not with the
                            // transport. A slow first keyframe must not spend
                            // almost all of the stability window by itself.
                            streamingSince = Date()
                        }
                        if state != .streaming { state = .streaming }
                    }
                }
                if state != .streaming,
                   let since = connectedSince,
                   Date().timeIntervalSince(since) > 8
                {
                    // The transport is alive but unusable. Do not leave its
                    // viewer and the host's capture running behind a failed
                    // overlay while waiting for somebody to press Try Again.
                    await Bridge.screenViewerClose(id: id)
                    if session?.id == id { session = nil }
                    connectedSince = nil
                    streamingSince = nil
                    state = .failed
                    message = "Connected, but no picture has arrived yet. The host may not have Screen Recording, or tokenstat may not be open on that Mac."
                    return
                }
                if let encoded = read.audio, let data = Data(base64Encoded: encoded) {
                    audio.play(data)
                }
                if !read.active {
                    let reason = read.error ?? "The screen session ended."
                    if actionable(reason) { state = .failed; message = reason }
                    else { reconnect(after: reason) }
                    return
                }
                if requestedControl { syncClipboard() }
            } catch {
                reconnect(after: error.localizedDescription)
                return
            }
        }
    }

    private func reconnect(after reason: String) {
        guard !stopped else { return }
        if let id = session?.id { closeTask = Task { await Bridge.screenViewerClose(id: id) } }
        session = nil
        connectedSince = nil
        streamingSince = nil
        decoder.reset(); audio.reset()
        reconnectAttempts += 1
        guard reconnectAttempts <= 3 else {
            state = .failed
            message = "Connection could not recover. \(reason)"
            return
        }
        state = .connecting
        // Say why. The reason used to be kept back until the third failure,
        // so the whole visible story of a session that could not stay up was
        // "Reconnecting…", which names nothing anybody can act on.
        message = "Reconnecting, attempt \(reconnectAttempts) of 3. \(reason)"
        let delay = reconnectAttempts
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func actionable(_ reason: String) -> Bool {
        let value = reason.lowercased()
        return value.contains("screen recording") || value.contains("accessibility")
            || value.contains("permission") || value.contains("not been allowed")
            || value.contains("does not have screen access") || value.contains("legend plan")
            || value.contains("no display") || value.contains("videotoolbox")
    }

    /// Put the pointer at a normalized point on the remote display.
    func move(to point: CGPoint) {
        cursor = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        send(["type":"move", "x":cursor.x, "y":cursor.y] as [String: Any])
    }

    /// Move the pointer by a distance measured on the viewer's own surface.
    ///
    /// Trackpad mode: the finger is not the pointer, so the client keeps the
    /// pointer position itself and sends an absolute point. The host stays a
    /// single "put it here", which is the only thing that survives two
    /// displays of different sizes.
    /// Move the pointer by a finger's worth of travel.
    ///
    /// `sensitivity` is the caller's, not a constant here, because how far a
    /// finger should move the pointer depends on how magnified the picture is
    /// and on whether somebody has asked for fine control. A fixed rate is
    /// what made zooming in useless: the picture got bigger and the pointer
    /// kept crossing it just as fast, so a four-pixel target stayed
    /// unreachable at every zoom level.
    func nudge(by delta: CGSize, in size: CGSize, sensitivity: CGFloat) {
        move(to: CGPoint(
            x: cursor.x + delta.width * sensitivity / max(1, size.width),
            y: cursor.y + delta.height * sensitivity / max(1, size.height)
        ))
    }

    /// Press and release in one message, with the count macOS needs to read a
    /// double click as a double click.
    func click(button: Int, count: Int) {
        send(["type":"click", "x":cursor.x, "y":cursor.y, "button":button, "clickCount":count] as [String: Any])
    }

    /// Hold or release the left button, for a drag that outlives one gesture.
    func press(_ down: Bool) {
        pointerIsDown = down
        send(["type":"mouse", "x":cursor.x, "y":cursor.y, "button":0, "down":down] as [String: Any])
    }

    func scroll(by delta: CGSize) {
        send(["type":"scroll", "x":cursor.x, "y":cursor.y, "dx":delta.width, "dy":delta.height] as [String: Any])
    }

    func sendKey(_ code: UInt16, down: Bool, flags: UInt64) {
        send(["type":"key", "keyCode":Int(code), "down":down, "flags":flags] as [String: Any])
    }

    func sendText(_ text: String, flags: UInt64) { send(["type":"text", "text":text, "flags":flags] as [String: Any]) }

    /// Turn control on or off on a session that is already running.
    ///
    /// Control is decided when the capability is issued, so switching means
    /// reopening the stream. The toggle used to be disabled while streaming
    /// instead, which meant control could never be turned on at all: the view
    /// starts streaming as it appears.
    func setControl(_ wanted: Bool) async {
        guard wanted != requestedControl, !peer.isEmpty else { return }
        if await flipControlOnLiveSession(wanted) { return }
        let tier = requestedTier
        stop()
        stopped = false
        requestedControl = wanted
        reconnectAttempts = 0
        state = .connecting
        message = wanted ? "Asking for control…" : "Switching to view only…"
        requestedTier = tier
        await connect()
        if state != .streaming && state != .connecting {
            requestedControl = false
        }
    }

    /// Turn control on or off on the session that is already up.
    ///
    /// The picture never stops, which is the point: reopening the stream meant
    /// a new screen channel, and the relay counts one per account, so the
    /// toggle raced the old channel's close and lost. Answers false when there
    /// is nothing live to flip or the host is too old to know the method, and
    /// the caller then falls back to reopening.
    /// Move a live session to a different budget.
    ///
    /// Never by reopening. The relay allows one screen channel per account, so
    /// a reopen races its own teardown, which is the whole reason control is
    /// flipped in place as well. A host too old to know the method keeps the
    /// picture it has, which is a worse picture and not a broken one.
    func setQuality(_ wanted: ScreenQualityChoice) async {
        guard wanted != quality else { return }
        quality = wanted
        guard let live = session, let hostSession = live.sessionId, !hostSession.isEmpty,
              state == .streaming || state == .connecting
        else { return }
        do {
            let identity = try await Bridge.machineIdentity()
            let capability = try await Bridge.onPeer(
                peer,
                "screen.capability.issue",
                ["peerId": identity.key, "control": requestedControl, "tier": requestedTier ?? ""],
                as: ScreenCapability.self
            )
            try await Bridge.setScreenQuality(
                peer: peer,
                sessionID: hostSession,
                capability: capability.token,
                // Automatic on a live session has to be said out loud: there is
                // no way to unsay a choice the host is already holding.
                quality: wanted.wire ?? ScreenQualityChoice.auto.rawValue
            )
        } catch {
            // Not worth a failed state. The session is still running and still
            // showing a picture, just not the one that was asked for.
        }
    }

    private func flipControlOnLiveSession(_ wanted: Bool) async -> Bool {
        guard let live = session, let hostSession = live.sessionId, !hostSession.isEmpty,
              state == .streaming || state == .connecting
        else { return false }
        do {
            let identity = try await Bridge.machineIdentity()
            // A fresh capability every time. The one this session opened with
            // says what it was opened for, and control is exactly the field
            // the host checks.
            let capability = try await Bridge.onPeer(
                peer,
                "screen.capability.issue",
                ["peerId": identity.key, "control": wanted, "tier": requestedTier ?? ""],
                as: ScreenCapability.self
            )
            try await Bridge.setScreenControl(
                peer: peer,
                sessionID: hostSession,
                capability: capability.token,
                control: wanted
            )
            requestedControl = wanted
            session?.control = wanted
            return true
        } catch {
            // An old host has no such method. Anything else is a real refusal
            // (the grant was narrowed, the plan lapsed), and reopening will
            // meet the same answer and report it where somebody can read it.
            return false
        }
    }

    /// Whether the live session is actually carrying input.
    var isControlling: Bool { requestedControl }
    func selectDisplay(_ id: UInt32) {
        guard displays.contains(where: { $0.id == id }) else { return }
        selectedDisplay = id
        decoder.reset()
        send(["type":"display", "id":id] as [String: Any])
    }
    private func syncClipboard() {
        let value: (Int, String?)
        #if os(macOS)
        value = (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string))
        #else
        value = (UIPasteboard.general.changeCount, UIPasteboard.general.string)
        #endif
        guard value.0 != clipboardChangeCount else { return }
        clipboardChangeCount = value.0
        guard let text = value.1, text.utf8.count <= 4_096 else { return }
        send(["type":"clipboard", "text":text])
    }
    private func applyClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardChangeCount = NSPasteboard.general.changeCount
        #else
        UIPasteboard.general.string = text
        clipboardChangeCount = UIPasteboard.general.changeCount
        #endif
    }
    /// Say "still here" on a beat, so the relay can tell a session somebody is
    /// watching from one nobody is.
    ///
    /// The relay cannot see inside an encrypted stream and must not try. What
    /// it can see is which direction bytes are moving, and on a screen channel
    /// everything flows one way: the host sends video, and the viewer sends
    /// almost nothing. That makes "the viewer has said nothing for two
    /// minutes" a usable definition of nobody is there, and this is what keeps
    /// it honest for somebody who is watching without touching anything.
    ///
    /// Deliberately not tied to control mode. A passive watcher is the exact
    /// case that would otherwise be cut off mid-session.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                // Any state with a session behind it, not just streaming. The
                // relay's idle cut does not care why the viewer went quiet,
                // so staying silent through a reconnect would have it close
                // the very session the reconnect is trying to resume.
                guard let id = self.session?.id else { continue }
                let payload = try? JSONSerialization.data(withJSONObject: ["type": "heartbeat"])
                guard let payload else { continue }
                try? await Bridge.screenViewerInput(id: id, data: payload)
            }
        }
    }

    /// Every input event, in the order it was made.
    ///
    /// One task per event let a move overtake the release that should have
    /// ended it: independent tasks have no order between them, and a drag that
    /// arrives after its own mouse-up leaves the far end holding a button
    /// nothing here will release. This chains each send onto the last, so the
    /// wire order is the gesture order.
    private func send(_ value: [String: Any]) {
        guard let id = session?.id, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        let isDisplay = (value["type"] as? String) == "display"
        guard isDisplay || session?.control == true else { return }
        let previous = inputTail
        inputTail = Task {
            await previous?.value
            try? await Bridge.screenViewerInput(id: id, data: data)
        }
    }

    func sendFile(_ url: URL) {
        guard transferTask == nil, !peer.isEmpty else { return }
        transferTask = Task { [weak self] in
            await self?.transfer(url)
            self?.transferTask = nil
        }
    }

    func cancelTransfer() { transferTask?.cancel() }

    private func transfer(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var id = ""
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            var size: UInt64 = 0
            while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data); size += UInt64(data.count)
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let resumeKey = Data("\(url.lastPathComponent)\u{0}\(size)\u{0}\(hash)".utf8)
            id = SHA256.hash(data: resumeKey).map { String(format: "%02x", $0) }.joined()
            let opened = try await Bridge.onPeer(peer, "screen.transfer.open", [
                "id": id, "name": url.lastPathComponent, "size": size, "digest": hash,
            ], as: ScreenTransferOpen.self)
            try handle.seek(toOffset: opened.offset)
            var offset = opened.offset
            transferProgress = size == 0 ? 1 : Double(offset) / Double(size)
            while let data = try handle.read(upToCount: min(opened.chunkBytes, 256 * 1024)), !data.isEmpty {
                try Task.checkCancellation()
                let answer = try await Bridge.onPeer(peer, "screen.transfer.chunk", [
                    "id": id, "offset": offset, "data": data.base64EncodedString(),
                ], as: ScreenTransferChunk.self)
                offset = answer.offset
                transferProgress = size == 0 ? 1 : Double(offset) / Double(size)
            }
            _ = try await Bridge.onPeer(peer, "screen.transfer.finish", ["id": id], as: ScreenTransferSaved.self)
            transferProgress = nil
        } catch is CancellationError {
            _ = try? await Bridge.onPeer(peer, "screen.transfer.cancel", ["id": id], as: ScreenTransferCancelled.self)
            transferProgress = nil
        } catch {
            transferProgress = nil
            message = error.localizedDescription
        }
    }
}

@MainActor
private final class ScreenAudioPlayer {
    var muted = false { didSet { if muted { player.stop() } } }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false

    func reset() {
        player.stop()
        engine.stop()
    }

    func play(_ data: Data) {
        guard !muted, data.count >= 16, String(data: data.prefix(4), encoding: .utf8) == "TAUD",
              data[4] == 1 else { return }
        let channels = AVAudioChannelCount(data[5])
        let rate: UInt32 = data.integer(at: 8)
        let frames: UInt32 = data.integer(at: 12)
        let samples = Int(frames) * Int(channels)
        guard channels > 0, channels <= 8, rate > 0,
              data.count == 16 + samples * MemoryLayout<Int16>.size,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let input = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Int16.self)
            for frame in 0..<Int(frames) {
                for channel in 0..<Int(channels) {
                    output[channel][frame] = Float(Int16(littleEndian: input[frame * Int(channels) + channel])) / Float(Int16.max)
                }
            }
        }
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try? engine.start()
            player.play()
            configured = true
        } else if !player.isPlaying {
            try? engine.start()
            player.play()
        }
        player.scheduleBuffer(buffer)
    }
}

private struct ScreenDisplay: Codable, Hashable, Identifiable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
}

private struct ScreenMetadata: Codable {
    let type: String
    let selected: UInt32?
    let displays: [ScreenDisplay]?
    let id: String?
    let text: String?
}

private struct ScreenEncodedFrame {
    let sequence: UInt64
    let width: UInt16
    let height: UInt16
    let keyframe: Bool
    let payload: Data
    init?(_ data: Data) {
        guard data.count >= 32, String(data: data.prefix(4), encoding: .utf8) == "TSCR", data[4] == 1, data[5] == 1 else { return nil }
        sequence = data.integer(at: 8)
        keyframe = data[6] & 1 == 1
        width = data.integer(at: 24)
        height = data.integer(at: 26)
        let count: UInt32 = data.integer(at: 28)
        guard data.count == 32 + Int(count) else { return nil }
        payload = data.subdata(in: 32..<data.count)
    }
}

@MainActor
private final class ScreenH264Decoder {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() { layer.videoGravity = .resizeAspect }
    func reset() { layer.flushAndRemoveImage(); format = nil }

    /// True when a picture was actually given to the display layer.
    @discardableResult
    func decode(_ frame: ScreenEncodedFrame) -> Bool {
        let units = frame.payload.annexBUnits()
        if frame.keyframe,
           let sps = units.first(where: { $0.first.map { $0 & 0x1f == 7 } == true }),
           let pps = units.first(where: { $0.first.map { $0 & 0x1f == 8 } == true })
        {
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [
                        spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes = [sps.count, pps.count]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        guard let format else { return false }
        // VCL only. SEI and AUD in the sample confuse the display layer, and
        // SPS/PPS already live in the format description.
        let pictures = units.filter { unit in
            guard let first = unit.first else { return false }
            let nal = Int(first & 0x1f)
            return (1...5).contains(nal)
        }
        var avcc = Data()
        for unit in pictures { avcc.appendBigEndian(UInt32(unit.count)); avcc.append(unit) }
        guard !avcc.isEmpty else { return false }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr,
              let block else { return false }
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr,
              let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary],
           let dict = attachments.first
        {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
        return true
    }
}

#if os(macOS)
private struct ScreenVideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> NSView { LayerHost(layer) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? LayerHost)?.layoutDisplay()
    }
    private final class LayerHost: NSView {
        let display: AVSampleBufferDisplayLayer
        init(_ display: AVSampleBufferDisplayLayer) {
            self.display = display
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(display)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            layoutDisplay()
        }
        func layoutDisplay() {
            display.frame = bounds
        }
    }
}
#else
private struct ScreenVideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> UIView { LayerHost(layer) }
    func updateUIView(_ view: UIView, context: Context) {
        (view as? LayerHost)?.layoutDisplay()
    }
    private final class LayerHost: UIView {
        let display: AVSampleBufferDisplayLayer
        init(_ display: AVSampleBufferDisplayLayer) {
            self.display = display
            super.init(frame: .zero)
            layer.addSublayer(display)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            layoutDisplay()
        }
        func layoutDisplay() {
            display.frame = bounds
        }
    }
}
#endif

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        self[offset..<offset + MemoryLayout<T>.size].reduce(0) { ($0 << 8) | T($1) }
    }
    func annexBUnits() -> [Data] {
        let bytes = [UInt8](self); var starts: [Int] = []
        var i = 0
        while i + 3 < bytes.count { if bytes[i...i+3] == [0,0,0,1] { starts.append(i + 4); i += 4 } else { i += 1 } }
        return starts.enumerated().map { index, start in Data(bytes[start..<(index + 1 < starts.count ? starts[index + 1] - 4 : bytes.count)]) }
    }
}
