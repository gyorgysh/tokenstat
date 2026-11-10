// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A picker that opens a panel you can type into, for lists a menu cannot
/// carry.
///
/// A menu is the right control for four efforts. It is the wrong one for the
/// forty-odd model ids an agent CLI now lists, where the only way to reach
/// `meta/muse-spark-1.3` is to read every line above it, and where a list that
/// changed a minute ago has nowhere to say so. The panel adds the two things
/// the menu has no room for: a filter, and a way to ask the host to look
/// again.
///
/// The shell is the branch picker's, because that pattern is already the one
/// people here have learned: a popover on the Mac, a sheet with detents on the
/// phone, one label closure supplying whatever opens it.

/// One option in a searchable picker.
///
/// `detail` is a second line, and `section` a heading. Both are optional and
/// the plain case, one flat list of labels, needs neither.
struct PickerChoice<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var detail: String?
    var section: String
    /// Overrides the list's typeface for this row. A product name such as an
    /// agent reads as a name, not as an identifier, beside model ids that do.
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

    /// Every word of the query has to appear somewhere in the row.
    ///
    /// Word by word rather than as one substring, so "meta 1.3" finds
    /// `meta/muse-spark-1.3` without anybody having to remember where the
    /// slashes and dashes fall in an id they did not choose.
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [label, detail ?? "", section].joined(separator: " ")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}

/// The panel shell: a popover on the Mac, a sheet on the phone.
///
/// Generic over both the control that opens it and what it shows, so a picker
/// with sections of its own (agent, model and effort together) uses the same
/// surface as a single flat list.
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
        // The composer summary grows as model and effort are selected. A
        // fixed anchor the width of this panel keeps its leading edge still.
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

/// The filter field. Shared so every panel's search looks like the branch
/// picker's rather than like whatever each screen invented.
struct PickerSearchField: View {
    var prompt: String
    @Binding var query: String
    var onSubmit: () -> Void = {}
    /// Lets a stepped panel put the caret back in the field when it moves to
    /// the next step, so the next thing typed searches that step.
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
                .buttonStyle(.plain)
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

/// One selectable row: the mark, an optional icon, the label, and whatever
/// the caller hangs off the end of it.
///
/// At least 44 points tall on every platform. A Mac can have a touch screen,
/// and a finger needs the same target there that it needs on the phone.
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
                        .lineLimit(1)
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

/// Row background. Selection and press, nothing else: the row is the label.
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

/// A section heading inside a panel, with what that section is currently set
/// to on the right of it.
///
/// The value is the part that earns its keep. A panel holding agent, model and
/// effort reads as one long list of names unless each group says what it is and
/// what it is set to, and the person who opened it came to change one of the
/// three.
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

/// Search field, filtered rows, and an optional way to reload the list.
///
/// The reload is not decoration. A model list is the agent CLI's answer as of
/// the last time the host asked it, cached for ten minutes so the picker does
/// not shell out to four CLIs on every keystroke. Add an API key to one of
/// them and the new provider is real everywhere except here, with nothing on
/// screen admitting it and no way to hurry it along. That is what this button
/// is for, and it is why it says when the list was read.
struct PickerOptionList<Value: Hashable>: View {
    var choices: [PickerChoice<Value>]
    /// Which rows carry the mark. A closure rather than one value because a
    /// panel can hold more than one choice at a time: agent, model and effort
    /// are three selections in one list.
    var isSelected: (Value) -> Bool
    var prompt: String
    var emptyMessage: String
    var monospaced: Bool = true
    /// A line above the search field naming what the panel is for. The phone
    /// gets this from the sheet's navigation title instead.
    var caption: String?
    var refresh: (() async -> Void)?
    /// What a section is currently set to, shown beside its heading.
    var sectionValue: ((String) -> String?)?
    /// Tabs for a picker that holds several independent settings, one per
    /// section, each showing what it is set to. The agent/model/effort picker
    /// uses these so the model and effort lists are visible before anybody
    /// scrolls past the agents. Two or more turn them on.
    var sectionTabs: [String] = []
    /// Walk the tabs in order: picking a row moves on to the next tab, and
    /// picking in the last one calls `finish`. Search covers only the current
    /// step, because a step is one question. The tabs stay clickable, so any
    /// earlier answer is one click away.
    var stepped = false
    /// The search prompt for one step, "Search models" rather than a prompt
    /// that names all three.
    var stepPrompt: ((String) -> String)?
    var finish: (() -> Void)?
    var stepPick: ((Value) async -> [String]?)?
    var selectionSummary: String?
    var pick: (Value) -> Void
    /// Trailing accessory per row, for the model picker's favourite star.
    var accessory: ((Value) -> AnyView)?
    /// Leading icon per row, for an agent's brand mark. Nil for a row with
    /// none, so model and effort rows keep their alignment.
    var icon: ((Value) -> AnyView?)?

    @State private var query = ""
    @State private var refreshing = false
    /// The tab somebody chose. Empty means the first one.
    @State private var selectedSection = ""
    @State private var hoveredSection: String?
    /// Which way the list slides on a step change: forward from the trailing
    /// edge, back from the leading one.
    @State private var movingForward = true
    @State private var choosing = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                #if os(macOS)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                #endif
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
                // The chosen tab persists across choice changes. One that no
                // longer exists, Effort after switching to an agent without
                // it, falls back to the first tab.
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

    /// One step back, beside the search field where the eye already is.
    /// Command-[ does the same on a keyboard, as it does in every Mac app
    /// with a back button.
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
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help(L10n.text("common.back"))
        .accessibilityLabel(L10n.text("common.back"))
        .accessibilityValue(section)
    }

    /// Moves to a tab, sliding the list the way the steps run.
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

    /// The caret follows the step on a Mac. On the phone it would raise the
    /// keyboard over a list of four efforts, so there the field waits for a tap.
    private func focusSearch() {
        #if os(macOS)
        guard stepped else { return }
        searchFocused = true
        #endif
    }

    /// Picking answers the current step and asks the next one. Picking the
    /// row that is already marked counts too: it is how somebody says "that
    /// one is fine" and moves on.
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
                    trailing: { EmptyView() }
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
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .environment(\.compactActions, true)
        .frame(minWidth: Theme.Control.heightComfortable, minHeight: Theme.Control.heightComfortable)
        .contentShape(.rect)
        .disabled(refreshing)
        .opacity(refreshing ? 0.4 : 1)
        .help(L10n.text("apple.searchablepicker.ask_this_computer_to_read_the_agent_s_mode.a3d03fd8"))
    }

    /// One tab per setting, each with its current value under its name.
    ///
    /// This was a row of small "All / Agent / Model / Effort" pills, and people
    /// did not see them: they read as decoration, so the agent list looked like
    /// the whole panel and the models below it went unfound. A tab that says
    /// "Model, opus" is both the summary and the way in, so the three settings
    /// are visible at a glance. Typing searches every tab at once, and no tab
    /// is marked while it does, because the list is no longer one of them.
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

    /// The step's number, or a check once it has been answered on the way
    /// through, so the strip reads as progress rather than as three filters.
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

    /// The section the list shows, or empty for all of them: when there are no
    /// tabs, and while a search is running across every tab.
    private var activeSection: String {
        guard tabbed, stepped || query.isEmpty else { return "" }
        return sectionTabs.contains(selectedSection) ? selectedSection : sectionTabs[0]
    }

    private var filtered: [PickerChoice<Value>] {
        choices.filter {
            $0.matches(query) && (activeSection.isEmpty || $0.section == activeSection)
        }
    }

    /// Sections in first-seen order. A dictionary would sort them by name and
    /// put Effort above Agent.
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

    /// Return in the filter field takes the first match, which is what a
    /// person typing three letters of a model id is asking for. Prefer a
    /// match in the currently filtered section, then an exact label match,
    /// so typing a model id that substring-matches an Agent row does not
    /// select the Agent.
    private func submit() {
        guard !filtered.isEmpty else { return }
        // Return on an empty field keeps the marked row and moves on, so a
        // keyboard can walk all three steps without changing anything.
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
        // No section filter: prefer a non-Agent section for Enter, since the
        // combined panel's Agent rows otherwise shadow model ids like "codex".
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
