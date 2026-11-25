// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// Every registered repository on every machine, by what it needs next.
///
/// The sidebar already lists the folders. This page answers the other
/// question: what is waiting on the person, what is moving, and what was left
/// unfinished. Each card says one next step and every figure on it opens the
/// page it counts.
///
/// Only drawn facts. A machine that is asleep keeps its last known folders,
/// and a missing figure means the host did not answer, not zero.
struct WorkspacesOverviewView: View {
    @Bindable var model: RepositoryOverviewModel
    var folders: [WorkspaceFolder]
    var summaries: [String: WorkspaceSummary]
    var directoryPresentation: WorkspaceDirectoryPresentation = .empty
    var directoryError: String? = nil
    var isFullScreen = false
    /// The inspector is on screen. A card it is not showing is not marked.
    var peekShown = false
    var onRetry: () -> Void = {}
    var chatsIn: (String) -> [ChatConversation]
    /// Live local sessions per folder id. Remote counts ride the summaries.
    var sessionsIn: (String) -> Int
    /// True only for a computer known to be away.
    var isAsleep: (WorkspaceFolder) -> Bool = { _ in false }
    /// The teams a local folder is shared into, by organization name. Empty
    /// for a folder nobody else can see.
    var sharedWith: (WorkspaceFolder) -> [String] = { _ in [] }
    var refreshChats: (WorkspaceFolder) async -> Void
    var actions: RepositoryActions
    var onAdd: () -> Void

    private enum Order: String, CaseIterable { case needs, yours, name }

    @State private var scope: String?
    @State private var search = ""
    @AppStorage("repositories.order") private var order: Order = .needs
    @State private var held: [String] = []
    @State private var settled = false
    @State private var columns = 2
    @State private var pointerOnCards = false
    @State private var showsAllNeeds = false
    @State private var pointer = ChatStartPointer()
    @FocusState private var focused: String?
    @Environment(\.scenePhase) private var scenePhase

    private static let cardMinimum: CGFloat = 360
    private static let gap: CGFloat = 14

    // MARK: Scope

    private struct MachineScope: Hashable {
        var id: String?
        var label: String
    }

    private var scopes: [MachineScope] {
        var scopes = [MachineScope(id: nil, label: L10n.text("apple.repositories.all_machines"))]
        if folders.contains(where: { !$0.isRemote }) {
            scopes.append(MachineScope(id: "local", label: L10n.text("apple.workspacesoverviewview.this_mac.79a4aefc")))
        }
        let remote = Dictionary(grouping: folders.filter(\.isRemote), by: \.machineID)
        for key in remote.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            scopes.append(MachineScope(id: key ?? "remote", label: remote[key]?.first.map(machine) ?? ""))
        }
        return scopes
    }

    private func matches(_ folder: WorkspaceFolder, query: String) -> Bool {
        guard scope == nil || (scope == "local" ? !folder.isRemote : folder.isRemote && (folder.machineID ?? "remote") == scope)
        else { return false }
        if query.isEmpty { return true }
        return folder.name.localizedCaseInsensitiveContains(query)
            || folder.path.localizedCaseInsensitiveContains(query)
            || (folder.machineLabel?.localizedCaseInsensitiveContains(query) ?? false)
            || chatsIn(folder.id).contains { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func machine(_ folder: WorkspaceFolder) -> String {
        guard folder.isRemote else { return L10n.text("apple.workspacesoverviewview.this_mac.79a4aefc") }
        let label = folder.machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == false) ? label! : L10n.text("apple.workspacesoverviewview.remote_machine.d9dd1af3")
    }

    // MARK: Data

    private func card(_ folder: WorkspaceFolder) -> RepositoryCardData {
        let summary = summaries[folder.id]
        let chats = chatsIn(folder.id)
        let usage = model.usage[folder.id]
        let pulls = model.pulls[folder.id]
        let terminals = folder.isRemote ? (summary?.sessions ?? 0) : sessionsIn(folder.id)
        let asleep = isAsleep(folder)
        // What a sleeping computer was doing when it was last heard is not
        // what it is doing now.
        let waiting = asleep ? [] : chats.filter { $0.waiting == true }
        let running = asleep ? [] : chats.filter { $0.running && $0.waiting != true }
        let last = chats.map { $0.lastMessageAtMs ?? $0.updatedAtMs }.max()

        var facts = RepositoryFacts()
        facts.exists = folder.exists
        facts.reachable = !asleep
        facts.waitingChatIDs = waiting.map(\.id)
        facts.runningChats = running.count
        facts.liveTerminals = asleep ? 0 : terminals
        facts.changedFiles = folder.changeCount
        facts.unpushedCommits = Int(folder.git?.ahead ?? 0)
        facts.behindCommits = Int(folder.git?.behind ?? 0)
        facts.lastActivity = last.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil }
        facts.hasRecentUsage = (usage?.total ?? 0) > 0
        facts.pulls = (pulls?.open ?? []).map { pull in
            .init(number: pull.number, mine: pulls?.isMine(pull) ?? false, draft: pull.draft,
                  failing: pull.checks == .failing, passing: pull.checks == .passing,
                  review: pull.reviewDecision, reviewRequested: pulls?.requested.contains(pull.number) ?? false)
        }

        let rows = chats.sorted { a, b in
            func rank(_ chat: ChatConversation) -> Int {
                asleep ? 2 : chat.waiting == true ? 0 : chat.running ? 1 : 2
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (a.lastMessageAtMs ?? a.updatedAtMs) > (b.lastMessageAtMs ?? b.updatedAtMs)
        }
        let branch = folder.git?.isRepo == true ? folder.git?.branch : nil
        return RepositoryCardData(
            id: folder.id, name: folder.name, path: folder.path, machine: machine(folder),
            isRemote: folder.isRemote, symbol: folder.symbol,
            branch: branch?.isEmpty == false ? branch : nil,
            ahead: folder.git?.ahead ?? 0, behind: folder.git?.behind ?? 0,
            teams: sharedWith(folder), facts: facts, step: RepositoryNextStep.next(facts),
            workingAgent: running.first?.backend,
            dayKeys: usage == nil ? [] : model.days, days: usage?.days ?? [], marks: pulls?.marks ?? [:],
            // Every waiting or running chat, so the strip can name each one.
            chats: Array(rows.prefix(max(3, waiting.count + running.count))).map {
                .init(id: $0.id, title: $0.title, backend: $0.backend, at: $0.lastMessageAtMs ?? $0.updatedAtMs,
                      running: !asleep && $0.running, waiting: !asleep && $0.waiting == true, pulls: $0.pulls)
            },
            added: folder.git?.added ?? 0, removed: folder.git?.removed ?? 0, changedFiles: folder.changeCount,
            openPulls: pulls?.open.count,
            chatCount: summary?.chats ?? chats.count, taskCount: summary?.tasks ?? 0, terminalCount: terminals,
            isQuiet: RepositoryNextStep.isQuiet(facts))
    }

    /// In the order asked for, taken once and then held still.
    private func sorted(_ cards: [RepositoryCardData]) -> [RepositoryCardData] {
        switch order {
        case .yours: return cards
        case .name: return cards.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .needs:
            let fresh = Self.ranked(cards)
            guard settled else { return fresh }
            let ids = RepositoryOrder.merge(held: held, current: fresh.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
    }

    private static func ranked(_ cards: [RepositoryCardData]) -> [RepositoryCardData] {
        cards.enumerated().sorted { a, b in
            if a.element.step.rank != b.element.step.rank { return a.element.step.rank < b.element.step.rank }
            let left = a.element.facts.lastActivity ?? .distantPast
            let right = b.element.facts.lastActivity ?? .distantPast
            return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
    }

    private func hold(_ cards: [RepositoryCardData]) {
        held = Self.ranked(cards).map(\.id)
        settled = true
    }

    // MARK: Body

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = folders.map(card)
        let visible = Set(folders.filter { matches($0, query: query) }.map(\.id))
        let shown = sorted(all).filter { visible.contains($0.id) }
        // A search or a chosen order is a request to see them, not a summary.
        let splits = order == .needs && query.isEmpty
        let active = splits ? shown.filter { !$0.isQuiet } : shown
        let quiet = splits ? shown.filter(\.isQuiet) : []

        VStack(spacing: 0) {
            DetailChromeBar { EmptyView() }
            VStack(spacing: 0) {
                tools
                ThemeRule()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if folders.isEmpty {
                            if directoryPresentation == .empty {
                                FirstProjectPrompt(onAdd: onAdd).frame(maxWidth: .infinity)
                            } else {
                                WorkspaceDirectoryPlaceholder(presentation: directoryPresentation,
                                                              error: directoryError, retry: onRetry)
                            }
                        } else if shown.isEmpty {
                            ContentUnavailableView.search(text: search)
                        } else {
                            if query.isEmpty {
                                hero(shown)
                                needsStrip(shown)
                            }
                            if !active.isEmpty { grid(active, titled: !quiet.isEmpty) }
                            if !quiet.isEmpty { quietList(quiet) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                    .frame(maxWidth: 1180, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .background {
                // The new chat page's surface, held still: the same room, with
                // the light on the headline instead of the composer.
                ChatStartBackdrop(isFullScreen: isFullScreen, active: false, pointer: pointer,
                                  focus: UnitPoint(x: 0.3, y: 0.08))
            }
        }
        .onChange(of: folders.map(\.id)) { _, _ in
            // The machine a filter named can leave while the filter stays.
            // Fall back to all rather than an empty grid.
            if let scope, !scopes.contains(where: { $0.id == scope }) { self.scope = nil }
            if let peek = model.peekID, !folders.contains(where: { $0.id == peek }) { model.peekID = nil }
        }
        .onChange(of: order) { _, _ in hold(folders.map(card)) }
        .task(id: scenePhase != .background) {
            guard scenePhase != .background else { return }
            await keepFresh()
        }
    }

    /// Reads only, and only while the page is on screen. Local chat lists come
    /// from the host's memory. Paired computers are asked once a minute, and
    /// only those that already answered.
    private func keepFresh() async {
        await BridgeLaunch.wait()
        var pass = 0
        while !Task.isCancelled {
            for folder in folders {
                guard !Task.isCancelled else { return }
                if folder.isRemote, pass % 6 != 0 || summaries[folder.id] == nil || isAsleep(folder) { continue }
                await refreshChats(folder)
            }
            await model.loadUsage(folders)
            if !settled, !folders.isEmpty, !Task.isCancelled { hold(folders.map(card)) }
            await model.loadPulls(folders.filter { !card($0).isQuiet })
            // The first answers about pull requests may reorder the page, but
            // never under a pointer or a keyboard that is already using it.
            if pass == 0, !Task.isCancelled, !folders.isEmpty, !pointerOnCards, focused == nil {
                hold(folders.map(card))
            }
            pass += 1
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: Theme.Space.s) {
            SearchField(text: $search, prompt: L10n.text("apple.workspacesoverviewview.search_projects.9e079c7d"))
                .frame(maxWidth: 300)
            if scopes.count > 2 {
                Picker(L10n.text("apple.workspacesoverviewview.machine.8f1cc42d"), selection: $scope) {
                    ForEach(scopes, id: \.id) { scope in
                        Text(scope.label).tag(scope.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Picker(L10n.text("apple.workspacesoverviewview.sort.bec69036"), selection: $order) {
                Text(L10n.text("apple.repositories.order_needs")).tag(Order.needs)
                Text(L10n.text("apple.workspacesoverviewview.your_order.f159e18f")).tag(Order.yours)
                Text(L10n.text("apple.workspacesoverviewview.name_a_z.7ed96629")).tag(Order.name)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: Theme.Space.s)
            Button(L10n.text("common.add_project"), .create) { onAdd() }
                .buttonStyle(AccentButtonStyle(small: true))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    // MARK: Headline

    private func hero(_ cards: [RepositoryCardData]) -> some View {
        let owed = cards.reduce(0) { $0 + RepositoryNextStep.owed($1.facts).count }
        let working = cards.reduce(0) { $0 + $1.facts.runningChats }
        let unfinished = cards.filter { $0.facts.reachable && ($0.facts.changedFiles > 0 || $0.facts.unpushedCommits > 0) }.count
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 32) {
                headline(owed: owed, working: working, unfinished: unfinished).fixedSize()
                Spacer(minLength: 0)
                figures(cards)
            }
            VStack(alignment: .leading, spacing: 16) {
                headline(owed: owed, working: working, unfinished: unfinished)
                figures(cards)
            }
        }
    }

    private func headline(owed: Int, working: Int, unfinished: Int) -> some View {
        let title: String
        if owed > 0 {
            title = owed == 1 ? L10n.text("apple.repositories.headline_needs.one") : L10n.text("apple.repositories.headline_needs.other", "\(owed)")
        } else if working > 0 {
            title = working == 1 ? L10n.text("apple.repositories.headline_working.one") : L10n.text("apple.repositories.headline_working.other", "\(working)")
        } else {
            title = L10n.text("apple.repositories.headline_clear")
        }
        var lines: [String] = []
        if owed > 0, working > 0 {
            lines.append(working == 1 ? L10n.text("apple.repositories.sub_working.one") : L10n.text("apple.repositories.sub_working.other", "\(working)"))
        }
        if unfinished > 0 {
            lines.append(unfinished == 1 ? L10n.text("apple.repositories.sub_unfinished.one") : L10n.text("apple.repositories.sub_unfinished.other", "\(unfinished)"))
        }
        if lines.isEmpty { lines.append(L10n.text("apple.repositories.sub_clear")) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.largeTitle).accessibilityAddTraits(.isHeader)
            Text(lines.joined(separator: " ")).font(Theme.body).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func figures(_ cards: [RepositoryCardData]) -> some View {
        let usage = cards.compactMap { model.usage[$0.id] }
        let week = usage.reduce(UInt64(0)) { $0.saturatingAdd($1.week) }
        if week > 0 {
            let today = usage.reduce(UInt64(0)) { $0.saturatingAdd($1.today) }
            let value = usage.compactMap(\.weekValue).reduce(Int64(0), +)
            HStack(alignment: .top, spacing: 28) {
                figure(L10n.text("apple.repositories.tokens_today"), formatTokens(today))
                figure(L10n.text("apple.repositories.tokens_week"), formatTokens(week))
                if value > 0 {
                    // List-rate value, never a bill. See `Bucket.value`.
                    figure(L10n.text("apple.repositories.week_list_rates"), formatSpend(UInt64(value)))
                }
            }
            .fixedSize()
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.font(10.5, weight: .semibold)).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value).font(Theme.font(17, weight: .semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Needs you

    private struct Need: Identifiable {
        var card: RepositoryCardData
        var step: RepositoryNextStep
        var id: String { "\(card.id)|\(step)" }
    }

    private static func needs(in cards: [RepositoryCardData]) -> [Need] {
        var needs: [Need] = []
        for card in cards {
            for step in RepositoryNextStep.owed(card.facts) { needs.append(Need(card: card, step: step)) }
        }
        // Most pressing first across repositories, steady among equals.
        let ranked = needs.enumerated().sorted { (a: (offset: Int, element: Need), b: (offset: Int, element: Need)) -> Bool in
            let left = a.element.step.rank, right = b.element.step.rank
            return left == right ? a.offset < b.offset : left < right
        }
        return ranked.map(\.element)
    }

    @ViewBuilder private func needsStrip(_ cards: [RepositoryCardData]) -> some View {
        let needs = Self.needs(in: cards)
        if !needs.isEmpty {
            let visible = showsAllNeeds ? needs : Array(needs.prefix(6))
            VStack(alignment: .leading, spacing: 12) {
                eyebrow(L10n.text("apple.repositories.needs_you"), count: needs.count)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(visible) { need in needCard(need) }
                }
                if needs.count > visible.count {
                    Button(L10n.text("apple.repositories.show_more", "\(needs.count - visible.count)"), .more) { showsAllNeeds = true }
                        .buttonStyle(QuietLinkStyle())
                        .font(Theme.callout)
                }
            }
        }
    }

    private func needCard(_ need: Need) -> some View {
        let step = RepositoryStepPresentation(need.step, data: need.card)
        let detail = detail(need)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: step.symbol).font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(step.tint).frame(width: 16).accessibilityHidden(true)
                Text(step.text).font(Theme.callout.weight(.semibold)).lineLimit(1).help(step.text)
                Spacer(minLength: 4)
                if let age = detail.age {
                    Text(age).font(Theme.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(detail.title).font(Theme.callout).foregroundStyle(.secondary).lineLimit(1).help(detail.title)
            HStack(spacing: 8) {
                Text(need.card.name).font(Theme.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule())
                Spacer(minLength: 4)
                if let action = step.action {
                    Button(action.label, action.icon) { actions.perform(need.step, in: need.card) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.text), \(need.card.name)")
    }

    private func detail(_ need: Need) -> (title: String, age: String?) {
        switch need.step {
        case let .waiting(id):
            guard let chat = need.card.chats.first(where: { $0.id == id }) else { return (need.card.name, nil) }
            return (chat.title, chat.at > 0 ? CompactAge.text(ms: chat.at) : nil)
        case let .checksFailed(number), let .changesRequested(number),
             let .reviewRequested(number), let .readyToMerge(number):
            guard let pull = model.pulls[need.card.id]?.open.first(where: { $0.number == number }) else { return ("#\(number)", nil) }
            return (pull.title, pull.updatedDate.map { CompactAge.text($0) })
        default: return (need.card.name, nil)
        }
    }

    // MARK: Cards

    private func eyebrow(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.font(10.5, weight: .semibold)).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            Text("\(count)").font(Theme.subheadline).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    private func grid(_ cards: [RepositoryCardData], titled: Bool) -> some View {
        let ids = cards.map(\.id)
        let rows = stride(from: 0, to: cards.count, by: columns).map { Array(cards[$0..<min($0 + columns, cards.count)]) }
        return VStack(alignment: .leading, spacing: 12) {
            if titled { eyebrow(L10n.text("apple.repositories.active"), count: cards.count) }
            // A grid rather than a lazy one: cards in a row share a height,
            // and nobody has enough repositories in use for that to cost.
            Grid(alignment: .topLeading, horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
                ForEach(rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { data in
                            RepositoryCard(data: data, isSelected: peekShown && model.peekID == data.id,
                                           isFocused: focused == data.id, actions: actions)
                                .equatable()
                                .focusable()
                                .focusEffectDisabled()
                                .focused($focused, equals: data.id)
                                .onTapGesture {
                                    focused = data.id
                                    if peekShown, model.peekID != nil { model.peekID = data.id }
                                }
                                .onKeyPress { press in handle(press, data: data, ids: ids) }
                        }
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes(.vertical)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { pointerOnCards = $0 }
        .onGeometryChange(for: Int.self) { proxy in
            max(1, min(3, Int((proxy.size.width + Self.gap) / (Self.cardMinimum + Self.gap))))
        } action: { columns = $0 }
    }

    private func handle(_ press: KeyPress, data: RepositoryCardData, ids: [String]) -> KeyPress.Result {
        guard press.modifiers.isSubset(of: [.numericPad, .function]) else { return .ignored }
        switch press.key {
        case .space: actions.peek(data.id); return .handled
        case .return: actions.open(data.id); return .handled
        case .leftArrow: return move(-1, from: data.id, ids: ids)
        case .rightArrow: return move(1, from: data.id, ids: ids)
        case .upArrow: return move(-columns, from: data.id, ids: ids)
        case .downArrow: return move(columns, from: data.id, ids: ids)
        default: return .ignored
        }
    }

    private func move(_ delta: Int, from id: String, ids: [String]) -> KeyPress.Result {
        guard let index = ids.firstIndex(of: id),
              let next = RepositoryOrder.move(from: index, by: delta, count: ids.count) else { return .ignored }
        focused = ids[next]
        // A peek that is open follows the cards, the way Quick Look does.
        if peekShown, model.peekID != nil { model.peekID = ids[next] }
        return .handled
    }

    private func quietList(_ cards: [RepositoryCardData]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                eyebrow(L10n.text("apple.repositories.quiet"), count: cards.count)
                Text(L10n.text("apple.repositories.quiet_note")).font(Theme.subheadline).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
            ForEach(cards) { data in
                Button { actions.open(data.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: data.symbol).font(Theme.font(13)).foregroundStyle(.secondary)
                            .frame(width: 18).accessibilityHidden(true)
                        Text(data.name).font(Theme.callout.weight(.semibold)).lineLimit(1)
                        TeamFolderBadges(names: data.teams)
                        Text(data.machine).font(Theme.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer(minLength: 8)
                        if let line = quietLine(data) {
                            Text(line).font(Theme.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                        RowChevron()
                    }
                    .frame(minHeight: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(RowFeedbackStyle(bleed: 10, radius: 8))
                .help(data.path)
                if data.id != cards.last?.id { ThemeRule().padding(.horizontal, 10) }
            }
        }
    }

    private func quietLine(_ data: RepositoryCardData) -> String? {
        var parts: [String] = []
        if case .asleep = data.step { parts.append(L10n.text("apple.repositories.step_asleep")) }
        if data.chatCount > 0 {
            parts.append(data.chatCount == 1 ? L10n.text("apple.workspacesoverviewview.0_chat_1.2838f969.one", "1")
                : L10n.text("apple.workspacesoverviewview.0_chat_1.2838f969.other", "\(data.chatCount)"))
        }
        if let last = data.facts.lastActivity { parts.append(CompactAge.ago(last)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
#endif
