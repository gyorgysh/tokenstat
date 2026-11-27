// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI


struct PickerChoice<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var detail: String?
    var section: String
    var monospaced: Bool?

    init(value: Value, label: String, detail: String? = nil, section: String = "",
         monospaced: Bool? = nil) {
        self.value = value
        self.label = label
        self.detail = detail
        self.section = section
        self.monospaced = monospaced
    }

    var id: Value { value }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [label, detail ?? "", section].joined(separator: " ")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}

struct PickerPanel<Label: View, Content: View>: View {
    var title: String
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { isPresented = true } label: { label() }
            .buttonStyle(.plain)
            .pickerPanelSurface(title: title, isPresented: $isPresented, content: content)
    }
}

extension View {
    /// The panel surface on its own, for a picker whose button cannot own the
    /// presentation.
    ///
    /// A control that sits inside a `ViewThatFits` is one of those. The
    /// container swaps candidates whenever its content changes width, and a
    /// swap is a change of identity, which throws away the `@State` holding
    /// the panel open. Picking an agent renames the field, the field no longer
    /// fits on one line, and the sheet the person was still reading closes
    /// under them. Anchoring the presentation on a stable ancestor is what
    /// keeps it open.
    @ViewBuilder
    func pickerPanelSurface<Content: View>(
        title: String,
        isPresented: Binding<Bool>,
        anchorsToLeadingEdge: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        popover(isPresented: isPresented,
                attachmentAnchor: anchorsToLeadingEdge
                    ? .rect(.rect(CGRect(x: 0, y: 0, width: 320, height: 1)))
                    : .rect(.bounds),
                arrowEdge: .bottom) {
            content()
                .frame(width: 320, height: 460)
                .background(Theme.panel)
        }
        #else
        sheet(isPresented: isPresented) {
            NavigationStack {
                content()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if ClientKeyboardPresence.shared.isVisible {
                            ToolbarItem(placement: .topBarTrailing) {
                                ClientKeyboardDismissButton()
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.text("common.done")) { isPresented.wrappedValue = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .background(Theme.panel)
        }
        #endif
    }
}

struct PickerSearchField: View {
    var prompt: String
    @Binding var query: String
    var onSubmit: () -> Void = {}
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            focusable(TextField(prompt, text: $query))
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
                .accessibilityLabel(L10n.text("apple.searchablepicker.clear_filter.ba59e2d4"))
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: Theme.Control.heightComfortable)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
        .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private func focusable(_ field: TextField<Text>) -> some View {
        if let focus {
            field.focused(focus)
        } else {
            field
        }
    }
}

struct PickerOptionRow<Trailing: View>: View {
    var label: String
    var detail: String?
    var isSelected: Bool
    var monospaced: Bool = true
    var leading: AnyView?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.35))
            if let leading {
                leading.accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    #if os(macOS)
                    .font(
                        monospaced
                            ? Theme.mono(12, weight: isSelected ? .semibold : .regular)
                            : Theme.font(12, weight: isSelected ? .semibold : .regular)
                    )
                    #else
                    .font(monospaced ? Theme.monoText(16, relativeTo: .body) : Theme.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    #endif
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            trailing()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        #if os(macOS)
        .frame(minHeight: Theme.Control.heightComfortable)
        #else
        .frame(minHeight: 48)
        #endif
        .contentShape(.rect)
    }
}

extension PickerOptionRow where Trailing == EmptyView {
    init(label: String, detail: String? = nil, isSelected: Bool, monospaced: Bool = true) {
        self.init(
            label: label,
            detail: detail,
            isSelected: isSelected,
            monospaced: monospaced,
            trailing: { EmptyView() }
        )
    }
}

struct PickerRowButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isSelected
                    ? Theme.rowSelected
                    : (configuration.isPressed ? Theme.rowHighlight : Color.clear),
                in: RoundedRectangle(cornerRadius: Theme.Space.s)
            )
    }
}

struct PickerSectionHeading: View {
    var title: String
    var value: String?

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(title.uppercased())
                .font(Theme.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .tracking(0.7)
            Spacer(minLength: Theme.Space.xs)
            if let value, !value.isEmpty {
                Text(value)
                    .font(Theme.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, 2)
    }
}

struct PickerOptionList<Value: Hashable>: View {
    var choices: [PickerChoice<Value>]
    var isSelected: (Value) -> Bool
    var prompt: String
    var emptyMessage: String
    var monospaced: Bool = true
    var caption: String?
    var captionAccessory: AnyView? = nil
    var header: AnyView? = nil
    var refresh: (() async -> Void)?
    var sectionValue: ((String) -> String?)?
    var sectionTabs: [String] = []
    var stepped = false
    var stepPrompt: ((String) -> String)?
    var finish: (() -> Void)?
    var stepPick: ((Value) async -> [String]?)?
    var selectionSummary: String?
    var pick: (Value) -> Void
    var accessory: ((Value) -> AnyView)?
    var icon: ((Value) -> AnyView?)?
    var trailing: ((Value) -> AnyView?)?

    @State private var query = ""
    @State private var refreshing = false
    @State private var selectedSection = ""
    @State private var hoveredSection: String?
    @State private var movingForward = true
    @State private var choosing = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let captionAccessory {
                    HStack(spacing: Theme.Space.xs) {
                        if let caption, !caption.isEmpty {
                            Text(caption)
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s)
                        captionAccessory
                    }
                } else {
                    #if os(macOS)
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                }
                if let header { header }
                if let selectionSummary, !tabbed {
                    Text(selectionSummary)
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.text("apple.searchablepicker.current_selection_0.a744cd0f", "\(selectionSummary)"))
                }
                if tabbed {
                    sectionFilter
                }
                HStack(spacing: Theme.Space.s) {
                    if stepped, let previous = previousStep {
                        backButton(to: previous)
                    }
                    PickerSearchField(prompt: currentPrompt, query: $query, onSubmit: submit,
                                      focus: $searchFocused)
                    if refresh != nil {
                        refreshButton
                    }
                }
            }
            .padding(Theme.Space.s)
            .onChange(of: sectionTabs) { _, tabs in
                if !selectedSection.isEmpty, !tabs.contains(selectedSection) {
                    selectedSection = ""
                }
            }

            ThemeRule()

            listBody
                .id(activeSection)
                .transition(stepTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .onAppear { focusSearch() }
    }

    @ViewBuilder
    private var listBody: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: Theme.Space.xs) {
                    Text(query.isEmpty ? emptyMessage : L10n.text("apple.searchablepicker.nothing_matches.965b516d"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                    if !query.isEmpty {
                        Text(L10n.text("apple.searchablepicker.try_another_part_of_the_name.168c7783"))
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(sections.enumerated()), id: \.element.0) { index, group in
                            let (section, rows) = group
                            if !section.isEmpty, activeSection.isEmpty {
                                if index > 0 {
                                    ThemeRule().padding(.top, Theme.Space.xs)
                                }
                                PickerSectionHeading(
                                    title: section,
                                    value: sectionValue?(section)
                                )
                            }
                            ForEach(rows) { choice in
                                row(choice)
                            }
                        }
                    }
                    .padding(Theme.Space.s)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var stepTransition: AnyTransition {
        guard stepped else { return .identity }
        return .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var currentPrompt: String {
        guard stepped, !activeSection.isEmpty, let stepPrompt else { return prompt }
        return stepPrompt(activeSection)
    }

    private var previousStep: String? {
        guard let index = sectionTabs.firstIndex(of: activeSection), index > 0 else { return nil }
        return sectionTabs[index - 1]
    }

    private func backButton(to section: String) -> some View {
        Button { show(section) } label: {
            Image(systemName: ActionIcon.back.symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.Control.heightComfortable, height: Theme.Control.heightComfortable)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
                .contentShape(.rect)
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
        .keyboardShortcut("[", modifiers: .command)
        .help(L10n.text("common.back"))
        .accessibilityLabel(L10n.text("common.back"))
        .accessibilityValue(section)
    }

    private func show(_ section: String) {
        let from = sectionTabs.firstIndex(of: activeSection) ?? 0
        let to = sectionTabs.firstIndex(of: section) ?? 0
        movingForward = to >= from
        withAnimation(.snappy(duration: 0.22)) {
            selectedSection = section
            query = ""
        }
        focusSearch()
    }

    private func focusSearch() {
        #if os(macOS)
        guard stepped else { return }
        searchFocused = true
        #endif
    }

    private func choose(_ choice: PickerChoice<Value>) {
        guard !choosing else { return }
        guard stepped, let stepPick else {
            pick(choice.value)
            return
        }
        choosing = true
        Task { @MainActor in
            defer { choosing = false }
            guard let tabs = await stepPick(choice.value),
                  let index = tabs.firstIndex(of: choice.section) else { return }
            if index + 1 < tabs.count {
                show(tabs[index + 1])
            } else {
                finish?()
            }
        }
    }

    private func row(_ choice: PickerChoice<Value>) -> some View {
        let selected = isSelected(choice.value)
        return HStack(spacing: 0) {
            Button { choose(choice) } label: {
                PickerOptionRow(
                    label: choice.label,
                    detail: choice.detail,
                    isSelected: selected,
                    monospaced: choice.monospaced ?? monospaced,
                    leading: icon?(choice.value),
                    trailing: { if let view = trailing?(choice.value) { view } }
                )
            }
            .buttonStyle(PickerRowButtonStyle(isSelected: selected))
            .disabled(choosing)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let accessory { accessory(choice.value) }
        }
    }

    private var refreshButton: some View {
        Button(L10n.text("common.refresh"), .refresh) {
            guard let refresh, !refreshing else { return }
            Task {
                refreshing = true
                defer { refreshing = false }
                await refresh()
            }
        }
        .buttonStyle(QuietLinkStyle())
        .foregroundStyle(Theme.accent)
        .environment(\.compactActions, true)
        .frame(minWidth: Theme.Control.heightComfortable, minHeight: Theme.Control.heightComfortable)
        .contentShape(.rect)
        .disabled(refreshing)
        .opacity(refreshing ? 0.4 : 1)
        .help(L10n.text("apple.searchablepicker.ask_this_computer_to_read_the_agent_s_mode.a3d03fd8"))
    }

    private var sectionFilter: some View {
        HStack(spacing: stepped ? 0 : 3) {
            ForEach(Array(sectionTabs.enumerated()), id: \.element) { index, section in
                if stepped, index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(Theme.font(11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                }
                sectionTab(section)
            }
        }
        .padding(3)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.searchablepicker.filter_settings.4e47a723"))
    }

    private func sectionTab(_ section: String) -> some View {
        let selected = activeSection == section
        let value = sectionValue?(section) ?? ""
        let step = (sectionTabs.firstIndex(of: section) ?? 0) + 1
        let answered = stepped && step - 1 < (sectionTabs.firstIndex(of: activeSection) ?? 0)
        return Button {
            if stepped { show(section) } else {
                selectedSection = section
                query = ""
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if stepped {
                        stepBadge(step, answered: answered, current: selected)
                    }
                    Text(section.uppercased())
                        .font(Theme.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                        .lineLimit(1)
                }
                Text(value)
                    .font(Theme.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .frame(minHeight: Theme.Control.heightComfortable)
            .background(
                selected ? Theme.accentSoft
                    : (hoveredSection == section ? Theme.rowHighlight : .clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredSection = section } else if hoveredSection == section { hoveredSection = nil }
        }
        .accessibilityLabel(section)
        .accessibilityValue(value)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepBadge(_ step: Int, answered: Bool, current: Bool) -> some View {
        ZStack {
            Circle()
                .fill(current || answered ? Theme.accent : Color.secondary.opacity(0.18))
            if answered {
                Image(systemName: "checkmark")
                    .font(Theme.fixed(7, weight: .bold))
            } else {
                Text("\(step)")
                    .font(Theme.fixed(8, weight: .bold))
            }
        }
        .foregroundStyle(current || answered ? Color.white : Color.secondary)
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    private var tabbed: Bool { sectionTabs.count > 1 }

    private var activeSection: String {
        guard tabbed, stepped || query.isEmpty else { return "" }
        return sectionTabs.contains(selectedSection) ? selectedSection : sectionTabs[0]
    }

    private var filtered: [PickerChoice<Value>] {
        choices.filter {
            $0.matches(query) && (activeSection.isEmpty || $0.section == activeSection)
        }
    }

    private var sections: [(String, [PickerChoice<Value>])] {
        var order: [String] = []
        var grouped: [String: [PickerChoice<Value>]] = [:]
        for choice in filtered {
            if grouped[choice.section] == nil {
                order.append(choice.section)
                grouped[choice.section] = []
            }
            grouped[choice.section]?.append(choice)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func submit() {
        guard !filtered.isEmpty else { return }
        if stepped, query.trimmingCharacters(in: .whitespaces).isEmpty {
            if let current = filtered.first(where: { isSelected($0.value) }) ?? filtered.first {
                choose(current)
            }
            return
        }
        if let exact = filtered.first(where: { $0.matches(query) && $0.label.lowercased() == query.lowercased().trimmingCharacters(in: .whitespaces) }) {
            choose(exact)
            return
        }
        if !activeSection.isEmpty, let first = filtered.first {
            choose(first)
            return
        }
        let sectionsInOrder = sections
        if sectionsInOrder.count > 1,
           let nonAgent = sectionsInOrder.first(where: { !$0.0.lowercased().contains("agent") }),
           let first = nonAgent.1.first {
            choose(first)
            return
        }
        guard let first = filtered.first else { return }
        choose(first)
    }
}
