// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI

struct SidebarDetailField: Identifiable {
    let title: String
    let value: String
    let symbol: String
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
                    Text(title).font(Theme.callout.weight(.semibold))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(Theme.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: field.symbol)
                            .font(Theme.fit(11)).foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(field.title).font(Theme.caption).foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Space.s)
                        Text(field.value).font(Theme.caption.weight(.medium))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(path).font(Theme.caption).foregroundStyle(.tertiary)
                .lineLimit(3).truncationMode(.middle)
                .textSelection(.enabled)
            footer
        }
        .padding(Theme.Space.m)
        .frame(width: DisplayFit.dp(310), alignment: .leading)
        .background(Theme.panel)
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
            title: conversation.title.isEmpty ? "Untitled conversation" : conversation.title,
            subtitle: "Chat · \(harnessName(conversation.backend))",
            symbol: "bubble.left.and.bubble.right",
            path: folder.path,
            fields: fields
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
            SidebarDetailField(title: "Project", value: folder.name, symbol: "folder"),
            SidebarDetailField(title: "Computer", value: folder.sidebarComputer, symbol: "laptopcomputer"),
            SidebarDetailField(title: "Status", value: conversation.running ? "Working" : "Ready", symbol: "circle.dotted"),
        ]
        if let model = conversation.model, !model.isEmpty {
            fields.append(.init(title: "Model", value: model, symbol: "sparkles"))
        }
        if let usage, !usage.isEmpty {
            let total = Decimal(usage.input) + Decimal(usage.output) + usage.cache
            fields.append(.init(title: "Tokens", value: total.formatted(), symbol: "number"))
            fields.append(.init(title: "Fresh input", value: usage.input.formatted(), symbol: "arrow.down"))
            fields.append(.init(title: "Tokens out", value: usage.output.formatted(), symbol: "arrow.up"))
            if usage.cache > 0 {
                fields.append(.init(title: "Cached tokens", value: usage.cache.formatted(), symbol: "arrow.clockwise"))
            }
        } else {
            fields.append(.init(title: "Tokens", value: !finishedLoading ? "Checking…" : loadFailed ? "Couldn’t load usage" : "Not reported yet", symbol: "number"))
        }
        fields.append(.init(title: "Last message", value: sidebarDate(conversation.lastMessageAtMs), symbol: "clock"))
        return fields
    }
}

extension WorkspaceFolder {
    var sidebarComputer: String { isRemote ? machineLabel ?? "Other computer" : "This computer" }
}

func sidebarDate(_ milliseconds: Int64?) -> String {
    guard let milliseconds else { return "No messages yet" }
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
        private var hovered = false
        private var enabled = false
        private var suppressOpening = false
        private var card: Card?

        func update(anchor: NSView, hovering: Bool, enabled: Bool, suppressOpening: Bool, card: Card) {
            self.anchor = anchor
            self.card = card
            let enabledChanged = self.enabled != enabled
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
            guard hovered != hovering || enabledChanged else { return }
            hovered = hovering
            pending?.cancel()
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                if hovering { self.show() }
                else if !self.containsPointer { self.close() }
            }
        }

        private var containsPointer: Bool {
            let point = NSEvent.mouseLocation
            let cardRect = popover?.contentViewController?.view.window?.frame
            if let anchor, let window = anchor.window {
                let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                if rect.insetBy(dx: -12, dy: -8).contains(point) { return true }
                if let cardRect {
                    // The popover arrow leaves a gap. Crossing it is still
                    // travelling toward this card, even after the row exits.
                    let left = min(rect.maxX, cardRect.minX)
                    let right = max(rect.maxX, cardRect.minX)
                    let bridge = NSRect(x: left, y: min(rect.minY, cardRect.minY),
                                        width: right - left,
                                        height: max(rect.maxY, cardRect.maxY) - min(rect.minY, cardRect.minY))
                    if bridge.insetBy(dx: -12, dy: -8).contains(point) { return true }
                }
            }
            return cardRect?.insetBy(dx: -12, dy: -8).contains(point) == true
        }

        private func show() {
            guard enabled, !suppressOpening, !SidebarMenuTracking.shared.active,
                  popover == nil, let anchor, anchor.window != nil, let card else { return }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = anchor.effectiveAppearance
            popover.contentViewController = NSHostingController(rootView: card)
            self.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .mouseMoved { self.pointerMoved() }
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
                if event.type == .mouseMoved { self?.pointerMoved() }
                else { self?.close() }
            }
        }

        private func pointerMoved() {
            pending?.cancel()
            guard !containsPointer else { return }
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard let self, !Task.isCancelled, !self.containsPointer else { return }
                self.close()
            }
        }

        func close() {
            pending?.cancel()
            pending = nil
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
