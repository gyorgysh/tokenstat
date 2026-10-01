// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// A local working copy. Closing the sheet never changes Home.
struct DesktopHomeEditor: View {
    let layout: HomeLayout
    var emptyReason: (HomeSection) -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var order: [HomeSection]
    @State private var hidden: Set<HomeSection>
    @State private var preset: HomePreset?
    @State private var beforeReset: HomeArrangement?
    @State private var dragging: HomeSection?
    @State private var announcement = ""
    @FocusState private var focused: HomeSection?

    init(layout: HomeLayout, emptyReason: @escaping (HomeSection) -> String?) {
        self.layout = layout
        self.emptyReason = emptyReason
        _order = State(initialValue: layout.order)
        _hidden = State(initialValue: layout.hidden)
        _preset = State(initialValue: layout.preset)
    }

    private var visible: [HomeSection] { order.filter { !hidden.contains($0) } }

    var body: some View {
        ThemedSheet(title: L10n.text("apple.desktophomeeditor.customize_home.642cec6e"),
                    subtitle: L10n.text("apple.desktophomeeditor.keep_what_matters_close_this_arrangement_s.bc3b0457"),
                    icon: .layout, scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SegmentedCapsulePicker(
                    options: HomePreset.allCases.map {
                        (value: Optional($0), label: $0.label, symbol: ActionIcon.layout.symbol)
                    },
                    selection: Binding<HomePreset?>(get: { preset }, set: { option in
                        guard let option else { return }
                        order = option.order
                        hidden = option.hidden
                        preset = option
                        beforeReset = nil
                        announcement = ""
                    })
                )
                HomeLayoutPreview(sections: visible)
                Text(L10n.text("apple.desktophomeeditor.visible_drag_the_grip_or_use_the_arrows_to.a21c0f32"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if visible.isEmpty {
                    Text(L10n.text("apple.desktophomeeditor.your_home_is_clear_turn_a_section_back_on.3f39aedb"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { section in row(section, visible: true) }
                if !hidden.isEmpty {
                    Text(L10n.text("apple.desktophomeeditor.hidden.7e6fefff"))
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(order.filter { hidden.contains($0) }) { section in
                        row(section, visible: false)
                    }
                }
                if !announcement.isEmpty {
                    Text(announcement)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("home.editor.announcement")
                }
                HStack {
                    Button(L10n.text("apple.desktophomeeditor.reset_home.99f3f8ce"), .refresh) {
                        beforeReset = HomeArrangement(order: order, hidden: hidden, preset: preset)
                        order = HomePreset.balanced.order
                        hidden = HomePreset.balanced.hidden
                        preset = .balanced
                        announcement = L10n.text("apple.desktophomeeditor.balanced_arrangement_restored.f3e8a3f6")
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    if let previous = beforeReset {
                        Button(L10n.text("apple.desktophomeeditor.undo_reset.c4961cf5"), .restore) {
                            order = previous.order
                            hidden = previous.hidden
                            preset = previous.preset
                            beforeReset = nil
                            announcement = L10n.text("apple.desktophomeeditor.previous_arrangement_restored.cc0d9cd0")
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    }
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(L10n.text("common.done"), .done) {
                layout.apply(order: order, hidden: hidden, preset: preset)
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 600, height: 730)
    }

    private func row(_ section: HomeSection, visible on: Bool) -> some View {
        let position = (visible.firstIndex(of: section) ?? 0) + 1
        let accessibilityValue = on ? L10n.text("apple.desktophomeeditor.visible_position_0.f3227a71", "\(position)") : L10n.text("apple.desktophomeeditor.hidden.7e6fefff")
        return HStack(spacing: Theme.Space.s) {
            if on {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
                    .help(L10n.text("apple.desktophomeeditor.drag_to_reorder_0.6c1ef024", "\(section.label)"))
                    .onDrag {
                        dragging = section
                        let provider = NSItemProvider(object: section.rawValue as NSString)
                        provider.registerDataRepresentation(forTypeIdentifier: HomeSectionDrop.type.identifier,
                                                            visibility: .all) { completion in
                            completion(Data(section.rawValue.utf8), nil)
                            return nil
                        }
                        return provider
                    }
                    .accessibilityHidden(true)
            }
            Button {
                if on { hidden.insert(section) } else { hidden.remove(section) }
                preset = nil
                beforeReset = nil
                announcement = "\(section.label) \(on ? L10n.text("apple.desktophomeeditor.hidden.e564b408") : L10n.text("apple.desktophomeeditor.shown.baaf5362"))."
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: section.symbol)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.label).font(Theme.callout.weight(.medium))
                        Text(emptyReason(section) ?? section.detail)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    ThemeCheckDisc(on: on)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focusEffectDisabled()
            .focused($focused, equals: section)
            .accessibilityLabel(section.label)
            .accessibilityValue(accessibilityValue)
            .accessibilityActions {
                if on && visible.first != section {
                    Button(L10n.text("apple.desktophomeeditor.move_up.c66feb5e")) { shift(section, by: -1) }
                }
                if on && visible.last != section {
                    Button(L10n.text("apple.desktophomeeditor.move_down.40bb50da")) { shift(section, by: 1) }
                }
            }
            .onKeyPress(.upArrow, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                shift(section, by: -1)
                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                shift(section, by: 1)
                return .handled
            }
            if on {
                VStack(spacing: 2) {
                    Button { shift(section, by: -1) } label: {
                        Image(systemName: ActionIcon.collapse.symbol).frame(width: 28, height: 22)
                    }
                    .accessibilityLabel(L10n.text("apple.desktophomeeditor.move_0_up.fe065a57", "\(section.label)"))
                    .disabled(visible.first == section)
                    Button { shift(section, by: 1) } label: {
                        Image(systemName: ActionIcon.more.symbol).frame(width: 28, height: 22)
                    }
                    .accessibilityLabel(L10n.text("apple.desktophomeeditor.move_0_down.37babe0f", "\(section.label)"))
                    .disabled(visible.last == section)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help(L10n.text("apple.desktophomeeditor.move_0_keyboard_command_up_or_command_down.672847bc", "\(section.label)"))
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(focused == section || dragging == section ? Theme.accent : Theme.border, lineWidth: 1))
        .onDrop(of: [HomeSectionDrop.type], delegate: HomeSectionDrop(target: section, dragging: $dragging) { source, target in
            guard !hidden.contains(source), !hidden.contains(target),
                  let from = visible.firstIndex(of: source), let to = visible.firstIndex(of: target) else { return }
            order = HomeLayout.movedVisible(order, hidden: hidden,
                                            from: IndexSet(integer: from), to: to > from ? to + 1 : to)
            changed(source)
        })
        .accessibilityIdentifier("home.editor.\(section.rawValue)")
    }

    private func shift(_ section: HomeSection, by delta: Int) {
        guard let index = visible.firstIndex(of: section), visible.indices.contains(index + delta),
              let from = order.firstIndex(of: section),
              let to = order.firstIndex(of: visible[index + delta]) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            order.swapAt(from, to)
        }
        changed(section)
        focused = section
    }

    private func changed(_ section: HomeSection) {
        preset = nil
        beforeReset = nil
        announcement = L10n.text("apple.desktophomeeditor.0_moved_to_position_1.4fa1daea", "\(section.label)", "\((visible.firstIndex(of: section) ?? 0) + 1)")
        NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

private struct HomeArrangement {
    let order: [HomeSection]
    let hidden: Set<HomeSection>
    let preset: HomePreset?
}

private struct HomeSectionDrop: DropDelegate {
    static let type = UTType(exportedAs: "ai.tokenstat.home-section", conformingTo: .data)
    let target: HomeSection
    @Binding var dragging: HomeSection?
    let move: (HomeSection, HomeSection) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && info.itemProviders(for: [Self.type]).isEmpty == false
    }
    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), let dragging, dragging != target else { return }
        move(dragging, target)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        dragging = nil
        return true
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
#endif
