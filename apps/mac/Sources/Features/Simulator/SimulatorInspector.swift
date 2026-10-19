// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI
import AppKit
import Observation

@MainActor
struct SimulatorInspector: View {
    let workspaceID: String
    let isActive: Bool
    @Binding var request: SimulatorAttachmentIntent?

    var body: some View {
        let owner = WorkViewedChange.owner(folderID: workspaceID)
        let local = WorkDestinationResolver.route(folderID: workspaceID).peer == nil
        if local {
            SimulatorInspectorContent(preferenceKey: BrowserHistory.key(for: owner) ?? workspaceID,
                isActive: isActive, request: $request)
                .id(owner)
        } else {
            ContentUnavailableView(L10n.text("apple.simulator.title"), systemImage: "iphone",
                description: Text(L10n.text("apple.simulator.local_only")))
        }
    }
}

@MainActor
private struct SimulatorInspectorContent: View {
    let isActive: Bool
    @Binding var request: SimulatorAttachmentIntent?
    @State private var session: SimulatorSession
    @State private var settings = false
    @State private var viewer: SimulatorViewerWindow?
    @Environment(\.colorScheme) private var colorScheme

    init(preferenceKey: String, isActive: Bool, request: Binding<SimulatorAttachmentIntent?>) {
        self.isActive = isActive; _request = request
        _session = State(initialValue: SimulatorSession(preferenceKey: preferenceKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SimulatorErrorBanner(session: session)
            if session.devices.isEmpty && !session.busy {
                ScrollView {
                    SimulatorSetupView(setup: session.setup, refreshing: session.isRefreshing) {
                        Task { await session.refresh(force: true) }
                    }.padding(18)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if session.perspective && !session.hasFrame { SimulatorAttachmentBar(session: session) }
                SimulatorDeviceStage(session: session, isActive: isActive)
                SimulatorControls(session: session, onExpand: openViewer)
            }
        }
        .background(Theme.background)
        .task(id: surfaceIsActive) {
            session.setActive(surfaceIsActive)
            guard surfaceIsActive else { return }
            await session.refresh(force: request != nil)
            applyRequest()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                await session.refresh()
                applyRequest()
            }
        }
        .task(id: request?.id) {
            guard surfaceIsActive, request != nil else { return }
            applyRequest(reportMissing: false)
            guard request != nil else { return }
            await session.refresh(force: true)
            applyRequest()
        }
        .onChange(of: colorScheme) { _, value in viewer?.updateAppearance(value) }
        .onDisappear { viewer?.close(); viewer = nil; session.detach(); session.setActive(false) }
    }

    private var surfaceIsActive: Bool { isActive || viewer?.isVisible == true }

    private func openViewer() {
        if viewer == nil { viewer = SimulatorViewerWindow(session: session, colorScheme: colorScheme) }
        viewer?.show()
    }

    private func applyRequest(reportMissing: Bool = true) {
        guard !Task.isCancelled, surfaceIsActive, let id = request?.deviceID else { return }
        if session.attachedID == id { request = nil; return }
        if session.devices.contains(where: { $0.id == id }) {
            // A link or external boot is a one-time action. Clearing the
            // owner's request also prevents replay after navigating away.
            request = nil
            session.attach(id)
        } else if reportMissing, session.setup.status(for: id.hasPrefix("android:") ? .android : .ios) == .toolsMissing {
            request = nil
            // The empty pane already shows setup. With another platform
            // available, reveal the requested platform's setup cards once.
            settings = !session.devices.isEmpty
        } else if reportMissing, session.setup.status(for: id.hasPrefix("android:") ? .android : .ios).isAuthoritative {
            request = nil
            session.error = L10n.text("apple.simulator.device_missing")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
            Menu {
                ForEach(session.orderedDevices) { device in
                    Button {
                        request = nil
                        session.selectedID = device.id
                        if session.attachedID != nil { session.attach(device.id) }
                    } label: {
                        Label(device.name + " · " + device.runtime,
                              systemImage: device.id == session.selectedID ? "checkmark" : session.favorites.contains(device.id) ? "pin.fill" : device.isTablet ? "ipad" : "iphone")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: session.selected?.isTablet == true ? "ipad" : "iphone").foregroundStyle(Theme.accent)
                    Text(session.selected?.name ?? L10n.text("apple.simulator.choose_device")).font(Theme.font(13, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(Theme.font(10)).foregroundStyle(Theme.controlGlyph)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton).disabled(session.busy || session.devices.isEmpty)
            Text(session.selected?.runtime ?? L10n.text("apple.simulator.ios_subtitle"))
                .font(Theme.font(11)).foregroundStyle(Theme.controlGlyph).padding(.leading, 24)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ToolbarIconButton(systemImage: ActionIcon.refresh.symbol, help: L10n.text("apple.simulator.refresh")) { Task { await session.refresh(force: true) } }
            ToolbarIconButton(systemImage: ActionIcon.settings.symbol, help: L10n.text("apple.simulator.preferences")) { settings.toggle() }
                .popover(isPresented: $settings) {
                    ScrollView { preferences.padding(18) }.frame(width: 350).frame(maxHeight: 640)
                }
        }.padding(12).background(Theme.sidebar).overlay(alignment: .bottom) { ThemeRule() }
    }

    private var preferences: some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("apple.simulator.preferences")).font(Theme.font(15, weight: .semibold))
            Toggle(L10n.text("apple.simulator.follow_agents"), isOn: $session.followsAgents)
            Text(L10n.text("apple.simulator.follow_help")).font(Theme.font(12)).foregroundStyle(Theme.controlGlyph)
            if let device = session.selected {
                Button(session.favorites.contains(device.id) ? L10n.text("apple.simulator.unfavorite") : L10n.text("apple.simulator.favorite"), .pin) { session.toggleFavorite(device.id) }
                Button(L10n.text("apple.simulator.use_default"), .device) { session.defaultID = device.id }
                    .disabled(session.defaultID == device.id)
                if session.defaultID != nil {
                    Button(L10n.text("apple.simulator.clear_default"), .restore) { session.defaultID = nil }
                }
            }
            Text(L10n.text("apple.simulator.selection_help")).font(Theme.font(12)).foregroundStyle(Theme.controlGlyph)
            Button(session.selected?.platform == .android ? L10n.text("apple.simulator.open_android_studio") : L10n.text("apple.simulator.open_xcode"), .external) { session.openExternally() }
            Text(L10n.text("apple.simulator.android_help")).font(Theme.font(12)).foregroundStyle(Theme.controlGlyph)
            ThemeRule()
            SimulatorSetupView(setup: session.setup, refreshing: session.isRefreshing, showsHeader: false) {
                Task { await session.refresh(force: true) }
            }
        }.font(Theme.font(13))
    }

}

private struct SimulatorAttachmentBar: View {
    let session: SimulatorSession
    var body: some View {
        HStack(spacing: 8) {
            if session.busy {
                ProgressView().controlSize(.small)
                Text(L10n.text("apple.simulator.booting")).font(Theme.font(12))
                Spacer(minLength: 0)
                Button(L10n.text("apple.simulator.cancel_attach"), .stop) { session.detach() }
            } else {
                Button(L10n.text("apple.simulator.attach"), .connect) { session.attach() }
                    .buttonStyle(.borderedProminent).disabled(session.selected == nil)
                Spacer(minLength: 0)
                if session.attachedID != nil {
                    Button(L10n.text("apple.simulator.detach"), .disconnect) { session.detach() }
                }
            }
        }.padding(12).background(Theme.panel).overlay(alignment: .bottom) { ThemeRule() }
    }
}

private struct SimulatorErrorBanner: View {
    let session: SimulatorSession
    @ViewBuilder var body: some View {
        if let error = session.error, error != session.setup.apple.failure, error != session.setup.android.failure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                Text(error).font(Theme.font(12)).textSelection(.enabled).lineLimit(4).help(error)
                Spacer(minLength: 0)
                ToolbarIconButton(systemImage: ActionIcon.dismiss.symbol, help: L10n.text("common.close")) { session.error = nil }
            }.padding(12).background(Theme.panel)
        }
    }

}

private struct SimulatorDeviceStage: View {
    let session: SimulatorSession
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let pixels = session.hasFrame ? session.pixels : session.previewPixels
            let aspect = pixels.width / max(1, pixels.height)
            let available = CGSize(width: max(100, geometry.size.width - 52), height: max(100, geometry.size.height - 48))
            let height = min(available.height, available.width / aspect) * session.zoom
            let width = height * aspect
            ZStack {
                RadialGradient(colors: [Theme.accentSoft.opacity(0.65), Theme.background], center: .center, startRadius: 20, endRadius: max(200, geometry.size.height * 0.65))
                if session.perspective {
                    SimulatorDeviceModel(session: session, visible: isActive)
                    VStack {
                        Spacer()
                        Text(L10n.text("apple.simulator.drag_to_rotate"))
                            .font(Theme.font(11)).foregroundStyle(Theme.controlGlyph)
                            .padding(12).background(Theme.panel.opacity(0.9), in: Capsule())
                            .padding(16)
                    }.allowsHitTesting(false)
                } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 14) {
                        device(width: width, height: height).padding(18)
                    }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }.scrollIndicators(.hidden)
                }
            }
        }
        .clipped()
    }

    private func device(width: CGFloat, height: CGFloat) -> some View {
        let radius = min(width * (session.selected?.isTablet == true ? 0.045 : 0.12), 38.0)
        return ZStack {
            RoundedRectangle(cornerRadius: radius + 8)
                .fill(LinearGradient(colors: [Theme.controlGlyph.opacity(0.6), Theme.border, Theme.controlGlyph.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(-7)
                .shadow(color: Theme.controlGlyph.opacity(0.22), radius: 16, y: 12)
            RoundedRectangle(cornerRadius: radius + 4).fill(.black).padding(-4)
            if session.attachedID != nil {
                SimulatorScreen(session: session, interactive: isActive,
                    cornerRadius: radius, visible: isActive && session.hasFrame)
                    .frame(width: width, height: height)
            }
            if !session.hasFrame {
                VStack(spacing: 16) {
                    Image(systemName: session.selected?.isTablet == true ? "ipad" : "iphone")
                        .font(Theme.font(38, weight: .ultraLight)).foregroundStyle(Theme.controlGlyph)
                    Text(session.busy ? L10n.text("apple.simulator.booting") : L10n.text("apple.simulator.attach_title"))
                        .font(Theme.font(18, weight: .semibold)).multilineTextAlignment(.center)
                    Text(session.devices.isEmpty ? L10n.text("apple.simulator.install_help") : L10n.text("apple.simulator.attach_help"))
                        .font(Theme.font(12)).foregroundStyle(Theme.controlGlyph).multilineTextAlignment(.center)
                    if session.busy {
                        ProgressView().controlSize(.small)
                        Button(L10n.text("apple.simulator.cancel_attach"), .stop) { session.detach() }
                    }
                    else {
                        Button(L10n.text("apple.simulator.attach"), .connect) { session.attach() }
                            .buttonStyle(.borderedProminent).disabled(session.selected == nil)
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius))
            }
        }.frame(width: width, height: height)
    }

}

private struct SimulatorControls: View {
    let session: SimulatorSession
    var isExpanded = false
    var onExpand: () -> Void
    @State private var confirmsShutdown = false

    var body: some View {
        VStack(spacing: 8) {
            if let message = session.message {
                Text(message).font(Theme.font(11)).foregroundStyle(Theme.controlGlyph).lineLimit(2)
            }
            HStack(spacing: 4) {
                ToolbarIconButton(systemImage: ActionIcon.home.symbol, help: L10n.text("apple.simulator.home")) { session.button(0) }
                ToolbarIconButton(systemImage: "lock", help: L10n.text("apple.simulator.lock")) { session.button(1) }
                Menu {
                    Button(L10n.text("apple.simulator.portrait"), .layout) { session.rotate(1) }
                    Button(L10n.text("apple.simulator.landscape_left"), .layout) { session.rotate(3) }
                    Button(L10n.text("apple.simulator.landscape_right"), .layout) { session.rotate(4) }
                    Button(L10n.text("apple.simulator.upside_down"), .layout) { session.rotate(2) }
                } label: { Image(systemName: "rotate.right").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.text("apple.simulator.rotate"))
                    .accessibilityLabel(L10n.text("apple.simulator.rotate"))
                ToolbarIconButton(systemImage: "camera", help: L10n.text("apple.simulator.screenshot")) { session.screenshot() }
                Menu {
                    if session.attached?.platform == .ios, session.attached?.isFoldable == true {
                        Button(L10n.text("apple.simulator.fold_open"), .layout) { session.fold(180) }
                        Button(L10n.text("apple.simulator.fold_half"), .layout) { session.fold(90) }
                        Button(L10n.text("apple.simulator.fold_closed"), .layout) { session.fold(0) }
                    }
                    Button(L10n.text("apple.simulator.light"), .theme) { session.command(["ui", "{device}", "appearance", "light"]) }
                    Button(L10n.text("apple.simulator.dark"), .theme) { session.command(["ui", "{device}", "appearance", "dark"]) }
                    Button(L10n.text("apple.simulator.paste"), .copy) {
                        if let text = NSPasteboard.general.string(forType: .string) { session.command(["pbcopy", "{device}"], input: Data(text.utf8)) }
                    }
                    Button(L10n.text("apple.simulator.settings_app"), .settings) { session.command(["launch", "{device}", "com.apple.Preferences"]) }
                    Button(session.attached?.platform == .android ? L10n.text("apple.simulator.open_android_studio") : L10n.text("apple.simulator.open_xcode"), .external) { session.openExternally() }
                    Button(L10n.text("apple.simulator.detach"), .disconnect) { session.detach() }
                    Button(L10n.text("apple.simulator.shutdown"), .stop) { confirmsShutdown = true }
                } label: { Image(systemName: ActionIcon.more.symbol).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.text("apple.simulator.more"))
                    .accessibilityLabel(L10n.text("apple.simulator.more"))
            }.disabled(session.attachedID == nil || session.busy || !session.hasFrame)
            HStack(spacing: 4) {
                ToolbarIconButton(systemImage: "minus.magnifyingglass", help: L10n.text("apple.simulator.zoom_out")) { session.zoom = max(0.5, session.zoom - 0.25) }
                Button(L10n.text("apple.simulator.fit"), .preview) { session.zoom = 1; session.perspective = false }
                    .buttonStyle(.plain).font(Theme.font(11))
                ToolbarIconButton(systemImage: "plus.magnifyingglass", help: L10n.text("apple.simulator.zoom_in")) { session.zoom = min(3, session.zoom + 0.25) }
                Spacer(minLength: 0)
                ToolbarIconButton(systemImage: "cube", help: L10n.text("apple.simulator.perspective"), isAccent: session.perspective) {
                    session.perspective.toggle()
                }
                ToolbarIconButton(systemImage: isExpanded ? ActionIcon.dismiss.symbol : ActionIcon.enterFullScreen.symbol, help: isExpanded ? L10n.text("common.close") : L10n.text("apple.simulator.expand")) { onExpand() }
            }
        }.padding(10).background(Theme.sidebar).overlay(alignment: .top) { ThemeRule() }
        .confirmationDialog(L10n.text("apple.simulator.shutdown_confirm"), isPresented: $confirmsShutdown) {
            Button(L10n.text("apple.simulator.shutdown"), role: .destructive) { session.shutdown() }
        }
    }
}

/// A document-style native window keeps the Metal surface in its own
/// compositing tree while the editor and the device session remain available.
@MainActor @Observable
private final class SimulatorViewerWindow: NSObject, NSWindowDelegate {
    private(set) var isVisible = false
    private let window: NSWindow
    private let session: SimulatorSession
    private var hasContent = false

    init(session: SimulatorSession, colorScheme: ColorScheme) {
        self.session = session
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 1000)
        let size = CGSize(width: min(740, max(540, available.width - 100)), height: min(900, max(640, available.height - 100)))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = L10n.text("apple.simulator.title")
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = NSColor(Theme.background)
        window.minSize = CGSize(width: 540, height: 640)
        window.delegate = self
        updateAppearance(colorScheme)
        window.center()
    }
    func updateAppearance(_ scheme: ColorScheme) { window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) }
    func show() {
        if !hasContent {
            window.contentView = NSHostingView(rootView: SimulatorExpandedContent(session: session) { [weak self] in self?.close() })
            hasContent = true
        }
        isVisible = true; window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
    }
    func close() { window.close(); isVisible = false }
    func windowWillClose(_ notification: Notification) { isVisible = false; window.makeFirstResponder(nil); window.contentView = nil; hasContent = false }
    func windowDidMiniaturize(_ notification: Notification) { isVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { isVisible = true }
}

private struct SimulatorExpandedContent: View {
    let session: SimulatorSession
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ModalHeader(title: session.attached?.name ?? L10n.text("apple.simulator.title"),
                subtitle: session.attached?.runtime ?? L10n.text("apple.simulator.ios_subtitle"), icon: .device, onClose: onClose)
            ThemeRule()
            SimulatorErrorBanner(session: session)
            if session.devices.isEmpty && !session.busy {
                ScrollView {
                    SimulatorSetupView(setup: session.setup, refreshing: session.isRefreshing) {
                        Task { await session.refresh(force: true) }
                    }.padding(18)
                }
            } else {
                if session.perspective && !session.hasFrame { SimulatorAttachmentBar(session: session) }
                SimulatorDeviceStage(session: session, isActive: true)
                SimulatorControls(session: session, isExpanded: true, onExpand: onClose)
            }
        }.frame(minWidth: 540, minHeight: 600).background(Theme.background)
    }
}
#endif
