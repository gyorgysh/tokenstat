// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatStartGlanceData {
    var week: [UInt64]
}

struct ChatStartGlance: View {
    let repository: WorkspaceFolder?
    let data: ChatStartGlanceData?
    let backend: String?
    var localProvider: String? = nil
    @State private var limits = PlanLimitsStore.shared
    @State private var projectWeek: [UInt64]?

    private static let height: CGFloat = 104

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            repositoryPanel
            spendPanel
            limitsPanel
        }
        .frame(maxWidth: .infinity)
        .task(id: repository?.id) { await loadProjectWeek() }
    }


    private var repositoryPanel: some View {
        GlancePanel(label: L10n.text("apple.chatglance.repository"), symbol: "arrow.triangle.branch",
                    height: Self.height) {
            if let folder = repository, !folder.isGeneral {
                let git = folder.git
                Text(git?.isRepo == true ? (git?.branch ?? folder.name) : folder.name)
                    .font(Theme.font(15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let git, git.isRepo {
                    HStack(spacing: 6) {
                        if !git.files.isEmpty {
                            Text("+\(git.added.formatted())").foregroundStyle(Theme.diffAdded)
                            Text("−\(git.removed.formatted())").foregroundStyle(Theme.diffRemoved)
                            Text(L10n.text("apple.chatglance.files", git.files.count.formatted()))
                                .foregroundStyle(.secondary)
                        } else {
                            Circle().fill(Theme.stateIdle).frame(width: 5, height: 5).accessibilityHidden(true)
                            Text(L10n.text("apple.chatglance.clean")).foregroundStyle(.secondary)
                        }
                    }
                    .font(Theme.caption).monospacedDigit()
                    Text(syncLine(git) ?? folder.machineLabel ?? L10n.text("apple.chatglance.this_mac"))
                        .font(Theme.caption).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                } else {
                    Text(L10n.text("apple.chatglance.not_repo")).font(Theme.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.text("apple.chatglance.no_repository")).font(Theme.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func syncLine(_ git: GitStatus) -> String? {
        var parts: [String] = []
        if git.ahead > 0 { parts.append(L10n.text("apple.chatglance.ahead", "\(git.ahead)")) }
        if git.behind > 0 { parts.append(L10n.text("apple.chatglance.behind", "\(git.behind)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }


    private func loadProjectWeek() async {
        projectWeek = nil
        guard let folder = repository, !folder.isGeneral, folder.machineID == nil else { return }
        let calendar = Calendar(identifier: .gregorian)
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let keys = days.map { formatter.string(from: $0) }
        guard let since = keys.first,
              let buckets = try? await Bridge.report(group: .day, query: Query(since: since, project: folder.name)),
              !Task.isCancelled else { return }
        let values = Dictionary(buckets.map { ($0.key, UInt64(max(0, $0.valueMicros))) }, uniquingKeysWith: { $0.saturatingAdd($1) })
        let week = keys.map { values[$0] ?? 0 }
        projectWeek = week.contains(where: { $0 > 0 }) ? week : nil
    }

    private var spendPanel: some View {
        let scoped = projectWeek
        let week = scoped ?? data?.week ?? []
        let total = week.reduce(UInt64(0)) { $0.saturatingAdd($1) }
        let label = scoped != nil ? (repository?.name ?? "") : L10n.text("apple.chatglance.all_projects")
        return GlancePanel(label: L10n.text("apple.chatglance.last_7_days"), symbol: "chart.bar", height: Self.height) {
            if week.isEmpty || total == 0 {
                Text(L10n.text("apple.chatglance.no_spend")).font(Theme.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatSpend(total)).font(Theme.font(15, weight: .semibold)).monospacedDigit()
                    Spacer(minLength: 4)
                    GlanceBars(values: week).frame(width: 64, height: 20)
                }
                Text(L10n.text("apple.chatglance.today", formatSpend(week.last ?? 0)))
                    .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(label).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }


    private var limitRows: [(provider: ProviderLimits, window: UsageWindow)] {
        let source = backend.map(harnessCanonicalID)
        if let source, let provider = limits.visible.first(where: { $0.source == source }), !provider.windows.isEmpty {
            return provider.windows.sorted { $0.percent > $1.percent }.prefix(2).map { (provider: provider, window: $0) }
        }
        return limits.visible
            .compactMap { provider in provider.windows.max { $0.percent < $1.percent }.map { (provider: provider, window: $0) } }
            .sorted { $0.window.percent > $1.window.percent }
            .prefix(2)
            .map { $0 }
    }

    private var limitsForPickedAgent: Bool {
        guard let source = backend.map(harnessCanonicalID) else { return false }
        return limits.visible.contains { $0.source == source && !$0.windows.isEmpty }
    }

    @ViewBuilder private var limitsPanel: some View {
        if let localProvider {
            GlancePanel(label: L10n.text("common.chat.local_limits_title"), symbol: "desktopcomputer", height: Self.height) {
                Text(L10n.text("common.chat.local_no_limits", LocalChatModel.providerName(localProvider)))
                    .font(Theme.callout).foregroundStyle(.secondary)
            }
        } else {
            planLimitsPanel
        }
    }

    private var planLimitsPanel: some View {
        let rows = limitRows
        let title = limitsForPickedAgent
            ? L10n.text("apple.chatglance.agent_limits", harnessName(harnessCanonicalID(backend ?? "")))
            : L10n.text("apple.chatglance.plan_limits")
        return GlancePanel(label: title, symbol: "gauge.with.dots.needle.50percent",
                           height: Self.height) {
            if rows.isEmpty {
                Text(L10n.text("apple.chatglance.no_limits")).font(Theme.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                HarnessMark(id: item.provider.source, size: 13)
                                Text(limitsForPickedAgent ? item.window.displayLabel : harnessName(item.provider.source))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text((item.window.percent / 100).formatted(.percent.precision(.fractionLength(0))))
                                    .foregroundStyle(item.window.severity == .normal ? Color.secondary : item.window.severity.tint)
                                    .monospacedDigit()
                            }
                            .font(Theme.caption)
                            GeometryReader { geo in
                                Capsule().fill(Theme.hairline)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(item.window.severity.tint)
                                            .frame(width: geo.size.width * min(1, max(0.02, item.window.percent / 100)))
                                    }
                            }
                            .frame(height: 3)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct GlancePanel<Content: View>: View {
    let label: String
    let symbol: String
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(Theme.font(10.5, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .labelStyle(GlanceLabelStyle())
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(Theme.panel.opacity(hovering ? 0.95 : 0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .combine)
    }
}

private struct GlanceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(Theme.font(9.5, weight: .semibold))
            configuration.title
        }
    }
}

private struct GlanceBars: View {
    let values: [UInt64]

    var body: some View {
        let peak = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index == values.count - 1 ? Theme.accent : Theme.accent.opacity(0.35))
                    .frame(height: max(2, CGFloat(Double(value) / Double(peak)) * 20))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
