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
                    ForEach(order) { section in
                        row(section)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Drag to reorder. Uncheck what you never read.")
                } footer: {
                    Text(footerText)
                }

                Section {
                    Button("Reset Home", .refresh) {
                        order = HomePreset.balanced.order
                        hidden = []
                        preset = .balanced
                    }
                    .listRowBackground(Color.clear)
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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
                    hidden = []
                    preset = option
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
        let place = (order.firstIndex(of: section) ?? 0) + 1
        return Button {
            if on { hidden.insert(section) } else { hidden.remove(section) }
            preset = nil
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
        .accessibilityValue(on ? "On, position \(place) of \(order.count)" : "Off")
        // Dragging is not the only way to move a card. VoiceOver and a
        // keyboard both reach these.
        .accessibilityActions {
            Button("Move up") { shift(section, by: -1) }
            Button("Move down") { shift(section, by: 1) }
        }
    }

    private func move(from: IndexSet, to: Int) {
        order = HomeLayout.moved(order, from: from, to: to)
        preset = nil
    }

    private func shift(_ section: HomeSection, by delta: Int) {
        guard let index = order.firstIndex(of: section) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        preset = nil
    }
}

/// Home at a glance: one bar per visible card, in order.
///
/// Small enough to sit above the list and still say what the arrangement will
/// look like, which is the thing a list of names cannot show. Not a rendering
/// of the real cards: a miniature that pretended to be the screen would be
/// wrong the moment any of them had nothing to say.
struct HomeLayoutPreview: View {
    let sections: [HomeSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The greeting, which is not a card and cannot be moved. Drawn
            // so the bars below read as a screen rather than a stack.
            Capsule()
                .fill(Theme.accent.opacity(0.35))
                .frame(width: 84, height: 8)
                .padding(.bottom, 3)
                .accessibilityHidden(true)
            if sections.isEmpty {
                Text("Your Home is clear")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(sections) { section in
                    HStack(spacing: 6) {
                        Image(systemName: section.symbol)
                            .font(Theme.fixed(8, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 12)
                        Text(section.label)
                            .font(Theme.fixed(9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: section == .activity ? 30 : 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Theme.accentSoft,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                }
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: sections)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sections.isEmpty
            ? "Preview: Home is clear"
            : "Preview: \(sections.map(\.label).joined(separator: ", "))")
    }
}

#endif
