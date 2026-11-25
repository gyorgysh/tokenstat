// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI

/// One repository, as plain values. Equatable so a card whose repository did
/// not change is not drawn again when another one's agent speaks.
struct RepositoryCardData: Equatable, Identifiable {
    struct Chat: Equatable, Identifiable {
        var id: String
        var title: String
        var backend: String
        var at: Int64
        var running: Bool
        var waiting: Bool
        var pulls: [ChatPull]
    }

    var id: String
    var name: String
    var path: String
    var machine: String
    var isRemote: Bool
    var symbol: String
    var branch: String?
    var ahead: UInt32
    var behind: UInt32
    var teams: [String]
    var facts: RepositoryFacts
    var step: RepositoryNextStep
    var workingAgent: String?
    var dayKeys: [String]
    var days: [UInt64]
    var marks: [String: [PullSummary]]
    var chats: [Chat]
    var added: UInt64
    var removed: UInt64
    var changedFiles: Int
    /// Nil when GitHub did not answer, which is not the same as none.
    var openPulls: Int?
    var chatCount: Int
    var taskCount: Int
    var terminalCount: Int
    var isQuiet: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && a.path == b.path && a.machine == b.machine
            && a.branch == b.branch && a.ahead == b.ahead && a.behind == b.behind && a.teams == b.teams
            && a.facts == b.facts && a.workingAgent == b.workingAgent
            && a.dayKeys == b.dayKeys && a.days == b.days && a.marks == b.marks && a.chats == b.chats
            && a.added == b.added && a.removed == b.removed && a.openPulls == b.openPulls
            && a.chatCount == b.chatCount && a.taskCount == b.taskCount && a.terminalCount == b.terminalCount
    }
}

/// Where each part of a card leads. One set for the page, so no card holds
/// its own copy of the shell's navigation.
struct RepositoryActions {
    var open: (String) -> Void
    var section: (WorkspaceSection, String) -> Void
    var newChat: (String) -> Void
    var chat: (String, String) -> Void
    var pull: (UInt32, String) -> Void
    var file: (String, String) -> Void
    var peek: (String) -> Void
}

// MARK: - Next step

struct RepositoryStepPresentation {
    var text: String
    var symbol: String
    var tint: Color
    var action: (label: String, icon: ActionIcon)?

    init(_ step: RepositoryNextStep, data: RepositoryCardData) {
        let chat: (String) -> RepositoryCardData.Chat? = { id in data.chats.first { $0.id == id } }
        switch step {
        case .missing:
            text = L10n.text("apple.repositories.step_missing")
            symbol = "folder.badge.questionmark"
            tint = Theme.warning
        case let .waiting(id):
            let agent = chat(id).map { harnessName(harnessCanonicalID($0.backend)) }
            text = agent.map { L10n.text("apple.repositories.step_waiting", $0) }
                ?? L10n.text("apple.repositories.step_waiting_any")
            symbol = "hand.raised"
            tint = Theme.warning
            action = (L10n.text("apple.repositories.action_answer"), .comment)
        case let .checksFailed(pull):
            text = L10n.text("apple.repositories.step_checks_failed", "\(pull)")
            symbol = "xmark.circle"
            tint = Theme.danger
            action = (L10n.text("apple.repositories.action_open"), .external)
        case let .changesRequested(pull):
            text = L10n.text("apple.repositories.step_changes_requested", "\(pull)")
            symbol = "exclamationmark.bubble"
            tint = Theme.danger
            action = (L10n.text("apple.repositories.action_open"), .external)
        case let .reviewRequested(pull):
            text = L10n.text("apple.repositories.step_review_requested", "\(pull)")
            symbol = "eye"
            tint = Theme.warning
            action = (L10n.text("apple.repositories.action_review"), .preview)
        case let .readyToMerge(pull):
            text = L10n.text("apple.repositories.step_ready", "\(pull)")
            symbol = "checkmark.circle"
            tint = Theme.pullOpen
            action = (L10n.text("apple.repositories.action_open"), .merge)
        case let .working(count):
            if count == 1, let agent = data.workingAgent {
                text = L10n.text("apple.repositories.step_working_agent", harnessName(harnessCanonicalID(agent)))
            } else {
                text = count == 1 ? L10n.text("apple.repositories.step_working.one")
                    : L10n.text("apple.repositories.step_working.other", "\(count)")
            }
            symbol = "circle.dotted"
            tint = Theme.stateWorking
            action = (L10n.text("apple.repositories.action_watch"), .preview)
        case .asleep:
            text = L10n.text("apple.repositories.step_asleep")
            symbol = "moon"
            tint = Theme.stateIdle
        case let .uncommitted(files):
            text = files == 1 ? L10n.text("apple.repositories.step_uncommitted.one")
                : L10n.text("apple.repositories.step_uncommitted.other", "\(files)")
            symbol = "pencil.line"
            tint = Theme.accent
            action = (L10n.text("apple.repositories.action_review"), .compare)
        case let .unpushed(commits):
            text = commits == 1 ? L10n.text("apple.repositories.step_unpushed.one")
                : L10n.text("apple.repositories.step_unpushed.other", "\(commits)")
            symbol = "arrow.up.circle"
            tint = Theme.accent
            action = (L10n.text("apple.repositories.action_review"), .compare)
        case let .behind(commits):
            text = commits == 1 ? L10n.text("apple.repositories.step_behind.one")
                : L10n.text("apple.repositories.step_behind.other", "\(commits)")
            symbol = "arrow.down.circle"
            tint = Theme.accent
            action = (L10n.text("apple.repositories.action_review"), .compare)
        case .clear:
            if let last = data.facts.lastActivity {
                text = L10n.text("apple.repositories.step_clear_since", CompactAge.ago(last))
            } else {
                text = L10n.text("apple.repositories.step_clear")
            }
            symbol = "checkmark"
            tint = Theme.stateIdle
        }
    }
}

extension RepositoryActions {
    /// The press a next step offers.
    func perform(_ step: RepositoryNextStep, in data: RepositoryCardData) {
        switch step {
        case let .waiting(id): chat(id, data.id)
        case let .checksFailed(number), let .changesRequested(number),
             let .reviewRequested(number), let .readyToMerge(number):
            pull(number, data.id)
        case .working:
            if let running = data.chats.first(where: \.running) { chat(running.id, data.id) } else { open(data.id) }
        case .uncommitted, .unpushed, .behind: section(.changes, data.id)
        case .missing, .asleep, .clear: open(data.id)
        }
    }
}

// MARK: - Card

struct RepositoryCard: View, Equatable {
    let data: RepositoryCardData
    let isSelected: Bool
    let isFocused: Bool
    let actions: RepositoryActions
    @State private var hovering = false

    static func == (a: Self, b: Self) -> Bool {
        a.data == b.data && a.isSelected == b.isSelected && a.isFocused == b.isFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stepLine
            if !data.days.isEmpty {
                RepositoryRibbon(keys: data.dayKeys, days: data.days, marks: data.marks)
            }
            if !data.chats.isEmpty { chatRows }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                facts
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel.opacity(hovering ? 0.97 : 0.82), in: shape)
        .overlay(shape.strokeBorder(border, lineWidth: isSelected || isFocused ? 1.5 : 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button(L10n.text("apple.repositories.open_repository")) { actions.open(data.id) }
            Button(L10n.text("apple.repositories.new_chat")) { actions.newChat(data.id) }
            Button(L10n.text("apple.repositories.peek")) { actions.peek(data.id) }
            if !data.isRemote {
                Button(L10n.text("apple.repositories.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: data.path)])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(data.name), \(RepositoryStepPresentation(data.step, data: data).text)")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
    }

    private var border: Color {
        isSelected || isFocused ? Theme.accent : hovering ? Theme.border : Theme.hairline
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { actions.open(data.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: data.symbol)
                        .font(Theme.font(15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(data.name).font(Theme.font(15, weight: .semibold)).lineLimit(1)
                            TeamFolderBadges(names: data.teams)
                        }
                        HStack(spacing: 5) {
                            Text(data.machine).lineLimit(1)
                            if let branch = data.branch {
                                Image(systemName: "arrow.triangle.branch").font(Theme.fixed(9, weight: .medium))
                                    .accessibilityHidden(true)
                                Text(branch).font(Theme.monoText(11)).lineLimit(1).truncationMode(.middle)
                            }
                            if data.ahead > 0 {
                                Text(L10n.text("apple.chatglance.ahead", "\(data.ahead)")).monospacedDigit().lineLimit(1)
                            }
                            if data.behind > 0 {
                                Text(L10n.text("apple.chatglance.behind", "\(data.behind)")).monospacedDigit().lineLimit(1)
                            }
                        }
                        .font(Theme.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(data.path)
            .accessibilityHint(L10n.text("apple.repositories.open_repository"))
            HStack(spacing: 0) {
                ToolbarIconButton(systemImage: ActionIcon.preview.symbol, help: L10n.text("apple.repositories.peek_help"),
                                  isAccent: isSelected) { actions.peek(data.id) }
                    .accessibilityLabel(L10n.text("apple.repositories.peek"))
                ToolbarIconButton(systemImage: "square.and.pencil", help: L10n.text("apple.repositories.new_chat")) {
                    actions.newChat(data.id)
                }
                .accessibilityLabel(L10n.text("apple.repositories.new_chat"))
            }
        }
    }

    private var stepLine: some View {
        let step = RepositoryStepPresentation(data.step, data: data)
        return HStack(spacing: 8) {
            Image(systemName: step.symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(step.tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(step.text).font(Theme.callout.weight(.medium)).lineLimit(1)
                .foregroundStyle(step.action == nil ? .secondary : .primary)
                .help(step.text)
            Spacer(minLength: 4)
            if let action = step.action {
                Button(action.label, action.icon) { actions.perform(data.step, in: data) }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minHeight: 36)
        .background(Theme.controlSeat.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var chatRows: some View {
        VStack(spacing: 0) {
            ForEach(data.chats.prefix(3)) { chat in
                Button { actions.chat(chat.id, data.id) } label: {
                    HStack(spacing: 8) {
                        HarnessMark(id: chat.backend, size: 18)
                        Text(chat.title).font(Theme.callout).lineLimit(1)
                        ChatPullMark(pulls: chat.pulls)
                        Spacer(minLength: 4)
                        if chat.waiting {
                            // The mark carries the colour. Amber words are too
                            // faint to read on a light card.
                            Circle().fill(Theme.warning).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(L10n.text("apple.repositories.chat_waiting")).font(Theme.subheadline.weight(.medium))
                        } else if chat.running {
                            Text(L10n.text("apple.repositories.chat_working"))
                                .foregroundStyle(Theme.accent).font(Theme.subheadline.weight(.medium))
                        } else {
                            Text(CompactAge.text(ms: chat.at)).font(Theme.subheadline)
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .frame(minHeight: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 7))
                .help(chat.title)
            }
        }
    }

    private var hasFacts: Bool {
        data.changedFiles > 0 || (data.openPulls ?? 0) > 0 || data.chatCount > 0 || data.taskCount > 0 || data.terminalCount > 0
    }

    /// Counts that exist. A zero is left out, so what is here is worth a press.
    /// A card too narrow for the words keeps the marks and the figures.
    @ViewBuilder private var facts: some View {
        if hasFacts {
            VStack(alignment: .leading, spacing: 8) {
                ThemeRule()
                ViewThatFits(in: .horizontal) {
                    factRow(compact: false)
                    factRow(compact: true)
                }
            }
        }
    }

    private func factRow(compact: Bool) -> some View {
        HStack(spacing: 18) {
            if data.changedFiles > 0 {
                fact(.changes, compact: compact, figure: data.changedFiles.formatted(),
                     label: data.changedFiles == 1 ? L10n.text("apple.repositories.files.one") : L10n.text("apple.repositories.files.other", data.changedFiles.formatted())) {
                    if data.added == 0, data.removed == 0 { Image(systemName: "doc.text") }
                    if data.added > 0 { Text("+\(data.added.formatted())").foregroundStyle(Theme.diffAdded) }
                    if data.removed > 0 { Text("−\(data.removed.formatted())").foregroundStyle(Theme.diffRemoved) }
                }
            }
            if let open = data.openPulls, open > 0 {
                fact(.pulls, compact: compact, figure: "\(open)", label: L10n.text("apple.repositories.pulls_open", "\(open)")) {
                    PullGlyphView(state: "open", tint: Theme.pullOpen)
                }
            }
            if data.chatCount > 0 {
                fact(.chat, compact: compact, figure: "\(data.chatCount)",
                     label: data.chatCount == 1 ? L10n.text("apple.workspacesoverviewview.0_chat_1.2838f969.one", "1") : L10n.text("apple.workspacesoverviewview.0_chat_1.2838f969.other", "\(data.chatCount)")) {
                    Image(systemName: "bubble.left")
                }
            }
            if data.taskCount > 0 {
                fact(.todo, compact: compact, figure: "\(data.taskCount)",
                     label: data.taskCount == 1 ? L10n.text("apple.workspacesoverviewview.0_task_1.d478181b.one", "1") : L10n.text("apple.workspacesoverviewview.0_task_1.d478181b.other", "\(data.taskCount)")) {
                    Image(systemName: "checklist")
                }
            }
            if data.terminalCount > 0 {
                fact(.sessions, compact: compact, figure: "\(data.terminalCount)",
                     label: data.terminalCount == 1 ? L10n.text("apple.workspacesoverviewview.0_session_1.aa4d5aa6.one", "1") : L10n.text("apple.workspacesoverviewview.0_session_1.aa4d5aa6.other", "\(data.terminalCount)")) {
                    Image(systemName: "terminal")
                }
            }
        }
        .fixedSize()
    }

    private func fact(_ section: WorkspaceSection, compact: Bool, figure: String, label: String,
                      @ViewBuilder mark: () -> some View) -> some View {
        Button { actions.section(section, data.id) } label: {
            HStack(spacing: 5) {
                mark().accessibilityHidden(true)
                Text(compact ? figure : label)
            }
            .font(Theme.subheadline).monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(RowFeedbackStyle(bleed: 8, radius: 7))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(section.label)
    }
}

// MARK: - Ribbon

/// Fourteen days of tokens, today last, with a mark on each day a pull request
/// was opened. Scaled to this repository's own busiest day, which is why the
/// total is always printed beside it.
struct RepositoryRibbon: View {
    let keys: [String]
    let days: [UInt64]
    let marks: [String: [PullSummary]]
    @State private var hovered: Int?

    private static let height: CGFloat = 40
    private static let spacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 4)
                if hovered == nil {
                    Text(L10n.text("apple.repositories.fourteen_days")).foregroundStyle(.tertiary)
                }
            }
            .font(Theme.subheadline)
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(days.indices, id: \.self) { index in
                    UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5)
                        .fill(fill(index))
                        .frame(height: barHeight(index))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: Self.height)
            .contentShape(.rect)
            .overlay {
                GeometryReader { geo in
                    Color.clear.contentShape(.rect)
                        .onContinuousHover { phase in
                            let next: Int?
                            switch phase {
                            case let .active(point):
                                let slot = geo.size.width / CGFloat(max(1, days.count))
                                next = slot > 0 ? min(days.count - 1, max(0, Int(point.x / slot))) : nil
                            case .ended: next = nil
                            }
                            if next != hovered { hovered = next }
                        }
                }
            }
            if keys.contains(where: { marks[$0] != nil }) {
                HStack(spacing: Self.spacing) {
                    ForEach(keys.indices, id: \.self) { index in
                        ZStack {
                            if let pull = lead(keys[index]) {
                                mark(pull)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("apple.repositories.tokens_in_days", formatTokens(total)))
        .accessibilityValue(days.indices.filter { days[$0] > 0 || marks[keys[$0]] != nil }.map(phrase).joined(separator: ". "))
    }

    private var total: UInt64 { days.reduce(0) { $0.saturatingAdd($1) } }

    private var caption: String {
        hovered.map(phrase) ?? L10n.text("apple.repositories.tokens", formatTokens(total))
    }

    private func phrase(_ index: Int) -> String {
        guard keys.indices.contains(index), days.indices.contains(index) else { return "" }
        let day: String
        if index == keys.count - 1 {
            day = L10n.text("apple.repositories.today")
        } else {
            day = RepositoryDays.date(keys[index])?.formatted(.dateTime.month(.abbreviated).day()) ?? keys[index]
        }
        var parts = [days[index] > 0 ? L10n.text("apple.repositories.tokens", formatTokens(days[index]))
            : L10n.text("apple.repositories.no_tokens")]
        for pull in (marks[keys[index]] ?? []).prefix(2) {
            parts.append(L10n.text("apple.repositories.pull_opened", "\(pull.number)"))
        }
        return "\(day): \(parts.joined(separator: ", "))"
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let peak = max(1, days.max() ?? 1)
        guard days[index] > 0 else { return 1 }
        return max(3, CGFloat(Double(days[index]) / Double(peak)) * Self.height)
    }

    private func fill(_ index: Int) -> Color {
        if hovered == index { return Theme.secondary }
        if days[index] == 0 { return Theme.controlSeat }
        return index == days.count - 1 ? Theme.accent : Theme.accent.opacity(0.42)
    }

    private func lead(_ key: String) -> PullSummary? {
        let pulls = marks[key] ?? []
        return pulls.first { $0.state == "open" } ?? pulls.first { $0.state == "merged" } ?? pulls.first
    }

    /// Open is an outline, settled is filled, so the two differ without colour.
    @ViewBuilder private func mark(_ pull: PullSummary) -> some View {
        let square = RoundedRectangle(cornerRadius: 1.5)
        if pull.state == "open" {
            square.strokeBorder(Theme.pullOpen, lineWidth: 1.5).frame(width: 7, height: 7).rotationEffect(.degrees(45))
        } else {
            square.fill(pull.state == "merged" ? Theme.pullMerged : Theme.pullClosed)
                .frame(width: 6, height: 6).rotationEffect(.degrees(45))
        }
    }
}
#endif
