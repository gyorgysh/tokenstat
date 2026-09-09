// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

#if !os(macOS)

/// Arrange Home: pick a starting layout, move the cards, switch off the ones
/// this person never reads.
///
/// A working copy, so Done applies the whole arrangement at once and Cancel
/// really is a cancel. Home changing card by card behind an open sheet would
/// be a preview nobody asked for, which is why there is a small one here
/// instead.
struct ClientHomeEditor: View {
    @Bindable var layout: HomeLayout
    @Environment(\.dismiss) private var dismiss

    @State private var order: [HomeSection]
    @State private var hidden: Set<HomeSection>
    @State private var preset: HomePreset?
    @State private var beforeReset: (order: [HomeSection], hidden: Set<HomeSection>, preset: HomePreset?)?
    @State private var announcement = ""
    @AccessibilityFocusState private var focusedSection: HomeSection?

    init(layout: HomeLayout) {
        self.layout = layout
        _order = State(initialValue: layout.order)
        _hidden = State(initialValue: layout.hidden)
        _preset = State(initialValue: layout.preset)
    }

    private var visible: [HomeSection] { order.filter { !hidden.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    presetRow
                    HomeLayoutPreview(sections: visible)
                        .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.m,
                                                  bottom: Theme.Space.s, trailing: Theme.Space.m))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } footer: {
                    Text("A starting arrangement. It moves the cards and nothing else.")
                }

                Section {
                    ForEach(visible) { section in
                        row(section)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Visible · drag to reorder")
                } footer: {
                    Text(footerText)
                }

                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(order.filter { hidden.contains($0) }) { section in
                            row(section)
                        }
                    }
                }

                Section {
                    Button("Reset Home", .refresh) {
                        beforeReset = (order, hidden, preset)
                        order = HomePreset.balanced.order
                        hidden = HomePreset.balanced.hidden
                        preset = .balanced
                        announcement = "Balanced arrangement restored."
                    }
                    .listRowBackground(Color.clear)
                    if let previous = beforeReset {
                        Button("Undo reset", .restore) {
                            order = previous.order
                            hidden = previous.hidden
                            preset = previous.preset
                            beforeReset = nil
                            announcement = "Previous arrangement restored."
                        }
                        .listRowBackground(Color.clear)
                    }
                    if !announcement.isEmpty {
                        Text(announcement)
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            // The platform's grouped grey is not our dark. Rows paint
            // themselves; the list is only the scroll behind them.
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", .dismiss) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", .done) {
                        layout.apply(order: order, hidden: hidden, preset: preset)
                        dismiss()
                    }
                }
            }
        }
    }

    private var footerText: String {
        if visible.isEmpty {
            return "Home will be clear. Search and the tabs are still there, and you can "
                + "switch a card back on here at any time."
        }
        let off = order.filter { hidden.contains($0) }
        guard !off.isEmpty else { return "Every card is on." }
        return "Off: \(off.map(\.label).joined(separator: ", "))."
    }

    private var presetRow: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(HomePreset.allCases) { option in
                Button {
                    order = option.order
                    hidden = option.hidden
                    preset = option
                    beforeReset = nil
                    announcement = ""
                } label: {
                    Text(option.label)
                        .font(ClientType.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            preset == option ? Theme.accentSoft : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                preset == option ? Theme.accent : Theme.accent.opacity(0.35),
                                lineWidth: 1
                            )
                        )
                        .foregroundStyle(Theme.accent)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) arrangement")
                .accessibilityAddTraits(preset == option ? [.isSelected] : [])
            }
        }
        .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.m,
                                  bottom: 0, trailing: Theme.Space.m))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func row(_ section: HomeSection) -> some View {
        let on = !hidden.contains(section)
        let place = (visible.firstIndex(of: section) ?? 0) + 1
        return Button {
            if on { hidden.insert(section) } else { hidden.remove(section) }
            preset = nil
            beforeReset = nil
            announcement = "\(section.label) \(on ? "hidden" : "shown")."
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: section.symbol)
                    .font(Theme.font(15))
                    .foregroundStyle(on ? Theme.accent : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.label)
                        .font(ClientType.body)
                        .foregroundStyle(on ? .primary : .secondary)
                    Text(section.detail)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ThemeCheckDisc(on: on)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityLabel(section.label)
        .accessibilityValue(on ? "Visible, position \(place) of \(visible.count)" : "Hidden")
        .accessibilityFocused($focusedSection, equals: section)
        // Dragging is not the only way to move a card. VoiceOver and a
        // keyboard both reach these.
        .accessibilityActions {
            if on {
                Button("Move up") { shift(section, by: -1) }
                Button("Move down") { shift(section, by: 1) }
            }
        }
    }

    private func move(from: IndexSet, to: Int) {
        let movedSection = from.first.flatMap { visible.indices.contains($0) ? visible[$0] : nil }
        order = HomeLayout.movedVisible(order, hidden: hidden, from: from, to: to)
        preset = nil
        beforeReset = nil
        if let movedSection { announceMove(movedSection) }
    }

    private func shift(_ section: HomeSection, by delta: Int) {
        guard let index = visible.firstIndex(of: section) else { return }
        let target = index + delta
        guard visible.indices.contains(target) else { return }
        move(from: IndexSet(integer: index), to: target > index ? target + 1 : target)
        focusedSection = section
    }

    private func announceMove(_ section: HomeSection) {
        announcement = "\(section.label) moved to position \((visible.firstIndex(of: section) ?? 0) + 1)."
        AccessibilityNotification.Announcement(announcement).post()
    }
}

#endif
