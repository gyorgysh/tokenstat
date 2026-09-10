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
        ThemedSheet(title: "Customize Home",
                    subtitle: "Keep what matters close. This arrangement stays on this Mac.",
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
                Text("Visible · drag the grip or use the arrows to reorder")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if visible.isEmpty {
                    Text("Your Home is clear. Turn a section back on below whenever you need it.")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { section in row(section, visible: true) }
                if !hidden.isEmpty {
                    Text("Hidden")
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
                    Button("Reset Home", .refresh) {
                        beforeReset = HomeArrangement(order: order, hidden: hidden, preset: preset)
                        order = HomePreset.balanced.order
                        hidden = HomePreset.balanced.hidden
                        preset = .balanced
                        announcement = "Balanced arrangement restored."
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    if let previous = beforeReset {
                        Button("Undo reset", .restore) {
                            order = previous.order
                            hidden = previous.hidden
                            preset = previous.preset
                            beforeReset = nil
                            announcement = "Previous arrangement restored."
                        }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                    }
                }
            }
        } actions: {
            Button("Cancel", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Done", .done) {
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
        let accessibilityValue = on ? "Visible, position \(position)" : "Hidden"
        return HStack(spacing: Theme.Space.s) {
            if on {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
                    .help("Drag to reorder \(section.label)")
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
                announcement = "\(section.label) \(on ? "hidden" : "shown")."
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
                    Button("Move up") { shift(section, by: -1) }
                }
                if on && visible.last != section {
                    Button("Move down") { shift(section, by: 1) }
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
                    .accessibilityLabel("Move \(section.label) up")
                    .disabled(visible.first == section)
                    Button { shift(section, by: 1) } label: {
                        Image(systemName: ActionIcon.more.symbol).frame(width: 28, height: 22)
                    }
                    .accessibilityLabel("Move \(section.label) down")
                    .disabled(visible.last == section)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Move \(section.label). Keyboard: Command–Up or Command–Down on the row.")
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
        announcement = "\(section.label) moved to position \((visible.firstIndex(of: section) ?? 0) + 1)."
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
