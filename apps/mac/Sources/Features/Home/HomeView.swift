// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct HomeView: View {
    @Environment(\.heatmapHover) private var heatmapHover
    @Bindable var model: HomeModel
    @AppStorage("activity.scope") private var savedScope: ActivityScope = .allMachines
    @Bindable var account: AccountModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hostReady) private var hostReady
    var onShowAccount: () -> Void
    @Bindable var scanner: InsightsModel
    var onOpenPin: (PinnedWorkStore.Pin) -> Void
    var pinAvailability: (PinnedWorkStore.Pin) -> String?
    var pinSubtitle: (PinnedWorkStore.Pin) -> String
    var recentWork: [DesktopHomeDestination]
    var onOpenRecent: (WorkReference) -> Void
    var onOpenMachine: (Machine) -> Void
    var setupHints: SetupHintsState? = nil
    @State private var layout = HomeLayout.shared
    @State private var editingHome = false
    @State private var pinsStore = PinnedWorkStore.shared

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar(accessory: { scopePicker }) {
                ToolbarIconButton(systemImage: ActionIcon.layout.symbol, help: L10n.text("apple.homeview.customize_home.642cec6e")) {
                    editingHome = true
                }
                if hostReady {
                    ToolbarIconButton(
                        systemImage: "arrow.clockwise",
                        help: L10n.text("apple.homeview.re_read_the_archive_for_this_device_s_acti.34b970ce"),
                        isBusy: model.isRefreshing,
                        isEnabled: !model.isLoading && !model.isRefreshing
                    ) {
                        Task {
                            LogoRefresh.began()
                            await account.load()
                            await model.refresh()
                        }
                    }
                }
            }
            ScrollView {
                WidthReader { width in
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if let message = model.errorMessage {
                            ErrorBanner(message: message)
                        }

                        if model.needsAccountSignIn { accountSignInPrompt }
                        profile
                        if let setupHints { SetupHintsCard(state: setupHints) }
                        if layout.sections.isEmpty {
                            clearHome
                        } else {
                            ForEach(layout.sections) { section in
                                sectionView(section, width: width)
                                    .id(section)
                            }
                        }
                        if showsLimitsSyncHint { limitsSyncHint }
                    }
                }
                .padding(Theme.Space.s)
            }
        }
        .desktopPaneBackground()
        #if os(macOS)
        .sheet(isPresented: $editingHome) {
            DesktopHomeEditor(layout: layout, emptyReason: emptyReason)
        }
        #endif
        .onDisappear { model.hover(day: nil) }
        .onChange(of: savedScope) { _, scope in Task { await model.setScope(scope) } }
        .task {
            #if os(macOS)
            try? await AgentProfileCatalog.shared.refresh()
            #endif
            await Self.waitForHost()
            guard !Task.isCancelled else { return }
            await model.setScope(savedScope)
            await model.refreshIfStale()
        }
        .onChange(of: layout.hidden.contains(.limits)) { _, hidden in
            if hidden { model.hidePlanLimits() }
        }
        .task(id: "\(layout.hidden.contains(.limits))-\(scenePhase)") {
            guard !layout.hidden.contains(.limits) else { return }
            guard scenePhase == .active else { return }
            await Self.waitForHost()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                await model.loadPlanLimits(force: false)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshIfStale() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .archiveDidChange)) { _ in
            Task { await model.reloadAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatEntitlementDidChange)) { _ in
            Task { await model.refresh() }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: HomeSection, width: CGFloat) -> some View {
        switch section {
        case .continueWork:
            DesktopContinueSection(destinations: recentWork, onOpen: onOpenRecent)
        case .pinnedWork:
            DesktopPinnedWorkSection(
                pins: pinsStore.pins(in: WorkSessionContext.shared.scope),
                availability: pinAvailability, subtitle: pinSubtitle, onOpen: onOpenPin
            )
        case .machines:
            DesktopHomeMachines(machines: account.account?.machines ?? [], onOpen: onOpenMachine)
        case .usage:
            usageSummary
        case .activity:
            activity
        case .limits:
            if let message = model.planErrorMessage { ErrorBanner(message: message) }
            panels(width: width)
            if limitsPending { panelPlaceholder }
        }
    }

    private func emptyReason(_ section: HomeSection) -> String? {
        switch section {
        case .continueWork where recentWork.isEmpty:
            return L10n.text("apple.homeview.appears_after_you_open_a_conversation.c00808b0")
        case .pinnedWork where pinsStore.pins(in: WorkSessionContext.shared.scope).isEmpty:
            return L10n.text("apple.homeview.pin_a_folder_from_the_sidebar_or_a_convers.33c68474")
        case .machines where (account.account?.machines ?? []).isEmpty:
            return L10n.text("apple.homeview.appears_when_your_account_has_linked_devic.8a84c464")
        case .limits where model.hasLoadedPlanLimits && panels.isEmpty && !limitsPending && model.planErrorMessage == nil:
            return L10n.text("apple.homeview.appears_when_a_connected_plan_has_usage_to.fd5f5a3e")
        default: return nil
        }
    }

    private var clearHome: some View {
        Card(title: L10n.text("apple.homeview.your_home_is_clear.9ae93db2"), subtitle: L10n.text("apple.homeview.your_work_is_still_in_the_sidebar.88f122e8"),
             leading: AnyView(ActionSeat(icon: .home, size: 24))) {
            Button(L10n.text("apple.homeview.customize_home.642cec6e"), .layout) { editingHome = true }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func figurePanel(title: String, value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center) {
                FeatureMark(name: "mark_insights", tint: Theme.accent, size: 22)
                Text(title)
                    .font(Theme.headline)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(Theme.numeric(20, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var usageSummary: some View {
        if model.calendar != nil {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                figurePanel(title: L10n.text("common.today"), value: model.todayValue.formatted, note: nil)
                figurePanel(title: L10n.text("apple.homeview.last_7_days.0603deca"), value: model.weekValue.formatted, note: nil)
                if let busiest = model.calendar?.busiest {
                    figurePanel(
                        title: L10n.text("apple.homeview.busiest.5192c2fb"),
                        value: formatSpend(busiest.value),
                        note: busiest.date
                    )
                }
            }
        } else if model.errorMessage != nil {
            Card(title: L10n.text("apple.homeview.today_and_this_week.2cb0c4ae"), mark: "mark_insights") {
                EmptyHint(text: L10n.text("apple.homeview.usage_could_not_be_read_see_the_message_ab.e05837aa"))
            }
        } else {
            Card(title: L10n.text("apple.homeview.today_and_this_week.2cb0c4ae"), mark: "mark_insights") {
                bar(width: nil, height: 40)
            }
        }
    }

    private static func waitForHost() async {
        for _ in 0..<100 {
            if await Bridge.hostSettled() { return }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    private var isWarming: Bool {
        model.isLoading && model.calendar == nil && model.errorMessage == nil
    }


    @ViewBuilder
    private func panels(width: CGFloat) -> some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(Array(rows(for: width).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    ForEach(row) { panel in
                        view(for: panel)
                            .transition(.smoothIn(reduceMotion: reduceMotion))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.18), value: panels.count)
    }

    private func rows(for width: CGFloat) -> [[HomePanel]] {
        let all = panels
        let count = columnCount(for: width)
        guard count > 0 else { return [all] }
        return stride(from: 0, to: all.count, by: count).map {
            Array(all[$0..<min($0 + count, all.count)])
        }
    }

    @ViewBuilder
    private func view(for panel: HomePanel) -> some View {
        switch panel.kind {
        case let .limits(provider):
            PlanLimitPanel(
                provider: provider,
                isLoading: model.isLoadingLimits,
                fillsHeight: true,
                profileTitle: limitProfileTitle(provider)
            ) {
                Task { await model.loadPlanLimits() }
            }
        case let .planUsage(rows):
            PlanUsageCard(rows: rows, fillsHeight: true)
        }
    }

    private func limitProfileTitle(_ provider: ProviderLimits) -> String? {
        guard let profiles = AgentProfileCatalog.shared.value, !profiles.named.isEmpty else { return nil }
        return profiles.profile(provider.profileId)?.title
    }

    private var panels: [HomePanel] {
        var out = PlanLimits.visible(model.planLimits).map { HomePanel(kind: .limits($0)) }
        if !model.planBySource.isEmpty {
            out.append(HomePanel(kind: .planUsage(model.planBySource)))
        }
        return out
    }

    private func columnCount(for width: CGFloat) -> Int {
        let fits = Int((width + Theme.Space.s) / (.panelWidth + Theme.Space.s))
        return max(1, min(panels.count, fits))
    }


    @AppStorage("home.limitsSyncHint.dismissed") private var limitsSyncHintDismissed = false

    private var showsLimitsSyncHint: Bool {
        !layout.hidden.contains(.limits)
            && !limitsSyncHintDismissed
            && account.signedIn
            && !account.limitsSyncEnabled
            && !PlanLimits.visible(model.planLimits).isEmpty
    }

    private var limitsSyncHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("apple.homeview.your_other_devices_cannot_see_these_number.464ea976"))
                    .font(Theme.callout.weight(.medium))
                Text(L10n.text("apple.homeview.account_has_a_plan_limits_card_for_how_muc.ba4309fd"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Button(L10n.text("apple.homeview.open_account.378549d3"), .account) { onShowAccount() }
                .buttonStyle(SecondaryButtonStyle())
            Button {
                limitsSyncHintDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.caption.weight(.semibold))
            }
            .buttonStyle(ControlFeedbackStyle(diameter: 24))
            .foregroundStyle(.secondary)
            .help(L10n.text("apple.homeview.do_not_offer_this_again.876977c3"))
            .accessibilityLabel(L10n.text("apple.homeview.dismiss.48845bff"))
        }
        .padding(Theme.Space.s)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .transition(.opacity)
    }

    private var greetingTitle: String {
        let hasHistory = (model.calendar?.activeDays ?? 0) > 0
        guard let name = account.account?.title, !name.isEmpty else {
            guard account.signedIn else { return L10n.text("apple.homeview.not_signed_in.491fc91c") }
            return HomeGreeting.line(hasHistory: hasHistory)
        }
        return HomeGreeting.line(name: name, hasHistory: hasHistory)
    }

    private var limitsPending: Bool {
        model.isLoadingLimits && model.planLimits.isEmpty
    }


    private var profile: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                profileIdentity
                Spacer()
                profileStats
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                profileIdentity
                profileStats
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.calendar != nil)
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var panelPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            bar(width: 96, height: 11, phase: 0)
            bar(width: nil, height: 10, phase: 0.08)
            bar(width: nil, height: 10, phase: 0.16)
        }
        .padding(Theme.cardPadding)
        .frame(width: .panelWidth, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .transition(.opacity)
    }

    private var activityPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            bar(width: nil, height: 187, phase: 0.12)
        }
        .transition(.opacity)
    }

    private func bar(width: CGFloat?, height: CGFloat, phase: Double = 0) -> some View {
        Skeleton.Bar(width: width, height: height, phase: phase)
    }

    @ViewBuilder
    private var profileIdentity: some View {
        if account.signedIn, let signed = account.account {
            ProfileNameButton(model: account, account: signed, fills: false) { identityContent }
        } else {
            HStack(alignment: .center, spacing: Theme.Space.m) { identityContent }
        }
    }

    @ViewBuilder
    private var identityContent: some View {
        Avatar(
            url: account.account?.avatar,
            name: account.account?.title,
            handle: account.account?.handle,
            size: 52
        )

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.s) {
                Text(greetingTitle)
                    .font(Theme.font(20, weight: .semibold))
                if let tier = account.account?.tier, !tier.isEmpty {
                    TierMark(tier: tier, size: 16)
                }
            }
            if let signed = account.account, signed.signedIn,
               signed.handle == nil || signed.handle != signed.title
            {
                ProfileNameLine(account: signed, font: Theme.callout)
            } else if !account.signedIn {
                Text(L10n.text("apple.homeview.working_locally.da99af57"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileStats: some View {
        if isWarming {
            HStack(spacing: Theme.Space.l) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        bar(width: 44, height: 8, phase: Double(index) * 0.1)
                        bar(width: 62, height: 20, phase: Double(index) * 0.1 + 0.05)
                    }
                }
            }
            .transition(.opacity)
        } else if let calendar = model.calendar {
            HStack(spacing: Theme.Space.l) {
                streak(
                    L10n.text("apple.homeview.streak.41db983f"),
                    "\(calendar.streakCurrent)",
                    note: calendar.streakCurrent == 1 ? "day" : "days",
                    tint: calendar.streakCurrent > 0 ? Theme.accent : .secondary
                )
                streak(L10n.text("apple.homeview.best.c47d21c6"), "\(calendar.streakBest)", note: "days")
                streak(L10n.text("common.active"), "\(calendar.activeDays)", note: "days")
            }
            .transition(.smoothIn(reduceMotion: reduceMotion))
        }
    }

    private func streak(
        _ label: String,
        _ value: String,
        note: String,
        tint: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.sectionHeader)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.numeric(24, weight: .medium))
                    .foregroundStyle(tint)
                Text(note)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }


    private var scopePicker: some View {
        #if os(macOS)
        ChromeTabStrip(
            tabs: ActivityScope.allCases.map { ChromeTab(id: $0.rawValue, label: $0.label, symbol: $0.symbol) },
            selected: model.scope.rawValue
        ) { id in
            if let scope = ActivityScope(rawValue: id) { Task { await model.setScope(scope) } }
        }
        .equatable()
        #else
        let binding = Binding<ActivityScope>(
            get: { model.scope },
            set: { scope in
                Task { await model.setScope(scope) }
            }
        )
        return SegmentedCapsulePicker(
            options: ActivityScope.allCases.map { (value: $0, label: $0.label, symbol: $0.symbol) },
            selection: binding
        )
        .frame(width: 280, alignment: .trailing)
        #endif
    }

    private var activitySubtitle: String {
        guard let calendar = model.calendar else {
            return L10n.text("apple.homeview.what_each_day_was_worth_at_api_list_price.c29a2633")
        }
        let base = L10n.text("apple.homeview.0_at_api_list_price_over_1_active_days.a929a181", "\(formatSpend(calendar.total))", "\(calendar.activeDays)")
        let source = model.deliveredScope == .allMachines
            ? L10n.text("apple.homeview.across_every_device_on_your_account.de7d54ab")
            : L10n.text("apple.homeview.on_this_device")
        if let notice = model.scopeNotice, !model.needsAccountSignIn {
            return base + source + ". " + notice
        }
        return base + source
    }

    @ViewBuilder
    private var activity: some View {
        Card(
            title: L10n.text("apple.homeview.activity.38da1505"),
            subtitle: activitySubtitle,
            mark: "mark_activity"
        ) {
            if let calendar = model.calendar {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HeatmapView(
                        calendar: calendar,
                        onSelect: { model.select(day: $0) },
                        selectedDate: model.selectedDay?.date,
                        onHover: { model.hover(day: $0) }
                    )
                    .onPreferenceChange(HoveredCellFrameKey.self) { frame in
                        MainActor.assumeIsolated { heatmapHover?.update(frame) }
                    }
                    .transformPreference(HoveredCellFrameKey.self) { $0 = nil }
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
            } else if model.errorMessage != nil {
                EmptyHint(text: L10n.text("apple.homeview.the_activity_could_not_be_read_see_the_mes.595eb6b5"))
            } else if model.isLoading {
                activityPlaceholder
            } else if model.hasConfirmedEmptyActivity {
                GettingStartedCard(
                    signedIn: account.signedIn,
                    isScanning: scanner.isScanning,
                    isCoolingDown: scanner.scanCooldownUntil != nil,
                    onSignIn: {
                        account.signIn()
                        onShowAccount()
                    },
                    onScan: { Task { await scanner.scan() } }
                )
            } else {
                activityPlaceholder
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.calendar != nil)
    }

    private var accountSignInPrompt: some View {
        HStack(spacing: Theme.Space.s) {
            Label(
                L10n.text("apple.homeview.all_devices_needs_your_tokenstat_ai_accoun.019e31cd"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(Theme.callout)
            .foregroundStyle(.secondary)

            Spacer(minLength: Theme.Space.s)

            Button {
                account.signIn()
                onShowAccount()
            } label: {
                ActionIcon.signIn.label(account.signedIn ? L10n.text("apple.homeview.reconnect.bf8a9eab") : L10n.text("common.sign_in"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(Theme.Space.m)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

private struct HomePanel: Identifiable {
    enum Kind {
        case limits(ProviderLimits)
        case planUsage([Bucket])
    }

    let kind: Kind

    var id: String {
        switch kind {
        case let .limits(provider): return "limits.\(provider.id)"
        case .planUsage: return "planUsage"
        }
    }
}
