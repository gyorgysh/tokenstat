// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Arrange Workspaces once a host is connected: order and hide Folders,
/// Recent chats and All sessions. Same working-copy pattern as Customize Home.
struct ClientWorkspacesEditor: View {
    @Bindable var layout: WorkspacesLayout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var keyboardSection: WorkspacesSection?

    @State private var order: [WorkspacesSection]
    @State private var hidden: Set<WorkspacesSection>
    @State private var preset: WorkspacesPreset?
    @State private var allTasks: Bool
    @State private var beforeReset: (
        order: [WorkspacesSection],
        hidden: Set<WorkspacesSection>,
        preset: WorkspacesPreset?
    )?
    @State private var announcement = ""
    @AccessibilityFocusState private var focusedSection: WorkspacesSection?

    init(layout: WorkspacesLayout) {
        self.layout = layout
        _order = State(initialValue: layout.order)
        _hidden = State(initialValue: layout.hidden)
        _preset = State(initialValue: layout.preset)
        _allTasks = State(initialValue: layout.allTasksVisible)
    }

    private var visible: [WorkspacesSection] { order.filter { !hidden.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    presetRow
                    WorkspacesLayoutPreview(sections: visible)
                        .listRowInsets(EdgeInsets(
                            top: Theme.Space.s,
                            leading: Theme.Space.m,
                            bottom: Theme.Space.s,
                            trailing: Theme.Space.m
                        ))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } footer: {
                    Text(L10n.text("apple.clientworkspaceseditor.order_of_folders_recent_chats_and_all_sess.1e31aba6"))
                }

                Section {
                    ForEach(visible) { section in
                        row(section)
                    }
                    .onMove(perform: move)
                } header: {
                    Text(L10n.text("apple.clientworkspaceseditor.visible_drag_to_reorder.865ac64c"))
                } footer: {
                    Text(footerText)
                }

                if !hidden.isEmpty {
                    Section(L10n.text("apple.clientworkspaceseditor.hidden.7e6fefff")) {
                        ForEach(order.filter { hidden.contains($0) }) { section in
                            row(section)
                        }
                    }
                }

                Section {
                    Button {
                        allTasks.toggle()
                    } label: {
                        HStack(spacing: Theme.Space.m) {
                            Image("mark_todo")
                                .resizable().scaledToFit().frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("apple.clientworkspaceseditor.all_tasks.cb664823"))
                                    .font(ClientType.body)
                                    .foregroundStyle(allTasks ? .primary : .secondary)
                                Text(L10n.text("apple.clientworkspaceseditor.task_board_for_the_whole_computer_above_th.39129983"))
                                    .font(ClientType.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            ThemeCheckDisc(on: allTasks)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(L10n.text("apple.clientworkspaceseditor.all_tasks_link.51f07f03"))
                    .accessibilityValue(allTasks ? L10n.text("apple.clientworkspaceseditor.visible.8411f5ab") : L10n.text("apple.clientworkspaceseditor.hidden.7e6fefff"))
                } header: {
                    Text(L10n.text("apple.clientworkspaceseditor.task_board.8aec510a"))
                }

                Section {
                    Button(L10n.text("apple.clientworkspaceseditor.reset_projects.86decdfb"), .refresh) {
                        beforeReset = (order, hidden, preset)
                        order = WorkspacesPreset.foldersFirst.order
                        hidden = WorkspacesPreset.foldersFirst.hidden
                        preset = .foldersFirst
                        announcement = L10n.text("apple.clientworkspaceseditor.folders_first_restored.cad01148")
                    }
                    .listRowBackground(Color.clear)
                    if let previous = beforeReset {
                        Button(L10n.text("apple.clientworkspaceseditor.undo_reset.c4961cf5"), .restore) {
                            order = previous.order
                            hidden = previous.hidden
                            preset = previous.preset
                            beforeReset = nil
                            announcement = L10n.text("apple.clientworkspaceseditor.previous_order_restored.e51463f3")
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
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(L10n.text("apple.clientworkspaceseditor.customize_projects.00ab91c5"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.done"), .done) {
                        layout.apply(order: order, hidden: hidden, preset: preset)
                        layout.setAllTasksVisible(allTasks)
                        dismiss()
                    }
                }
            }
        }
    }

    private var footerText: String {
        if visible.isEmpty {
            return L10n.text("apple.clientworkspaceseditor.projects_will_only_show_computers_switch_a.638004ff")
        }
        let off = order.filter { hidden.contains($0) }
        guard !off.isEmpty else { return L10n.text("apple.clientworkspaceseditor.every_section_is_on.51c7661a") }
        return L10n.text("apple.clientworkspaceseditor.off_0.8d022e73", "\(off.map(\.label).joined(separator: ", "))")
    }

    private var presetRow: some View {
        let arrangement = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Space.s))
            : AnyLayout(HStackLayout(spacing: Theme.Space.s))
        return arrangement {
            ForEach(WorkspacesPreset.allCases) { option in
                Button {
                    order = option.order
                    hidden = option.hidden
                    preset = option
                    beforeReset = nil
                    announcement = ""
                } label: {
                    Text(option.label)
                        .font(ClientType.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
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
                .accessibilityLabel(L10n.text("apple.clientworkspaceseditor.0_preset.621d4288", "\(option.label)"))
                .accessibilityAddTraits(preset == option ? [.isSelected] : [])
            }
        }
        .listRowInsets(EdgeInsets(
            top: Theme.Space.s,
            leading: Theme.Space.m,
            bottom: 0,
            trailing: Theme.Space.m
        ))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func row(_ section: WorkspacesSection) -> some View {
        let on = !hidden.contains(section)
        let place = (visible.firstIndex(of: section) ?? 0) + 1
        return Button {
            if on { hidden.insert(section) } else { hidden.remove(section) }
            preset = nil
            beforeReset = nil
            announcement = "\(section.label) \(on ? L10n.text("apple.clientworkspaceseditor.hidden.e564b408") : L10n.text("apple.clientworkspaceseditor.shown.baaf5362"))."
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($keyboardSection, equals: section)
        .onKeyPress(.upArrow, phases: .down) { press in
            guard on, press.modifiers.contains(.command) else { return .ignored }
            shift(section, by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard on, press.modifiers.contains(.command) else { return .ignored }
            shift(section, by: 1)
            return .handled
        }
        .listRowBackground(Color.clear)
        .accessibilityLabel(section.label)
        .accessibilityValue(on ? L10n.text("apple.clientworkspaceseditor.visible_position_0_of_1.0c15d01d", "\(place)", "\(visible.count)") : L10n.text("apple.clientworkspaceseditor.hidden.7e6fefff"))
        .accessibilityFocused($focusedSection, equals: section)
        .accessibilityActions {
            if on {
                if visible.first != section {
                    Button(L10n.text("apple.clientworkspaceseditor.move_up.c66feb5e")) { shift(section, by: -1) }
                }
                if visible.last != section {
                    Button(L10n.text("apple.clientworkspaceseditor.move_down.40bb50da")) { shift(section, by: 1) }
                }
            }
        }
    }

    private func move(from: IndexSet, to: Int) {
        let movedSection = from.first.flatMap { visible.indices.contains($0) ? visible[$0] : nil }
        order = WorkspacesLayout.movedVisible(order, hidden: hidden, from: from, to: to)
        preset = nil
        beforeReset = nil
        if let movedSection { announceMove(movedSection) }
    }

    private func shift(_ section: WorkspacesSection, by delta: Int) {
        guard let index = visible.firstIndex(of: section) else { return }
        let target = index + delta
        guard visible.indices.contains(target) else { return }
        move(from: IndexSet(integer: index), to: target > index ? target + 1 : target)
        focusedSection = section
        keyboardSection = section
    }

    private func announceMove(_ section: WorkspacesSection) {
        announcement = L10n.text("apple.clientworkspaceseditor.0_moved_to_position_1.4fa1daea", "\(section.label)", "\((visible.firstIndex(of: section) ?? 0) + 1)")
        AccessibilityNotification.Announcement(announcement).post()
    }
}

/// Miniature stack for the editor preview.
private struct WorkspacesLayoutPreview: View {
    let sections: [WorkspacesSection]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(Theme.accent.opacity(0.35))
                .frame(width: 72, height: 8)
                .padding(.bottom, 3)
                .accessibilityHidden(true)
            if sections.isEmpty {
                Text(L10n.text("apple.clientworkspaceseditor.only_computers_will_show.dcb66766"))
                    .font(Theme.caption)
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
                    .frame(height: 20)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: sections)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sections.isEmpty
            ? L10n.text("apple.clientworkspaceseditor.preview_only_hosts.00b8c09f")
            : L10n.text("apple.clientworkspaceseditor.preview_0.7a199109", "\(sections.map(\.label).joined(separator: ", "))"))
    }
}

#endif
