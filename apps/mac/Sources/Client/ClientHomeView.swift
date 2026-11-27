// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientHomeView: View {
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.openClientAccount) private var openAccount
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(HomeModel.self) private var model
    @State private var layout = HomeLayout.shared
    @State private var selectedDay: HeatCell?
    @State private var pickingADay = false
    @State private var customizing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                greeting
                status
                ForEach(layout.sections) { section in
                    view(for: section)
                }
                if layout.sections.isEmpty {
                    clearHome
                }
                if model.calendar != nil, let notice = model.scopeNotice {
                    NoticeCard(text: notice, showSignIn: model.needsAccountSignIn)
                }
                customizeButton
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDisabled(pickingADay)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard !pickingADay, selectedDay == nil, !customizing,
                          value.startLocation.x <= 44,
                          value.translation.width >= 80,
                          value.translation.width > abs(value.translation.height) * 2 else { return }
                    openAccount()
                }
        )
        .refreshable {
            await ClientRefresh.pull("home") {
                await account.load()
                await model.refresh()
            }
        }
        .task {
            model.scope = .allMachines
            await model.load()
        }
        .onChange(of: layout.hidden.contains(.limits)) { _, hidden in
            if hidden { model.hidePlanLimits() }
        }
        .task(id: "\(layout.hidden.contains(.limits))-\(scenePhase)") {
            guard !layout.hidden.contains(.limits) else { return }
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.loadPlanLimits(force: false)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatEntitlementDidChange)) { _ in
            Task { await model.refresh() }
        }
        .sheet(item: $selectedDay) { day in
            DayDetailSheet(day: day)
        }
        .sheet(isPresented: $customizing) {
            ClientHomeEditor(layout: layout, emptyReason: emptyReason)
        }
        .onChange(of: navigation.homeEditorRequested, initial: true) { _, requested in
            guard requested else { return }
            navigation.homeEditorRequested = false
            customizing = true
        }
    }


    @ViewBuilder
    private func view(for section: HomeSection) -> some View {
        switch section {
        case .continueWork:
            ClientContinueSection()
        case .pinnedWork:
            ClientPinnedWorkSection()
        case .machines:
            ClientHomeMachinesSection()
        case .usage:
            if let calendar = model.calendar {
                totals(calendar)
            } else if model.isLoading {
                ClientWireframe.Totals()
            }
        case .activity:
            if let calendar = model.calendar {
                heatmapCard(calendar)
            } else if model.isLoading {
                ClientWireframe.Heatmap()
            }
        case .limits:
            if model.calendar != nil {
                ClientLimitsCard(
                    providers: model.planLimits,
                    isLoading: model.isLoadingLimits,
                    errorMessage: model.planErrorMessage
                )
            }
        }
    }

    private func emptyReason(_ section: HomeSection) -> String? {
        switch section {
        case .continueWork where ClientRecentPlaces.shared.places(in: account.account?.recentPlacesScope).isEmpty:
            return L10n.text("apple.clienthomeview.appears_after_you_open_a_folder_or_convers.032af20f")
        case .pinnedWork where PinnedWorkStore.shared.pins(in: account.account?.pinnedWorkScope).isEmpty:
            return L10n.text("apple.clienthomeview.pin_a_folder_or_conversation_to_keep_it_he.e84b9c14")
        case .machines where (account.account?.machines ?? []).isEmpty:
            return L10n.text("apple.clienthomeview.appears_when_your_account_has_linked_devic.8a84c464")
        case .limits where model.hasLoadedPlanLimits && !model.planLimits.contains(where: \.hasWindows) && model.planErrorMessage == nil:
            return L10n.text("apple.clienthomeview.readings_appear_after_a_linked_computer_sh.042da1f4")
        default: return nil
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.calendar != nil || model.isLoading {
            EmptyView()
        } else if model.hasConfirmedEmptyActivity {
            ClientGettingStarted()
        } else if let message = model.errorMessage {
            ClientEmptyState(
                kind: .unreachable,
                title: connectivity.isOffline ? L10n.text("apple.clienthomeview.you_are_offline.4d5c9439") : L10n.text("apple.clienthomeview.could_not_load_your_activity.83f3bb60"),
                message: connectivity.isOffline
                    ? L10n.text("apple.clienthomeview.this_updates_by_itself_when_the_connection.afd97997")
                    : FriendlyError.from(message).message,
                actionTitle: connectivity.isOffline ? nil : L10n.text("apple.clienthomeview.try_again.d8b8392e"),
                actionIcon: .refresh,
                action: connectivity.isOffline ? nil : { Task { await model.refresh() } }
            )
        } else {
            ClientEmptyState(
                kind: .unreachable,
                title: L10n.text("apple.clienthomeview.activity_is_unavailable.05583cc4"),
                message: model.scopeNotice ?? L10n.text("apple.clienthomeview.waiting_for_your_activity_to_load.49d8b7e3"),
                actionTitle: L10n.text("apple.clienthomeview.try_again.d8b8392e"),
                actionIcon: .refresh,
                action: { Task { await model.refresh() } }
            )
        }
    }

    private var clearHome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(L10n.text("apple.clienthomeview.your_home_is_clear.9ae93db2"))
                .font(ClientType.label.weight(.medium))
            Text(L10n.text("apple.clienthomeview.every_card_is_switched_off_the_tabs_and_yo.1ab18ab6"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }

    private var customizeButton: some View {
        Button(L10n.text("apple.clienthomeview.customize_home.642cec6e"), .layout) { customizing = true }
            .buttonStyle(.plain)
            .font(ClientType.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.top, Theme.Space.xs)
    }


    @ViewBuilder
    private var greeting: some View {
        if account.signedIn {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Text(greetingLine)
                    .font(ClientType.screenTitle)
                    .lineLimit(2)
                if let tier = account.account?.tier, !tier.isEmpty {
                    TierMark(tier: tier, size: 16)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var greetingLine: String {
        if let name = account.account?.title, !name.isEmpty {
            HomeGreeting.line(name: name, hasHistory: hasHistory)
        } else {
            HomeGreeting.line(hasHistory: hasHistory)
        }
    }

    private var hasHistory: Bool {
        (model.calendar?.activeDays ?? 0) > 0
    }

    private func totals(_ calendar: ActivityCalendar) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: Theme.Space.s) { totalTiles(calendar) }
            } else {
                HStack(spacing: Theme.Space.s) { totalTiles(calendar) }
            }
        }
    }

    private func totalTiles(_ calendar: ActivityCalendar) -> some View {
        Group {
            TotalTile(label: L10n.text("common.today"), micros: todayValue(calendar), mark: "mark_day")
            TotalTile(label: L10n.text("apple.homeview.last_7_days.0603deca"), micros: weekValue(calendar), mark: "mark_week")
        }
    }

    private func heatmapCard(_ calendar: ActivityCalendar) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center) {
                ClientSectionTitle(title: L10n.text("apple.clienthomeview.activity.38da1505"), mark: "mark_activity")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L10n.text("apple.clienthomeview.0_active_days.16d30c85", "\(calendar.activeDays)"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                    if let freshness = calendar.freshness {
                        Text(freshness)
                            .font(ClientType.caption)
                            .foregroundStyle(calendar.isStaleGrid ? Theme.warning : Color.secondary.opacity(0.8))
                    }
                }
            }
            PhoneHeatmap(
                calendar: calendar,
                onSelect: { day in
                    guard !day.isLocked else { return }
                    selectedDay = day
                },
                onScrub: { pickingADay = $0 }
            )
            if calendar.isHistoryLocked {
                HistoryLockBanner(days: calendar.historyDays ?? 30)
            }
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }


    private func todayValue(_ calendar: ActivityCalendar) -> UInt64 {
        days(calendar).last { $0.date == calendar.last }?.value ?? 0
    }

    private func weekValue(_ calendar: ActivityCalendar) -> UInt64 {
        days(calendar).suffix(7).reduce(0) { $0.saturatingAdd($1.value) }
    }

    private func days(_ calendar: ActivityCalendar) -> [HeatCell] {
        calendar.rows.flatMap { $0.compactMap { $0 } }.sorted { $0.date < $1.date }
    }
}

private struct TotalTile: View {
    let label: String
    let micros: UInt64
    let mark: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                Text(formatSpend(micros))
                    .font(ClientType.figureSmall)
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            FeatureMark(name: mark, size: 26)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.clienthomeview.0_1_at_api_list_price.c7adc814", "\(label)", "\(formatSpend(micros))"))
    }
}

private struct NoticeCard: View {
    @Environment(AccountModel.self) private var account
    let text: String
    let showSignIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(text, systemImage: "info.circle")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if showSignIn {
                Button(L10n.text("common.sign_in"), .signIn) { account.signIn() }
                    .clientGlassStyle()
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }
}

#endif
