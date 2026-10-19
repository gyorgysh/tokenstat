// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum ChatActivitySection: String {
    case goal, plan, subagents
    init?(command: String) { self.init(rawValue: String(command.dropFirst())) }
}

struct ChatActivityDisclosureState {
    private var choices: [ChatActivitySection: Bool] = [:]

    func isExpanded(_ section: ChatActivitySection, requested: ChatActivitySection?, hasContent: Bool) -> Bool {
        choices[section] ?? (requested.map { $0 == section } ?? hasContent)
    }

    mutating func setExpanded(_ expanded: Bool, for section: ChatActivitySection) {
        choices[section] = expanded
    }
}

struct ChatActivityOwner: Hashable {
    var reference: WorkReference?
    var backend: String?
    var model: String?
    var revision: UInt64?
    var selection: UInt64
    var session: UInt64
    var running: Bool
    var saved: Bool
}

struct ChatActivityRead {
    var owner: ChatActivityOwner
    var inspection: ChatInspection?
    var failed = false
    var loaded = false
    var lease = UUID()
}

/// Recent inspector reports can paint immediately while a fresh read runs.
/// They never establish live status, and never cross a login or run boundary.
@MainActor final class ChatActivitySnapshots {
    static let shared = ChatActivitySnapshots()
    private struct Entry {
        let owner: ChatActivityOwner
        let inspection: ChatInspection
        let storedAt: TimeInterval
    }
    private var entries: [Entry] = []

    private func key(_ owner: ChatActivityOwner) -> ChatActivityOwner {
        var key = owner
        key.selection = 0
        return key
    }

    func inspection(for owner: ChatActivityOwner,
                    now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ChatInspection? {
        guard !owner.saved, owner.reference != nil else { return nil }
        return entries.last(where: {
            $0.owner == key(owner)
                && now >= $0.storedAt && now - $0.storedAt < 30
        })?.inspection
    }

    func store(_ inspection: ChatInspection, for owner: ChatActivityOwner,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !owner.saved, owner.reference != nil, inspection.backend == owner.backend else { return }
        let owner = key(owner)
        entries.removeAll { $0.owner.session != owner.session || $0.owner == owner || now - $0.storedAt >= 30 }
        entries.append(Entry(owner: owner, inspection: inspection, storedAt: now))
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
    }
}

extension ChatModel {
    var activityOwner: ChatActivityOwner {
        ChatActivityOwner(reference: currentReference, backend: selected?.backend, model: selected?.model,
                          revision: selected?.runRevision, selection: selectionGeneration,
                          session: WorkSessionContext.shared.generation,
                          running: selected?.running == true, saved: savedCopy != nil)
    }

    var currentActivityRead: ChatActivityRead? {
        guard let reference = currentReference, WorkCacheAccess.canRead(reference) else { return nil }
        let owner = activityOwner
        if let read = activityRead, read.owner == owner { return read }
        guard let inspection = ChatActivitySnapshots.shared.inspection(for: owner) else { return nil }
        return ChatActivityRead(owner: owner, inspection: inspection, failed: true, loaded: true)
    }

    var inspectionIsLive: Bool {
        let read = currentActivityRead
        return read?.failed == false && read?.inspection?.currentRun == true && selected?.running == true
    }

    var activityIsLive: Bool {
        inspectionIsLive && currentActivityRead?.inspection?.activity?.live == true
    }

    func retireActivityRead() {
        activityRead?.failed = true
        activityRead?.lease = UUID()
    }

    /// One reader serves the summary, inspector and command sheet. A result
    /// cannot cross account, host, conversation, backend, model or run changes.
    func watchActivity() async {
        let requested = activityOwner
        let lease = UUID()
        let cached = currentActivityRead?.inspection
        activityRead = ChatActivityRead(owner: requested, inspection: cached, failed: cached != nil,
                                        loaded: cached != nil, lease: lease)
        defer {
            if activityRead?.lease == lease { activityRead?.failed = true }
        }
        guard !requested.saved, let reference = requested.reference,
              let id = reference.itemID, WorkCacheAccess.canRead(reference) else {
            activityRead = ChatActivityRead(owner: requested, loaded: true, lease: lease)
            return
        }
        let peer = peer
        while !Task.isCancelled, activityOwner == requested, activityRead?.lease == lease, WorkCacheAccess.canRead(reference) {
            do {
                let result = try await Bridge.chatInspection(id: id, peer: peer)
                guard !Task.isCancelled, activityOwner == requested, activityRead?.lease == lease, WorkCacheAccess.canRead(reference),
                      result.backend == requested.backend else { return }
                ChatActivitySnapshots.shared.store(result, for: requested)
                activityRead = ChatActivityRead(owner: requested, inspection: result, loaded: true, lease: lease)
            } catch {
                guard !Task.isCancelled, activityOwner == requested, activityRead?.lease == lease else { return }
                activityRead = ChatActivityRead(owner: requested, inspection: currentActivityRead?.inspection, failed: true, loaded: true, lease: lease)
                if case let BridgeError.core(code, _) = error, code == "unknown_method" { return }
            }
            do { try await Task.sleep(for: .seconds(busy ? 2 : 5)) } catch { return }
        }
    }
}

private struct ChatActivityPresentation: ViewModifier {
    @Bindable var model: ChatModel
    var active: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: ChatPollWatchIdentity(owner: model.activityOwner, active: active && scenePhase == .active)) {
                guard active, scenePhase == .active else { return }
                await model.watchActivity()
            }
            .onChange(of: model.activityOwner) { _, _ in model.showingActivity = false }
            .onChange(of: active) { _, active in
                if !active { model.showingActivity = false; model.retireActivityRead() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.retireActivityRead() }
            }
            .sheet(isPresented: $model.showingActivity) {
                ThemedSheet(title: L10n.text("common.chat.activity.title"), subtitle: "", scrolls: true, fills: true,
                            onClose: { model.showingActivity = false }) {
                    ChatActivityDetails(inspection: model.currentActivityRead?.inspection,
                                        live: model.activityIsLive, section: model.activitySection)
                        .id(model.activityOwner)
                } actions: { EmptyView() }
                .modalFrame(width: 580, height: 680)
            }
    }
}

extension View {
    func chatActivityPresentation(model: ChatModel, active: Bool) -> some View {
        modifier(ChatActivityPresentation(model: model, active: active))
    }
}

/// A quiet, persistent entry point while work is in progress. Unknown activity
/// stays absent here; the inspector and commands explain unreported sections.
struct ChatActivityStrip: View {
    @Bindable var model: ChatModel
    var body: some View {
        if let activity = model.currentActivityRead?.inspection?.activity, activity.hasContent {
            Button {
                model.activitySection = nil
                model.showingActivity = true
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        if let goal = activity.goal {
                            Text(goal.objective).lineLimit(1)
                        } else if let step = activity.plan.first(where: { $0.status == "inProgress" }) {
                            Text(step.text).lineLimit(1)
                        } else {
                            Text(L10n.text("common.chat.activity.title"))
                        }
                        ChatActivitySummary(activity: activity, live: model.activityIsLive)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(.secondary)
                }
                .font(Theme.caption).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .accessibilityHint(L10n.text("common.chat.activity.details"))
        }
    }
}

struct ChatActivityCard: View {
    @Bindable var model: ChatModel
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { expanded.toggle() } label: {
                HStack {
                    Label(L10n.text("common.chat.activity.title"), systemImage: "list.bullet.clipboard")
                        .font(Theme.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if model.activityIsLive {
                        Text(L10n.text("common.chat.activity.live")).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(Theme.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: activityRowHeight, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? L10n.text("common.collapse") : L10n.text("common.expand"))
            if expanded {
                ChatActivityDetails(inspection: model.currentActivityRead?.inspection, live: model.activityIsLive)
            } else if let activity = model.currentActivityRead?.inspection?.activity {
                ChatActivitySummary(activity: activity, live: model.activityIsLive)
            } else if model.currentActivityRead?.loaded == false {
                ProgressView().controlSize(.small)
            } else {
                Text(L10n.text("common.chat.activity.unavailable")).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .id(model.activityOwner)
    }
}

private struct ChatActivitySummary: View {
    let activity: ChatInspection.Activity
    var live: Bool
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { parts }
            VStack(alignment: .leading, spacing: 3) { parts }
        }.font(Theme.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var parts: some View {
        if let goal = activity.goal { Text(activityStatus(goal.status)) }
        if activity.planReported, !activity.plan.isEmpty {
            Text(L10n.text("common.chat.activity.steps", activity.completedSteps.formatted(), activity.plan.count.formatted())).monospacedDigit()
        }
        if activity.agentsReported, !activity.agents.isEmpty {
            Text(activity.agents.count == 1
                 ? L10n.text("common.chat.activity.one_subagent", activity.agents.count.formatted())
                 : L10n.text("common.chat.activity.agents", activity.agents.count.formatted())).monospacedDigit()
            if live, let count = activity.runningAgents, count > 0 {
                Text(L10n.text("common.chat.activity.running_agents", count.formatted())).foregroundStyle(Theme.accent)
            }
        }
        if !activity.hasContent { Text(L10n.text("common.chat.activity.no_activity")) }
        else if !live { Text(L10n.text("common.chat.activity.report_only")) }
    }
}

struct ChatActivityPlanChecklist: View {
    @Bindable var model: ChatModel

    var body: some View {
        if let activity = model.currentActivityRead?.inspection?.activity,
           activity.planReported, !activity.plan.isEmpty {
            ChatPlanChecklist(activity: activity, live: model.activityIsLive)
        }
    }
}

struct ChatPlanChecklist: View {
    let activity: ChatInspection.Activity
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(L10n.text("common.chat.activity.plan")).font(Theme.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(L10n.text("common.chat.activity.steps", activity.completedSteps.formatted(), activity.plan.count.formatted()))
                    .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ChatPlanSteps(steps: activity.plan, live: live)
            if !live {
                Text(L10n.text("common.chat.activity.report_only")).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

private struct ChatPlanSteps: View {
    let steps: [ChatInspection.Activity.Step]
    let live: Bool

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: step.status == "completed" ? "checkmark.circle.fill" : step.status == "inProgress" ? "circle.inset.filled" : "circle.dashed")
                    .foregroundStyle(live && step.status == "inProgress" ? Theme.accent : Color.secondary)
                    .frame(width: 16)
                Text(step.text).textSelection(.enabled)
                    .foregroundStyle(step.status == "completed" ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
            }
            .font(Theme.callout).padding(.vertical, 3)
            .accessibilityElement(children: .combine).accessibilityValue(activityStatus(step.status))
        }
    }
}

private struct ChatActivityDetails: View {
    var inspection: ChatInspection?
    var live: Bool
    private let requestedSection: ChatActivitySection?
    @State private var disclosures = ChatActivityDisclosureState()

    init(inspection: ChatInspection?, live: Bool, section: ChatActivitySection? = nil) {
        self.inspection = inspection
        self.live = live
        requestedSection = section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let activity = inspection?.activity {
                section(L10n.text("common.chat.activity.goal"), expanded: expansion(.goal, hasContent: activity.goal != nil)) {
                    if let goal = activity.goal {
                        Text(goal.objective).font(Theme.callout).textSelection(.enabled)
                        Text(activityStatus(goal.status)).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        if goal.tokensUsed != nil || goal.tokenBudget != nil {
                            budget(L10n.text("common.chat.activity.tokens"), used: goal.tokensUsed, limit: goal.tokenBudget)
                        }
                        if goal.timeUsedSeconds != nil || goal.timeBudgetSeconds != nil {
                            budget(L10n.text("common.chat.activity.time"), used: goal.timeUsedSeconds, limit: goal.timeBudgetSeconds, seconds: true)
                        }
                        source(goal.source)
                    } else { note(activity.goalReported ? L10n.text("common.chat.activity.none") : L10n.text("common.chat.activity.not_reported")) }
                }
                ThemeRule()
                section(L10n.text("common.chat.activity.plan"), expanded: expansion(.plan, hasContent: !activity.plan.isEmpty)) {
                    if activity.plan.isEmpty {
                        note(activity.planReported ? L10n.text("common.chat.activity.none") : L10n.text("common.chat.activity.not_reported"))
                    } else {
                        Text(L10n.text("common.chat.activity.steps", activity.completedSteps.formatted(), activity.plan.count.formatted()))
                            .font(Theme.caption).foregroundStyle(.secondary)
                        ChatActivityProgress(fraction: Double(activity.completedSteps) / Double(activity.plan.count))
                        ChatPlanSteps(steps: activity.plan, live: live)
                        if let value = activity.planSource { source(value) }
                    }
                }
                ThemeRule()
                section(L10n.text("common.chat.activity.subagents"), expanded: expansion(.subagents, hasContent: !activity.agents.isEmpty)) {
                    if activity.agents.isEmpty {
                        note(activity.agentsReported ? L10n.text("common.chat.activity.none") : L10n.text("common.chat.activity.not_reported"))
                    } else {
                        ForEach(activity.agents) { agent in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(agent.name ?? agent.id).font(Theme.caption.weight(.semibold)).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(activityStatus(activity.agentStatus(agent, live: live)))
                                        .font(Theme.caption).foregroundStyle(.secondary)
                                }
                                if let task = agent.task { Text(task).font(Theme.caption).textSelection(.enabled) }
                                if let model = agent.model { note(model) }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                if activity.partial { note(L10n.text("common.chat.activity.partial")) }
                if !live { note(L10n.text("common.chat.activity.report_only")) }
                if let stamp = inspection?.observedAtMs {
                    note(L10n.text("common.chat.activity.last_reported", Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .shortened)))
                }
            } else { note(L10n.text("common.chat.activity.unavailable")) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expansion(_ section: ChatActivitySection, hasContent: Bool) -> Binding<Bool> {
        Binding(get: { disclosures.isExpanded(section, requested: requestedSection, hasContent: hasContent) },
                set: { disclosures.setExpanded($0, for: section) })
    }

    private func section<Content: View>(_ title: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack {
                    Text(title).font(Theme.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(Theme.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: activityRowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expanded.wrappedValue ? L10n.text("common.collapse") : L10n.text("common.expand"))
            if expanded.wrappedValue { content() }
        }
    }

    private func budget(_ title: String, used: UInt64?, limit: UInt64?, seconds: Bool = false) -> some View {
        let amount: (UInt64) -> String = { seconds ? L10n.text("common.chat.activity.seconds", $0.formatted()) : $0.formatted() }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let limit {
                    Text(L10n.text("common.chat.activity.progress", used.map(amount) ?? L10n.text("common.chat.activity.not_reported"), amount(limit))).monospacedDigit()
                } else {
                    Text(used.map(amount) ?? L10n.text("common.chat.activity.not_reported")).monospacedDigit()
                }
            }.font(Theme.caption)
            if let used, let limit, limit > 0 { ChatActivityProgress(fraction: Double(used) / Double(limit)) }
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func source(_ value: String) -> some View {
        note(L10n.text("common.chat.activity.source", value == "tool" ? L10n.text("common.chat.activity.source_tool") : L10n.text("common.chat.activity.source_agent")))
    }
}

private struct ChatActivityProgress: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accentSoft)
                Capsule().fill(Theme.accent).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private var activityRowHeight: CGFloat {
    #if os(macOS)
    28
    #else
    44
    #endif
}

private func activityStatus(_ status: String) -> String {
    switch status {
    case "active": L10n.text("common.chat.activity.status_active")
    case "paused": L10n.text("common.chat.activity.status_paused")
    case "completed": L10n.text("common.chat.activity.status_completed")
    case "blocked": L10n.text("common.chat.activity.status_blocked")
    case "budgetLimited": L10n.text("common.chat.activity.status_budgetLimited")
    case "usageLimited": L10n.text("common.chat.activity.status_usageLimited")
    case "pending": L10n.text("common.chat.activity.status_pending")
    case "inProgress": L10n.text("common.chat.activity.status_inProgress")
    case "running": L10n.text("common.chat.activity.status_running")
    case "waiting": L10n.text("common.chat.activity.status_waiting")
    case "failed": L10n.text("common.chat.activity.status_failed")
    case "stopped": L10n.text("common.chat.activity.status_stopped")
    default: L10n.text("common.chat.activity.status_unknown")
    }
}
