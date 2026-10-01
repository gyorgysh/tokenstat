// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// One flags monitor for all rows. Ordinary typing does not invalidate them.
@MainActor @Observable
final class SidebarModifierKeys {
    static let shared = SidebarModifierKeys()
    private(set) var shift = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.shift = event.modifierFlags.contains(.shift)
            return event
        }
    }

    func refresh() { shift = NSEvent.modifierFlags.contains(.shift) }
}

/// Both controls occupy the same reserved seat, so hover never moves a title.
struct SidebarRowActions: View {
    let name: String
    let visible: Bool
    var canDelete = true
    let deleteTitle: String
    let delete: () -> Void
    let hover: (Bool) -> Void
    let actions: () -> [NativeMenuItem]
    @State private var controlHovered = false

    private var showsDelete: Bool { visible && canDelete && SidebarModifierKeys.shared.shift }

    var body: some View {
        Group {
            if showsDelete {
                Button(action: delete) { glyph(ActionIcon.delete.symbol) }
                    .buttonStyle(.plain)
                    .help(deleteTitle)
                    .accessibilityLabel(deleteTitle)
            } else {
                glyph("ellipsis")
                    .overlay(NativeMenuTrigger(items: actions, accessibilityLabel: L10n.text("apple.sidebarrowactions.actions_for_0.29a5141b", "\(name)")))
                    .help(L10n.text("apple.sidebarrowactions.actions_for_0_hold_shift_for_1.34c1216b", "\(name)", "\(deleteTitle.lowercased())"))
                    .accessibilityLabel(L10n.text("apple.sidebarrowactions.actions_for_0.29a5141b", "\(name)"))
            }
        }
        .frame(width: 24, height: 24)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .onHover { on in
            SidebarModifierKeys.shared.refresh()
            controlHovered = on
            hover(on)
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Theme.fit(11, weight: .semibold))
            .foregroundStyle(controlHovered ? Theme.accent : Color.secondary)
            .frame(width: 24, height: 24)
            .background(controlHovered ? Theme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(.rect)
    }
}

struct SidebarRenameSheet: View {
    let title: String
    let currentName: String
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ThemedSheet(title: title, subtitle: L10n.text("apple.sidebarrowactions.choose_the_name_shown_in_the_sidebar.e7682b18"), icon: .edit,
                    onClose: { if !saving { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField(L10n.text("apple.sidebarrowactions.name.dcd1d522"), text: $name).textFieldStyle(.themed)
                    .focused($focused).onSubmit { submit() }
                    .disabled(saving)
                if let error {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.diffRemoved)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }.disabled(saving)
            Button(L10n.text("common.save"), .save) { submit() }
                .buttonStyle(AccentButtonStyle())
                .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 460, height: error == nil ? 250 : 300)
        .interactiveDismissDisabled(saving)
        .onAppear {
            name = currentName
            focused = true
        }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving, !value.isEmpty else { return }
        saving = true
        Task {
            do {
                try await save(value)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

extension View {
    func sidebarContextMenu(items: @escaping () -> [NativeMenuItem]) -> some View {
        overlay(NativeMenuTrigger(items: items, rightClickOnly: true).accessibilityHidden(true))
    }
}

@MainActor
enum SidebarPinAction {
    static func items(reference: WorkReference?, name: String, folderName: String) -> [NativeMenuItem] {
        guard let reference else { return [] }
        let store = PinnedWorkStore.shared
        let pinned = store.isPinned(reference)
        let full = !pinned && store.pins(in: reference.scope).count >= PinnedWorkStore.capacity
        var items = [NativeMenuItem(pinned ? L10n.text("apple.sidebarrowactions.unpin_from_home.df00f5de") : L10n.text("apple.sidebarrowactions.pin_to_home.db029e6f"),
                                   icon: pinned ? .pinned : .pin, isEnabled: !full) {
            if pinned { store.unpin(reference) }
            else { store.pin(reference, label: name, folderName: folderName) }
        }]
        if full {
            items.append(.init(L10n.text("apple.sidebarrowactions.home_holds_eight_pins_unpin_one_to_make_ro.7d0eb1cf"), isEnabled: false) {})
        }
        return items
    }
}

/// Menus suspend hover cards until their native tracking loop finishes.
@MainActor @Observable
final class SidebarMenuTracking {
    static let shared = SidebarMenuTracking()
    private(set) var active = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = true }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = false }
            })
    }
}


#endif
