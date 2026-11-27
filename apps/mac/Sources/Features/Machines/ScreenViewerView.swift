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
    @State private var viewOffset: CGSize = .zero
    @State private var fine = false
    @State private var dragLatched = false
    @State private var heldModifiers: UInt64 = 0
    @State private var keyboardWanted = false
    #if os(macOS)
    @State private var mode: ScreenPointerMode = .direct
    @State private var viewerIsFullScreen = false
    @State private var viewerWindow: NSWindow?
    #else
    @State private var mode: ScreenPointerMode = .trackpad
    @State private var immersive = false
    @State private var appliedLandscape = false
    @State private var keysRevealed = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
            if !isCompactHeight, !isImmersive {
                HStack(spacing: 6) {
                    Circle().fill(model.transport == "direct" ? Theme.success : Theme.warning).frame(width: 7, height: 7)
                    Text(model.transport == "direct" ? L10n.text("apple.screenviewerview.direct_connection.28d0ad54") : L10n.text("apple.screenviewerview.encrypted_relay.153d7b1c"))
                }
                .font(Theme.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .cancellationAction) {
                InspectorCloseButton(action: { dismiss() }, help: L10n.text("common.close"), label: L10n.text("apple.screenviewerview.close_screen_viewer.fec23bc8"))
            }
            #endif
            if model.displays.count > 1 {
                ToolbarItem {
                    Picker(L10n.text("apple.screenviewerview.display.34e108c0"), selection: Binding(
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
                        Button(L10n.text("apple.screenviewerview.send_file.cb4bef0b"), .upload) { importingFile = true }
                    } else {
                        Button(L10n.text("apple.screenviewerview.cancel_transfer.f48e8dc7"), .stop) { model.cancelTransfer() }
                    }
                }
            }
            ToolbarItem {
                Toggle(isOn: $muted) { Label(L10n.text("apple.screenviewerview.mute.8dd6857b"), systemImage: muted ? "speaker.slash" : "speaker.wave.2") }
                    .onChange(of: muted) { _, value in model.audio.muted = value }
            }
            ToolbarItem {
                Toggle(isOn: $controlling) { Label(L10n.text("apple.screenviewerview.control.32d7e820"), systemImage: "cursorarrow.motionlines") }
                    .disabled(model.state == .connecting)
            }
            ToolbarItem {
                Picker(L10n.text("apple.screenviewerview.quality.1b2c08a8"), selection: Binding(
                    get: { model.quality },
                    set: { choice in Task { await model.setQuality(choice) } }
                )) {
                    ForEach(ScreenQualityChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .help(L10n.text("apple.screenviewerview.how_much_of_the_connection_this_picture_ma.191b5e79"))
            }
            if controlling {
                ToolbarItem {
                    Picker(L10n.text("apple.screenviewerview.pointer.d00f1e4d"), selection: $mode) {
                        ForEach(ScreenPointerMode.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if zoom > 1.01 {
                ToolbarItem {
                    Button(L10n.text("apple.screenviewerview.fit.9f872ed4"), .collapse) {
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
                    viewerIsFullScreen ? L10n.text("apple.screenviewerview.exit_full_screen.897e0cf7") : L10n.text("apple.screenviewerview.full_screen.674fe2ac"),
                    viewerIsFullScreen ? .exitFullScreen : .enterFullScreen
                ) {
                    (viewerWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
                }
                .labelStyle(.iconOnly)
                .help(viewerIsFullScreen ? L10n.text("apple.screenviewerview.return_this_viewer_to_its_window.aa6bd450") : L10n.text("apple.screenviewerview.fill_this_display.e5ca2ad4"))
            }
            #else
            ToolbarItem {
                // The glyph alone. Spelled out, it was the only word in a row
                // of icons and took about half the bar on a phone, which on
                // the screen with the least room to spare is the one place a
                // label cannot afford to be a word. The title stays as the
                // accessibility label and the iPad tooltip.
                Button(L10n.text("apple.screenviewerview.full_screen.674fe2ac"), .enterFullScreen) {
                    withAnimation { immersive = true }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(L10n.text("apple.screenviewerview.full_screen.674fe2ac"))
            }
            #endif
            #if !os(macOS)
            if controlling {
                ToolbarItem {
                    Toggle(isOn: $keyboardWanted) { Label(L10n.text("apple.screenviewerview.keyboard.2316810a"), systemImage: "keyboard") }
                }
            }
            #endif
        }
        .onChange(of: controlling) { _, wanted in
            viewOffset = .zero
            #if !os(macOS)
            if !wanted { keysRevealed = false }
            #endif
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
                ProgressView(value: progress)
                    .frame(maxWidth: 280)
                    .padding()
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .overlay(alignment: .bottom) {
            if dragLatched, !showsKeyBar {
                HStack(spacing: Theme.Space.s) {
                    Text(L10n.text("apple.screenviewerview.holding_the_left_button.fcaabf2e"))
                    Button(L10n.text("apple.screenviewerview.release.e020e3c6"), .move) {
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
        .background {
            ViewerWindowBridge(window: $viewerWindow, isFullScreen: $viewerIsFullScreen)
        }
        #endif
        #if !os(macOS)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        .toolbar(immersive ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .onTapGesture {
            guard immersive, !controlling else { return }
            withAnimation { immersive = false }
        }
        .overlay(alignment: .topTrailing) {
            if immersive {
                Button(L10n.text("apple.screenviewerview.exit_full_screen.897e0cf7"), .exitFullScreen) {
                    withAnimation { immersive = false }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .labelStyle(.iconOnly)
                .padding(Theme.Space.m)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if controlling {
                VStack(spacing: 0) {
                    if !keyBarIsFurniture { keyBarHandle }
                    if showsKeyBar { keyBar }
                }
            }
        }
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
        .onAppear {
            if isCompactHeight {
                appliedLandscape = true
                immersive = true
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    private var isImmersive: Bool {
        #if os(macOS)
        false
        #else
        immersive
        #endif
    }

    private var showsKeyBar: Bool {
        #if os(macOS)
        false
        #else
        keyBarIsFurniture || keysRevealed
        #endif
    }

    private var keyBarIsFurniture: Bool {
        #if os(macOS)
        false
        #else
        !isCompactHeight && !immersive
        #endif
    }

    private var isCompactHeight: Bool {
        #if os(macOS)
        false
        #else
        verticalSizeClass == .compact
        #endif
    }

    private func start() async { await model.start(peer: peer, tier: tier, control: controlling) }

    @ViewBuilder
    private var overlayStatus: some View {
        VStack(spacing: Theme.Space.m) {
            if model.state == .connecting {
                // Fixed circular spinner. Bare `ProgressView()` on macOS 14
                // becomes a linear bar and walks the width of this overlay.
                BusySpinner()
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
                    readiness(L10n.text("apple.screenviewerview.legend_plan.1160a70f"), ready: tier?.lowercased() == "legend")
                    readiness(L10n.text("apple.screenviewerview.signed_in_and_paired.0cf50cf8"), ready: true)
                    readiness(L10n.text("apple.screenviewerview.computer_online.3793e57b"), ready: !model.message.localizedCaseInsensitiveContains("offline"))
                    readiness(L10n.text("apple.screenviewerview.per_device_screen_permission.2a9f7a46"), ready: !model.needsPermission)
                    readiness(
                        controlling ? L10n.text("apple.screenviewerview.screen_recording_and_accessibility.d2a661df") : L10n.text("apple.screenviewerview.screen_recording_on_that_computer.9102c9a7"),
                        ready: !model.message.localizedCaseInsensitiveContains("recording")
                    )
                }
                .padding(Theme.Space.m)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                if model.needsPermission {
                    Button(L10n.text("apple.screenviewerview.request_access.b06f1662"), .approve) { Task { await model.requestAccess() } }
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
                Button(L10n.text("apple.screenviewerview.try_again.d8b8392e"), .refresh) { Task { await start() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        .contentShape(Rectangle())
    }

    private var legendRequired: some View {
        VStack(spacing: Theme.Space.m) {
            #if os(macOS)
            TierMark(tier: "legend", size: 36)
            #else
            ClientEmptyArt(kind: .screen)
            #endif
            Text(L10n.text("apple.screenviewerview.screen_access_is_on_legend.6cb112d2"))
                .font(Theme.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(L10n.text("apple.screenviewerview.mouse_and_keyboard_never_travel_without_th.b97a2ef8"))
                .font(Theme.callout)
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.center)
            plansButton
        }
    }

    @ViewBuilder
    private var plansButton: some View {
        #if os(macOS)
        Link(L10n.text("apple.screenviewerview.see_plans.d9898933"), destination: URL(string: "https://tokenstat.ai/pricing")!)
            .buttonStyle(AccentButtonStyle())
        #else
        Button(L10n.text("apple.screenviewerview.see_plans.d9898933"), .plans) { store.showPaywall = true }
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

    private var pointerSensitivity: CGFloat {
        let base: CGFloat = 1.6
        return base / max(1, zoom) * (fine ? 0.35 : 1)
    }

    static let maxZoom: CGFloat = 8

    private var pointerAnchor: UnitPoint {
        controlling ? UnitPoint(x: model.cursor.x, y: model.cursor.y) : .center
    }

    private func clamped(_ offset: CGSize, in size: CGSize, at zoom: CGFloat) -> CGSize {
        let horizontal = max(0, size.width * (zoom - 1) / 2)
        let vertical = max(0, size.height * (zoom - 1) / 2)
        return CGSize(
            width: min(max(offset.width, -horizontal), horizontal),
            height: min(max(offset.height, -vertical), vertical)
        )
    }

    #if !os(macOS)
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

    private var keyBarHandle: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: 44, height: 4)
            Image(systemName: keysRevealed ? "chevron.down" : "chevron.up")
                .font(Theme.font(9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
        }
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
        .accessibilityLabel(keysRevealed ? L10n.text("apple.screenviewerview.hide_the_key_row.e589377c") : L10n.text("apple.screenviewerview.show_the_key_row.0fa3f684"))
        .accessibilityAddTraits(.isButton)
    }
    #endif

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
    var message = L10n.text("apple.screenviewerview.connecting.72021eb7")
    var aspectRatio: CGFloat = 16 / 9
    var displays: [ScreenDisplay] = []
    var selectedDisplay: UInt32?
    var transferProgress: Double?
    var transport = "relay"
    var cursor = CGPoint(x: 0.5, y: 0.5)
    let decoder = ScreenH264Decoder()
    let audio = ScreenAudioPlayer()
    private var session: ScreenViewerSession?
    private var task: Task<Void, Never>?
    private var pointerIsDown = false
    private var peer = ""
    private var transferTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var inputTail: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var clipboardChangeCount = -1
    private var requestedTier: String?
    private var requestedControl = false
    private var reconnectAttempts = 0
    private var connectedSince: Date?
    private var streamingSince: Date?
    private static let stableAfter: TimeInterval = 12
    private var stopped = false
    private var generation: UInt64 = 0
    private var lastAutoRequest = Date.distantPast
    private(set) var requestNotice: String?
    private(set) var isRequesting = false
    var quality: ScreenQualityChoice = .auto
    var needsPermission: Bool {
        let value = message.lowercased()
        return value.contains("permission") || value.contains("screen access") || value.contains("allowed")
    }
    var needsLegend: Bool {
        message.localizedCaseInsensitiveContains("legend plan")
    }

    func requestAccess() async {
        guard !isRequesting, !stopped else { return }
        let owner = generation
        isRequesting = true
        defer { isRequesting = false }
        do {
            var answer = try await Bridge.askScreenAccess(peer: peer, control: requestedControl)
            guard owner == generation, !stopped, !Task.isCancelled else { return }
            if answer.granted == true, !requestedControl {
                answer = try await Bridge.askScreenAccess(peer: peer, control: true)
            }
            guard owner == generation, !stopped, !Task.isCancelled else { return }
            if answer.granted == true {
                requestNotice = L10n.text("apple.screenviewerview.this_device_already_has_access_press_try_a.fd1aee06")
                return
            }
            requestNotice = L10n.text("apple.screenviewerview.asked_approve_this_device_on_that_computer.f8ffae43")
        } catch {
            guard owner == generation, !stopped, !Task.isCancelled else { return }
            requestNotice = error.localizedDescription
            return
        }
        if let sent = try? await Bridge.requestScreenAccess(), sent.signedIn, sent.enabled, sent.sent > 0 {
            guard owner == generation, !stopped, !Task.isCancelled else { return }
            requestNotice = L10n.text("apple.screenviewerview.asked_a_notification_went_to_your_other_de.3be993ac")
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
        message = L10n.text("apple.screenviewerview.connecting.72021eb7")
        await connect()
    }

    private func connect() async {
        let owner = generation
        func isCurrent() -> Bool { owner == generation && !stopped && !Task.isCancelled }
        await awaitClose()
        guard isCurrent() else { return }
        let tier = requestedTier
        let control = requestedControl
        guard tier?.lowercased() == "legend" else {
            state = .failed
            message = L10n.text("apple.screenviewerview.screen_access_requires_the_legend_plan.66173f1c")
            return
        }
        do {
            let identity = try await Bridge.machineIdentity()
            guard isCurrent() else { return }
            let capability = try await Bridge.onPeer(
                peer,
                "screen.capability.issue",
                ["peerId": identity.key, "control": control, "tier": tier ?? ""],
                as: ScreenCapability.self
            )
            guard isCurrent() else { return }
            let session = try await Bridge.screenViewerOpen(
                peer: peer,
                capability: capability.token,
                control: control,
                quality: quality
            )
            guard isCurrent() else {
                await Bridge.screenViewerClose(id: session.id)
                return
            }
            self.session = session
            transport = session.transport
            connectedSince = Date()
            streamingSince = nil
            state = .connecting
            message = L10n.text("apple.screenviewerview.waiting_for_the_first_picture.be8d50cf")
            task = Task { [weak self] in await self?.readLoop(session.id) }
        } catch {
            guard isCurrent() else { return }
            let reason = error.localizedDescription
            if actionable(reason) {
                state = .failed
                message = reason
                if needsPermission, Date().timeIntervalSince(lastAutoRequest) > 60 {
                    lastAutoRequest = Date()
                    await requestAccess()
                }
            } else {
                reconnect(after: reason)
            }
        }
    }

    func stop() {
        generation &+= 1
        stopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel()
        task = nil
        if let id = session?.id {
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

    private func awaitClose() async {
        guard let closing = closeTask else { return }
        closeTask = nil
        await closing.value
    }

    private func readLoop(_ id: String) async {
        while !Task.isCancelled {
            do {
                let read = try await Bridge.screenViewerRead(id: id)
                guard !Task.isCancelled, !stopped, session?.id == id else { return }
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
                            streamingSince = Date()
                        }
                        if state != .streaming { state = .streaming }
                    }
                }
                if state != .streaming,
                   let since = connectedSince,
                   Date().timeIntervalSince(since) > 8
                {
                    await Bridge.screenViewerClose(id: id)
                    guard !Task.isCancelled, !stopped, session?.id == id else { return }
                    session = nil
                    connectedSince = nil
                    streamingSince = nil
                    state = .failed
                    message = L10n.text("apple.screenviewerview.connected_but_no_picture_has_arrived_yet_t.ded4562c")
                    return
                }
                if let encoded = read.audio, let data = Data(base64Encoded: encoded) {
                    audio.play(data)
                }
                if !read.active {
                    let reason = read.error ?? L10n.text("apple.screenviewerview.the_screen_session_ended.c37a27b0")
                    if actionable(reason) { state = .failed; message = reason }
                    else { reconnect(after: reason) }
                    return
                }
                if requestedControl { syncClipboard() }
            } catch {
                guard !Task.isCancelled, !stopped, session?.id == id else { return }
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
            message = L10n.text("apple.screenviewerview.connection_could_not_recover_0.7c8ca1d2", "\(reason)")
            return
        }
        state = .connecting
        message = L10n.text("apple.screenviewerview.reconnecting_attempt_0_of_3_1.8f4f26ac", "\(reconnectAttempts)", "\(reason)")
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

    func move(to point: CGPoint) {
        cursor = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        send(["type":"move", "x":cursor.x, "y":cursor.y] as [String: Any])
    }

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

    func setControl(_ wanted: Bool) async {
        guard wanted != requestedControl, !peer.isEmpty else { return }
        let owner = generation
        if await flipControlOnLiveSession(wanted) { return }
        guard owner == generation, !stopped, !Task.isCancelled else { return }
        let tier = requestedTier
        stop()
        stopped = false
        startHeartbeat()
        requestedControl = wanted
        reconnectAttempts = 0
        state = .connecting
        message = wanted ? L10n.text("apple.screenviewerview.asking_for_control.50c714d1") : L10n.text("apple.screenviewerview.switching_to_view_only.d67a2762")
        requestedTier = tier
        await connect()
        if state != .streaming && state != .connecting {
            requestedControl = false
        }
    }

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
                quality: wanted.wire ?? ScreenQualityChoice.auto.rawValue
            )
        } catch {
        }
    }

    private func flipControlOnLiveSession(_ wanted: Bool) async -> Bool {
        guard let live = session, let hostSession = live.sessionId, !hostSession.isEmpty,
              state == .streaming || state == .connecting
        else { return false }
        do {
            let identity = try await Bridge.machineIdentity()
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
            guard !stopped, !Task.isCancelled, session?.id == live.id else { return true }
            requestedControl = wanted
            session?.control = wanted
            return true
        } catch {
            return false
        }
    }

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
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                guard let id = self.session?.id else { continue }
                let payload = try? JSONSerialization.data(withJSONObject: ["type": "heartbeat"])
                guard let payload else { continue }
                try? await Bridge.screenViewerInput(id: id, data: payload)
            }
        }
    }

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
            for frame in 0..<Int(frames) {
                for channel in 0..<Int(channels) {
                    output[channel][frame] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 16 + (frame * Int(channels) + channel) * 2, as: Int16.self))) / Float(Int16.max)
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
        guard width > 0, height > 0, data.count == 32 + Int(count) else { return nil }
        payload = data.subdata(in: 32..<data.count)
    }
}

@MainActor
private final class ScreenH264Decoder {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() { layer.videoGravity = .resizeAspect }
    func reset() { layer.flushAndRemoveImage(); format = nil }

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
