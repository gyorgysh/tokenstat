// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

struct RepositoryPeek: View {
    @Bindable var model: RepositoryOverviewModel
    let folders: [WorkspaceFolder]
    let actions: RepositoryActions
    var onClose: () -> Void

    private var folder: WorkspaceFolder? { folders.first { $0.id == model.peekID } }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: folder?.name ?? L10n.text("apple.workspacesoverviewview.project.98595978"),
                               symbol: folder?.symbol ?? "folder")
                Spacer(minLength: 0)
            }
            if let folder {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        summary(folder)
                        if folder.git?.isRepo == true { changes(folder) }
                        pullSection(folder)
                        agents(folder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(folder.id)
            } else {
                InspectorEmptyState(mark: "mark_archive", title: L10n.text("apple.repositories.peek_empty_title"),
                                    subtitle: L10n.text("apple.repositories.peek_empty"))
                    .padding(.horizontal, Theme.Space.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .desktopPaneBackground()
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.font(10.5, weight: .semibold)).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { ThemeRule() }
    }

    private func summary(_ folder: WorkspaceFolder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.isRemote ? folder.machineLabel ?? L10n.text("apple.workspacesoverviewview.remote_machine.d9dd1af3")
                    : L10n.text("apple.workspacesoverviewview.this_mac.79a4aefc"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                Text(folder.path).font(Theme.caption).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if let usage = model.usage[folder.id], usage.week > 0 {
                Text(usage.weekValue.map {
                    L10n.text("apple.repositories.peek_week_value", formatTokens(usage.week), formatSpend(UInt64(clamping: $0)))
                } ?? L10n.text("apple.repositories.peek_week", formatTokens(usage.week)))
                    .font(Theme.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L10n.text("apple.repositories.new_chat"), .create) { actions.newChat(folder.id) }
                    .buttonStyle(AccentButtonStyle(small: true))
                Button(L10n.text("apple.repositories.action_open"), .reveal) { actions.open(folder.id) }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
        .padding(Theme.Space.m)
    }

    private func changes(_ folder: WorkspaceFolder) -> some View {
        let files = folder.git?.files ?? []
        return section(L10n.text("apple.repositories.not_committed")) {
            if files.isEmpty {
                Text(L10n.text("apple.chatglance.clean")).font(Theme.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(files.prefix(8)) { file in
                        Button { actions.file(file.path, folder.id) } label: {
                            HStack(spacing: 6) {
                                Text(file.fileName).font(Theme.monoText(11)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if let added = file.added, added > 0 {
                                    Text("+\(added.formatted())").foregroundStyle(Theme.diffAdded)
                                }
                                if let removed = file.removed, removed > 0 {
                                    Text("−\(removed.formatted())").foregroundStyle(Theme.diffRemoved)
                                }
                            }
                            .font(Theme.numeric(11))
                            .frame(minHeight: 28)
                            .contentShape(.rect)
                        }
                        .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 7))
                        .help(file.path)
                    }
                }
                if files.count > 8 {
                    Button(L10n.text("apple.repositories.all_files", files.count.formatted()), .next) { actions.section(.changes, folder.id) }
                        .buttonStyle(QuietLinkStyle())
                        .font(Theme.callout)
                }
            }
        }
    }

    @ViewBuilder private func pullSection(_ folder: WorkspaceFolder) -> some View {
        if let pulls = model.pulls[folder.id] {
            section(L10n.text("apple.route.pull_requests.d9e3f260")) {
                if pulls.open.isEmpty {
                    Text(L10n.text("apple.repositories.no_open_pulls")).font(Theme.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(pulls.open.prefix(6)) { pull in
                            Button { actions.pull(pull.number, folder.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    PullGlyphView(state: "open", tint: pull.draft ? Theme.stateIdle : Theme.pullOpen)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("#\(pull.number) \(pull.title)").font(Theme.callout).lineLimit(2)
                                        Text(status(pull, requested: pulls.requested.contains(pull.number)))
                                            .font(Theme.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 5)
                                .contentShape(.rect)
                            }
                            .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 7))
                        }
                    }
                    if pulls.open.count > 6 {
                        Button(L10n.text("apple.repositories.all_pulls", "\(pulls.open.count)"), .next) { actions.section(.pulls, folder.id) }
                            .buttonStyle(QuietLinkStyle())
                            .font(Theme.callout)
                    }
                }
            }
        }
    }

    private func status(_ pull: PullSummary, requested: Bool) -> String {
        if pull.draft { return L10n.text("apple.branchpull.draft") }
        var parts: [String] = []
        switch pull.checks {
        case .failing: parts.append(L10n.text("apple.repositories.checks_failed"))
        case .pending: parts.append(L10n.text("apple.repositories.checks_running"))
        case .passing: parts.append(L10n.text("apple.repositories.checks_passed"))
        case nil: break
        }
        if requested {
            parts.append(L10n.text("apple.repositories.your_review"))
        } else {
            switch pull.reviewDecision {
            case "approved": parts.append(L10n.text("apple.pullsview.approved.87b42e40"))
            case "changes_requested": parts.append(L10n.text("apple.pullsview.changes_requested.10a92a8a"))
            case "review_required": parts.append(L10n.text("apple.pullsview.review_needed.eb0807c2"))
            default: break
            }
        }
        if parts.isEmpty { parts.append(L10n.text("apple.branchpull.open")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func agents(_ folder: WorkspaceFolder) -> some View {
        if let usage = model.usage[folder.id], usage.total > 0, !usage.agents.isEmpty {
            let shown = Self.grouped(usage.agents)
            let total = max(1, shown.reduce(0.0) { $0 + Double($1.tokens) })
            section(L10n.text("apple.repositories.who_worked")) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                            RoundedRectangle(cornerRadius: 2).fill(Self.tint(index))
                                .frame(width: max(2, (geo.size.width - CGFloat(shown.count - 1) * 2) * Double(agent.tokens) / total))
                        }
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.tint(index)).frame(width: 8, height: 8)
                        Text(agent.id.isEmpty ? L10n.text("apple.repositories.other_agents") : harnessName(agent.id)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text((Double(agent.tokens) / total).formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(Theme.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private static func grouped(_ all: [RepositoryOverviewModel.Agent]) -> [RepositoryOverviewModel.Agent] {
        let total = all.reduce(0.0) { $0 + Double($1.tokens) }
        let agents = all.filter { Double($0.tokens) >= total * 0.005 }
        guard agents.count > 4 else { return agents }
        let rest = agents.dropFirst(3).reduce(UInt64(0)) { $0.saturatingAdd($1.tokens) }
        return Array(agents.prefix(3)) + [.init(id: "", tokens: rest)]
    }

    private static func tint(_ index: Int) -> Color {
        switch index {
        case 0: Theme.accent
        case 1: Theme.accent.opacity(0.55)
        case 2: Theme.secondary.opacity(0.8)
        default: Theme.stateIdle
        }
    }
}
#endif
