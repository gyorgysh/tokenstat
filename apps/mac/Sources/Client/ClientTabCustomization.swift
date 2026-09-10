// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Which tabs this device shows, and in what order.
///
/// Device furniture, like the layout preference: a phone with a keyboard case
/// lives in the sidebar, a phone in hand lives in the tab bar, and neither
/// arrangement follows the account. The bar stays the familiar four unless
/// somebody turns SSH on; hiding is refused while one tab is left standing,
/// so the selection can never point at nothing.
@MainActor @Observable
final class ClientTabCustomization {
    static let shared = ClientTabCustomization()

    private static let orderKey = "client.tabOrder.v1"
    private static let hiddenKey = "client.tabHidden.v1"

    /// Every known tab, in display order. Tabs added by later builds join at
    /// the end rather than jumping the order somebody already arranged.
    var order: [ClientTab]
    /// Tabs switched off in the editor. Never every tab: see `setVisible`.
    var hidden: Set<ClientTab>

    /// What the tab bar, the sidebar and the shortcuts all draw. Never empty.
    var visibleTabs: [ClientTab] {
        let shown = order.filter { !hidden.contains($0) }
        return shown.isEmpty ? [.home] : shown
    }

    /// A direct action may open a destination whose shortcut is hidden.
    /// Keep that destination in the bar while selected, without changing
    /// this device's preferences or introducing another modal navigation flow.
    func tabs(including selected: ClientTab) -> [ClientTab] {
        ClientTabVisibility.displayed(order: order, visible: visibleTabs, selected: selected)
    }

    init(defaults: UserDefaults = .standard) {
        let storedOrder = defaults.object(forKey: Self.orderKey) == nil
            ? nil
            : defaults.stringArray(forKey: Self.orderKey)?
                .compactMap(ClientTab.init(rawValue:))
                .filter { ClientTab.allCases.contains($0) }
        let known = storedOrder ?? []
        let resolvedOrder = known + ClientTab.allCases.filter { !known.contains($0) }
        let resolvedHidden: Set<ClientTab>
        if storedOrder == nil {
            // New device, or one from before tabs could be arranged: the
            // familiar four, with SSH waiting as an opt-in.
            resolvedHidden = [.ssh]
        } else {
            resolvedHidden = Set(
                (defaults.stringArray(forKey: Self.hiddenKey) ?? [])
                    .compactMap(ClientTab.init(rawValue:))
            ).intersection(resolvedOrder)
        }
        self.order = resolvedOrder
        self.hidden = resolvedHidden
        self.defaults = defaults
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Show or hide one tab. Hiding the last visible tab is refused, because
    /// the selection would point at nothing and the bar would go blank.
    ///
    /// Returns whether the change stuck, so the editor can say why not.
    @discardableResult
    func setVisible(_ visible: Bool, tab: ClientTab) -> Bool {
        if !visible, !hidden.contains(tab),
           order.filter({ !hidden.contains($0) }).count <= 1 {
            return false
        }
        if visible {
            hidden.remove(tab)
        } else {
            hidden.insert(tab)
        }
        save()
        return true
    }

    func move(from: IndexSet, to: Int) {
        order.move(fromOffsets: from, toOffset: to)
        save()
    }

    func reset() {
        order = ClientTab.allCases
        hidden = [.ssh]
        save()
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hidden.map(\.rawValue), forKey: Self.hiddenKey)
    }
}

/// Arrange this device's tabs: order them, switch the unused off, turn SSH on.
///
/// A sheet from the This device pane, where the other device-local choices
/// live. Reordering is drag handles, always on: an Edit button would be a
/// second step before the only thing this screen is for.
struct ClientTabEditor: View {
    @Bindable var customization: ClientTabCustomization
    @Environment(\.dismiss) private var dismiss
    @State private var refusedTab: ClientTab?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(customization.order) { tab in
                        row(tab)
                    }
                    .onMove { customization.move(from: $0, to: $1) }
                } header: {
                    Text("Drag to reorder. Uncheck what you never open.")
                } footer: {
                    if customization.hidden.isEmpty {
                        Text("Every tab is on.")
                    } else {
                        Text("Off: \(offSummary). A hidden tab appears temporarily when you open it from another screen. At least one tab always stays on.")
                    }
                }
                Section {
                    Button("Reset tabs", .refresh) {
                        customization.reset()
                        refusedTab = nil
                    }
                    .tint(Theme.accent)
                    .listRowBackground(Color.clear)
                }
            }
            .environment(\.editMode, .constant(.active))
            // The platform's grouped grey is not our dark. Rows paint
            // themselves; the list is only the scroll behind them.
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "One tab stays on",
                isPresented: Binding(
                    get: { refusedTab != nil },
                    set: { if !$0 { refusedTab = nil } }
                )
            ) {
                Button("OK", role: .cancel) { refusedTab = nil }
            } message: {
                Text("Hiding \(refusedTab?.label ?? "that tab") too would leave the bar empty.")
            }
        }
    }

    private var offSummary: String {
        customization.order
            .filter { customization.hidden.contains($0) }
            .map(\.label)
            .joined(separator: ", ")
    }

    private func row(_ tab: ClientTab) -> some View {
        let on = !customization.hidden.contains(tab)
        let lastStanding = on && customization.visibleTabs.count <= 1
        return Button {
            if customization.setVisible(!on, tab: tab) {
                refusedTab = nil
            } else {
                refusedTab = tab
            }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: tab.symbol)
                    .font(Theme.font(15))
                    .foregroundStyle(on ? Theme.accent : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.label)
                        .font(ClientType.body)
                        .foregroundStyle(on ? .primary : .secondary)
                    Text(tab.editorDetail)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ThemeCheckDisc(on: on)
                    .opacity(lastStanding ? 0.35 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .disabled(lastStanding)
        .accessibilityLabel("\(tab.label) tab")
        .accessibilityValue(on ? "On" : "Off")
    }
}

#endif

/// Pure selection policy shared by the tab renderer and its regression suite.
enum ClientTabVisibility {
    static func displayed<T: Hashable>(order: [T], visible: [T], selected: T) -> [T] {
        guard !visible.contains(selected) else { return visible }
        return order.filter { visible.contains($0) || $0 == selected }
    }
}
