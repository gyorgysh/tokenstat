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

    init(value: Value, label: String, detail: String? = nil, section: String = "") {
        self.value = value
        self.label = label
        self.detail = detail
        self.section = section
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
            #if os(macOS)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                content()
                    .frame(width: 320, height: 420)
                    .background(Theme.panel)
            }
            #else
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    content()
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { isPresented = false }
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

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField(prompt, text: $query)
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
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 34)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
        .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
    }
}

/// One selectable row: the mark, the label, and whatever the caller hangs off
/// the end of it.
struct PickerOptionRow<Trailing: View>: View {
    var label: String
    var detail: String?
    var isSelected: Bool
    var monospaced: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(Theme.font(11, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.35))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(
                        monospaced
                            ? Theme.mono(12, weight: isSelected ? .semibold : .regular)
                            : Theme.font(12, weight: isSelected ? .semibold : .regular)
                    )
                    .lineLimit(1)
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
    /// Optional quick filters for a picker with several independent settings.
    /// The agent/model/effort picker uses these to make its three editable
    /// dimensions obvious before somebody starts scrolling its long list.
    var sectionTabs: [String] = []
    var pick: (Value) -> Void
    /// Trailing accessory per row, for the model picker's favourite star.
    var accessory: ((Value) -> AnyView)?

    @State private var query = ""
    @State private var refreshing = false
    /// Empty means every section. It avoids inventing a fourth, fake section
    /// solely to represent the All tab.
    @State private var selectedSection = ""

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
                HStack(spacing: Theme.Space.s) {
                    PickerSearchField(prompt: prompt, query: $query, onSubmit: submit)
                    if refresh != nil {
                        refreshButton
                    }
                }
                if !sectionTabs.isEmpty {
                    sectionFilter
                }
            }
            .padding(Theme.Space.s)
            .onChange(of: sectionTabs) { _, tabs in
                // The selected filter persists across choice changes. A hidden
                // filter that no longer exists would show "Nothing matches"
                // with no affordance, e.g. Effort selected then switching to
                // an agent without Effort.
                if !selectedSection.isEmpty, !tabs.contains(selectedSection) {
                    selectedSection = ""
                }
            }

            ThemeRule()

            if filtered.isEmpty {
                VStack(spacing: Theme.Space.xs) {
                    Text(query.isEmpty ? emptyMessage : "Nothing matches")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                    if !query.isEmpty {
                        Text("Try another part of the name.")
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
                            if !section.isEmpty {
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
            }
        }
    }

    private func row(_ choice: PickerChoice<Value>) -> some View {
        let selected = isSelected(choice.value)
        return Button { pick(choice.value) } label: {
            PickerOptionRow(
                label: choice.label,
                detail: choice.detail,
                isSelected: selected,
                monospaced: monospaced
            ) {
                if let accessory { accessory(choice.value) }
            }
        }
        .buttonStyle(PickerRowButtonStyle(isSelected: selected))
    }

    private var refreshButton: some View {
        Button("Refresh", .refresh) {
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
        .disabled(refreshing)
        .opacity(refreshing ? 0.4 : 1)
        .help("Ask this computer to read the agent's model list again")
    }

    /// The group names stay visible while the list changes underneath them.
    /// A search field alone told people they could search, not that Agent,
    /// Model and Effort were separate things they could change.
    private var sectionFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sectionTab(title: "All", section: "")
                ForEach(sectionTabs, id: \.self) { section in
                    sectionTab(title: section, section: section)
                }
            }
        }
        .accessibilityLabel("Filter settings")
    }

    private func sectionTab(title: String, section: String) -> some View {
        let selected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            Text(title)
                .font(Theme.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    selected ? Theme.accentSoft : Theme.background,
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        selected ? Theme.accent.opacity(0.35) : Theme.border,
                        lineWidth: 1
                    )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filtered: [PickerChoice<Value>] {
        choices.filter {
            $0.matches(query) && (selectedSection.isEmpty || $0.section == selectedSection)
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
        if let exact = filtered.first(where: { $0.matches(query) && $0.label.lowercased() == query.lowercased().trimmingCharacters(in: .whitespaces) }) {
            pick(exact.value)
            return
        }
        if !selectedSection.isEmpty, let first = filtered.first {
            pick(first.value)
            return
        }
        // No section filter: prefer a non-Agent section for Enter, since the
        // combined panel's Agent rows otherwise shadow model ids like "codex".
        let sectionsInOrder = sections
        if sectionsInOrder.count > 1,
           let nonAgent = sectionsInOrder.first(where: { !$0.0.lowercased().contains("agent") }),
           let first = nonAgent.1.first {
            pick(first.value)
            return
        }
        guard let first = filtered.first else { return }
        pick(first.value)
    }
}
