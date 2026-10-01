// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI

struct SidebarDetailField: Identifiable {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .primary
    var numeric = false
    var monospaced = false
    var id: String { title }
}

/// A compact identity card beside a sidebar row. The card can keep the pointer
/// while someone crosses from its row to an action such as Reveal in Finder.
struct SidebarDetailCard<Footer: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let path: String
    let fields: [SidebarDetailField]
    var git: GitStatus? = nil
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(Theme.fit(17, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.fit(14, weight: .semibold))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(Theme.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: field.symbol)
                            .font(Theme.fit(11)).foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(field.title).font(Theme.fit(12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: Theme.Space.s)
                        Text(field.value)
                            .font(field.monospaced ? Theme.monoText(12) : field.numeric ? Theme.numeric(12, weight: .medium) : Theme.fit(12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(field.tint)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let git, git.isRepo {
                SidebarGitDetail(git: git)
            }
            ThemeRule()
            Text(path).font(Theme.caption).foregroundStyle(.tertiary)
                .lineLimit(3).truncationMode(.middle)
                .textSelection(.enabled)
            footer
        }
        .padding(Theme.Space.m)
        .frame(width: DisplayFit.dp(340), alignment: .leading)
        .background(Theme.panel)
    }
}

private struct SidebarGitDetail: View {
    let git: GitStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
                Text(git.branch.flatMap { $0.isEmpty ? nil : $0 } ?? "Detached HEAD")
                    .font(Theme.monoText(12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .accessibilityLabel(L10n.text("apple.rootview.branch.52656e81") + ": " + (git.branch ?? "Detached HEAD"))
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(L10n.text("apple.rootview.changed_files.5d4041aa"))
                    .font(Theme.fit(12)).foregroundStyle(.secondary)
                Text(git.files.count.formatted()).font(Theme.numeric(12))
                Spacer(minLength: Theme.Space.s)
                if !git.files.isEmpty {
                    HStack(spacing: 8) {
                        Text("+\(git.added.formatted())").foregroundStyle(Theme.diffAdded)
                        Text("−\(git.removed.formatted())").foregroundStyle(Theme.diffRemoved)
                    }
                    .font(Theme.numeric(12, weight: .semibold))
                    .accessibilityLabel(L10n.text("apple.rootview.lines.3b26a542") + ": +\(git.added) −\(git.removed)")
                }
            }
            if git.partial {
                Text(L10n.text("apple.sidebarhovercard.partial_line_counts"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            if git.ahead > 0 || git.behind > 0 {
                HStack(spacing: Theme.Space.s) {
                    Text(L10n.text("apple.rootview.upstream.94adc696"))
                        .font(Theme.fit(12)).foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Space.s)
                    Label("\(git.ahead.formatted())", systemImage: "arrow.up")
                        .foregroundStyle(Theme.accent)
                    Label("\(git.behind.formatted())", systemImage: "arrow.down")
                        .foregroundStyle(git.behind > 0 ? Theme.warning : Theme.controlGlyph)
                }
                .font(Theme.numeric(12))
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.18)))
    }
}

struct SidebarChatDetailCard: View {
    let conversation: ChatConversation
    let folder: WorkspaceFolder
    @State private var usage: ChatUsageTotals?
    @State private var finishedLoading = false
    @State private var loadFailed = false

    var body: some View {
        SidebarDetailCard(
            title: conversation.title.isEmpty ? L10n.text("apple.sidebarhovercard.untitled_conversation.31d248c4") : conversation.title,
            subtitle: L10n.text("apple.sidebarhovercard.chat_0.34012b11", "\(harnessName(conversation.backend))"),
            symbol: "bubble.left.and.bubble.right",
            path: folder.path,
            fields: fields,
            git: folder.git
        ) { EmptyView() }
        .task(id: "\(conversation.id)-\(conversation.updatedAtMs)") {
            finishedLoading = false
            let route = Bridge.chatRoute(workspaceID: folder.id)
            let page = try? await Bridge.chatEventPage(id: conversation.id, cursor: nil, limit: 1, peer: route.peer)
            guard !Task.isCancelled else { return }
            usage = page?.usage.flatMap { $0.isValid ? $0 : nil }
            loadFailed = page == nil
            finishedLoading = true
        }
    }

    private var fields: [SidebarDetailField] {
        var fields = [
            SidebarDetailField(title: L10n.text("apple.sidebarhovercard.project.98595978"), value: folder.name, symbol: "folder"),
            SidebarDetailField(title: L10n.text("apple.sidebarhovercard.computer.76ed42d2"), value: folder.sidebarComputer, symbol: "laptopcomputer"),
            SidebarDetailField(title: L10n.text("apple.sidebarhovercard.status.920e413c"), value: conversation.running ? L10n.text("common.working") : L10n.text("apple.sidebarhovercard.ready"), symbol: "circle.dotted", tint: conversation.running ? Theme.stateWorking : Theme.controlGlyph),
        ]
        if let model = conversation.model, !model.isEmpty {
            fields.append(.init(title: L10n.text("apple.sidebarhovercard.model.5e2c614c"), value: model, symbol: "sparkles"))
        }
        if let usage, !usage.isEmpty {
            let total = Decimal(usage.input) + Decimal(usage.output) + usage.cache
            fields.append(.init(title: L10n.text("apple.sidebarhovercard.tokens.a039dfb9"), value: total.formatted(), symbol: "number", numeric: true))
            fields.append(.init(title: L10n.text("apple.sidebarhovercard.fresh_input.a5156480"), value: usage.input.formatted(), symbol: "arrow.down", numeric: true))
            fields.append(.init(title: L10n.text("apple.sidebarhovercard.tokens_out.da9a58f8"), value: usage.output.formatted(), symbol: "arrow.up", numeric: true))
            if usage.cache > 0 {
                fields.append(.init(title: L10n.text("apple.sidebarhovercard.cached_tokens.3efd7d16"), value: usage.cache.formatted(), symbol: "arrow.clockwise", numeric: true))
            }
        } else {
            fields.append(.init(title: L10n.text("apple.sidebarhovercard.tokens.a039dfb9"), value: !finishedLoading ? L10n.text("apple.sidebarhovercard.checking") : loadFailed ? L10n.text("apple.sidebarhovercard.usage_unavailable") : L10n.text("apple.sidebarhovercard.usage_not_reported"), symbol: "number", tint: .secondary))
        }
        fields.append(.init(title: L10n.text("apple.sidebarhovercard.last_message.ee5c88bf"), value: sidebarDate(conversation.lastMessageAtMs), symbol: "clock"))
        return fields
    }
}

extension WorkspaceFolder {
    var sidebarComputer: String { isRemote ? machineLabel ?? L10n.text("apple.sidebarhovercard.other_computer.dc797a69") : L10n.text("apple.sidebarhovercard.this_computer.26f9f95a") }
}

func sidebarDate(_ milliseconds: Int64?) -> String {
    guard let milliseconds else { return L10n.text("apple.sidebarhovercard.no_messages_yet.f42e0f66") }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        .formatted(date: .abbreviated, time: .shortened)
}

/// Application-defined popovers do not consume the click that selects another
/// row. Pointer checks span the row, the gap and the card, without taking focus
/// from a terminal or composer.
private struct SidebarHoverPresentation<Card: View>: NSViewRepresentable {
    let hovering: Bool
    let enabled: Bool
    let suppressOpening: Bool
    @ViewBuilder let card: () -> Card

    func makeNSView(context: Context) -> NSView {
        let view = SidebarHoverAnchor()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(anchor: view, hovering: hovering, enabled: enabled,
                                   suppressOpening: suppressOpening, card: card())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator {
        private weak var anchor: NSView?
        private var popover: NSPopover?
        private var pending: Task<Void, Never>?
        private var localMonitor: Any?
        private var globalMonitor: Any?
        private var pointerTimer: Timer?
        private var pointerState = SidebarHoverState()
        private var hovered = false
        private var enabled = false
        private var suppressOpening = false
        private var card: Card?

        func update(anchor: NSView, hovering: Bool, enabled: Bool, suppressOpening: Bool, card: Card) {
            self.anchor = anchor
            self.card = card
            let enabledChanged = self.enabled != enabled
            let suppressionChanged = self.suppressOpening != suppressOpening
            self.enabled = enabled
            self.suppressOpening = suppressOpening
            if let controller = popover?.contentViewController as? NSHostingController<Card> {
                controller.rootView = card
            }
            guard enabled else {
                hovered = hovering
                close()
                return
            }
            guard hovered != hovering || enabledChanged || suppressionChanged else { return }
            hovered = hovering
            pending?.cancel()
            pending = nil
            if popover != nil {
                checkPointer()
                return
            }
            guard hovering, !suppressOpening else { return }
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                self.show()
            }
        }

        private var containsPointer: Bool {
            let cardRect = popover?.contentViewController?.view.window?.frame
            var rowRect: NSRect?
            if let anchor, let window = anchor.window {
                rowRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            }
            return SidebarHoverState.contains(NSEvent.mouseLocation, row: rowRect, card: cardRect)
        }

        private func show() {
            guard enabled, hovered, containsPointer, !suppressOpening, !SidebarMenuTracking.shared.active,
                  popover == nil, let anchor, anchor.window?.isVisible == true, let card else { return }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = anchor.effectiveAppearance
            popover.contentViewController = NSHostingController(rootView: card)
            self.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
            // Mouse-move events are not guaranteed in an NSPopover window.
            // Sample the actual pointer while a card is open so leaving it
            // still closes the card even when no row receives a hover exit.
            pointerState = SidebarHoverState()
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPointer() }
            }
            timer.tolerance = 0.02
            pointerTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .mouseMoved { self.checkPointer() }
                else if event.type == .keyDown {
                    if event.keyCode == 53 || event.window != self.popover?.contentViewController?.view.window { self.close() }
                } else if event.type == .scrollWheel || event.type == .rightMouseDown {
                    self.close()
                } else if event.window != self.popover?.contentViewController?.view.window {
                    self.close()
                }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                if event.type == .mouseMoved { self?.checkPointer() }
                else { self?.close() }
            }
        }

        private func checkPointer() {
            guard let popover else { return }
            guard popover.isShown, anchor?.window?.isVisible == true, NSApp.isActive,
                  !SidebarMenuTracking.shared.active else {
                close()
                return
            }
            if pointerState.shouldClose(pointerInside: containsPointer, at: ProcessInfo.processInfo.systemUptime) {
                close()
            }
        }

        func close() {
            pending?.cancel()
            pending = nil
            pointerTimer?.invalidate()
            pointerTimer = nil
            pointerState = SidebarHoverState()
            popover?.close()
            popover = nil
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil
            globalMonitor = nil
        }
    }
}

private final class SidebarHoverAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func sidebarHoverCard<Card: View>(hovering: Bool, enabled: Bool = true, suppressOpening: Bool = false,
                                      @ViewBuilder card: @escaping () -> Card) -> some View {
        background(SidebarHoverPresentation(hovering: hovering, enabled: enabled && !SidebarMenuTracking.shared.active,
                                           suppressOpening: suppressOpening, card: card))
    }
}
#endif
