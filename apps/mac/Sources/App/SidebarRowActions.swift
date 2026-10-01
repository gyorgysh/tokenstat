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
                    .overlay(NativeMenuTrigger(items: actions, accessibilityLabel: "Actions for \(name)"))
                    .help("Actions for \(name). Hold Shift for \(deleteTitle.lowercased()).")
                    .accessibilityLabel("Actions for \(name)")
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
        ThemedSheet(title: title, subtitle: "Choose the name shown in the sidebar.", icon: .edit,
                    onClose: { if !saving { dismiss() } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("Name", text: $name).textFieldStyle(.themed)
                    .focused($focused).onSubmit { submit() }
                    .disabled(saving)
                if let error {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.diffRemoved)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel", .dismiss) { dismiss() }.disabled(saving)
            Button("Save", .save) { submit() }
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
        var items = [NativeMenuItem(pinned ? "Unpin from Home" : "Pin to Home",
                                   icon: pinned ? .pinned : .pin, isEnabled: !full) {
            if pinned { store.unpin(reference) }
            else { store.pin(reference, label: name, folderName: folderName) }
        }]
        if full {
            items.append(.init("Home holds eight pins. Unpin one to make room.", isEnabled: false) {})
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
