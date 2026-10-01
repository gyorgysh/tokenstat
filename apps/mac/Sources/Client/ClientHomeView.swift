// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// What did I spend, everywhere, with every laptop asleep.
///
/// Account plane only, and that is the rule to hold hardest. A phone is what
/// you have precisely when the Mac is closed, so a Home screen that needs the
/// Mac awake is blank exactly when it is wanted. See `docs/mobile-app.md`.
struct ClientHomeView: View {
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.openClientAccount) private var openAccount
    @State private var model = HomeModel()
    @State private var layout = HomeLayout.shared
    /// The day whose detail sheet is open. A sheet rather than the Mac's hover
    /// popover, because a finger has no hover.
    @State private var selectedDay: HeatCell?
    /// A finger is holding the heatmap, so this page does not scroll.
    @State private var pickingADay = false
    @State private var customizing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                greeting
                // Outside the arrangement, deliberately. Whether the account
                // could be read at all is the screen talking, not a card
                // somebody chose to keep, and hiding Activity must not hide
                // "you are offline".
                status
                // In the order this device was arranged in. A card with
                // nothing to say draws nothing and keeps its place.
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
            // Clear of the floating tab bar. The bar is chrome over content,
            // so the content has to end above it rather than under it.
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        // Always, not based on size. `basedOnSize` stops a short screen from
        // bouncing, and a screen that cannot bounce cannot be pulled: the
        // refresh gesture quietly disappeared exactly when the page was empty,
        // which is when somebody most wants to pull it.
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDisabled(pickingADay)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    // A deliberate rightward edge swipe opens the same sheet
                    // as the avatar, leaving vertical scroll and card gestures alone.
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
            // Account scope always. There is no local archive to fall back to,
            // and asking for one would only produce a refusal to render.
            model.scope = .allMachines
            await model.load()
        }
        .onChange(of: layout.hidden.contains(.limits)) { _, hidden in
            if hidden { model.hidePlanLimits() }
        }
        .task(id: layout.hidden.contains(.limits)) {
            guard !layout.hidden.contains(.limits) else { return }
            await model.loadPlanLimits()
        }
        // The connection came back. Fetch now rather than leaving somebody
        // looking at an offline card on a phone that is plainly online again,
        // which is the moment they would otherwise force-quit the app.
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
        // Search asked for the editor by name. `initial` because Home may
        // have been the screen behind search all along, in which case nothing
        // changes here except the flag.
        .onChange(of: navigation.homeEditorRequested, initial: true) { _, requested in
            guard requested else { return }
            navigation.homeEditorRequested = false
            customizing = true
        }
    }

    // MARK: - Sections

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
            // Below the grid, and only once there is an account behind it.
            // `model.calendar` being nil means the load failed or has not
            // landed, and this has nothing to say then.
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

    /// What happened to the account read, when something did.
    ///
    /// A quiet, locked or cached grid still belongs to an existing account.
    /// Setup requires a successful empty response.
    @ViewBuilder
    private var status: some View {
        if model.calendar != nil || model.isLoading {
            EmptyView()
        } else if model.hasConfirmedEmptyActivity {
            ClientGettingStarted()
        } else if let message = model.errorMessage {
            // A failed load replaces the wireframe with the reason. A
            // skeleton that never resolves is a lie told slowly.
            //
            // Offline gets its own words. Every screen here is account
            // plane, so with no network there is nothing to fetch and
            // nothing anybody can do about it: the honest line is "you
            // are offline", not the transport error underneath it,
            // which reads like the product is broken.
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
            // No authoritative empty answer yet. Recovery and stale
            // or fallback calendars must not send an account to setup.
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

    /// Every card switched off. Not an error, and not empty space with
    /// nothing to press: the way back is right here.
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

    /// At the bottom, under everything it arranges. A control for changing
    /// the furniture does not belong above the furniture.
    private var customizeButton: some View {
        Button(L10n.text("apple.clienthomeview.customize_home.642cec6e"), .layout) { customizing = true }
            .buttonStyle(.plain)
            .font(ClientType.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.top, Theme.Space.xs)
    }

    // MARK: - Pieces

    /// Same line the website and the Mac home use: a local-clock phrase,
    /// the first name, and the star / badge / crown next to it.
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

    /// The greeting keeps its phrase when the account has no name to
    /// greet by. A missing display name and handle say nothing about
    /// the session, so the line stays and only the name drops out.
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
        HStack(spacing: Theme.Space.s) {
            TotalTile(label: L10n.text("common.today"), micros: todayValue(calendar), mark: "mark_day")
            TotalTile(label: L10n.text("apple.clienthomeview.this_week.8c4eef5a"), micros: weekValue(calendar), mark: "mark_week")
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
                // The page holds still while a day is being picked. A grid
                // scrubbed with a finger inside a page that scrolls under it
                // is two gestures fighting over one touch.
                onScrub: { pickingADay = $0 }
            )
            if calendar.isHistoryLocked {
                HistoryLockBanner(days: calendar.historyDays ?? 30)
            }
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }

    // MARK: - Figures

    /// The most recent day the grid carries.
    ///
    /// Taken from the calendar rather than from a day report, because the day
    /// report reads the local archive and the client has none. Same numbers,
    /// one source, no disagreement between the grid and the figure above it.
    private func todayValue(_ calendar: ActivityCalendar) -> UInt64 {
        days(calendar).last { $0.date == calendar.last }?.value ?? 0
    }

    private func weekValue(_ calendar: ActivityCalendar) -> UInt64 {
        days(calendar).suffix(7).reduce(0) { $0 + $1.value }
    }

    private func days(_ calendar: ActivityCalendar) -> [HeatCell] {
        // Column-major: the grid is seven rows of weeks, so reading rows in
        // order gives every Monday before any Tuesday. Sorting by the date
        // string is safe because it is `YYYY-MM-DD`.
        calendar.rows.flatMap { $0.compactMap { $0 } }.sorted { $0.date < $1.date }
    }
}

/// One large figure with its label. Two of these are the top of Home.
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
                    // A figure that moved should look like it moved.
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Top trailing, the way every other figure card on the client
            // carries its mark. See `ClientStatPanels`.
            FeatureMark(name: mark, size: 26)
                // The label beside it already says which period this is.
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.clienthomeview.0_1_at_api_list_price.c7adc814", "\(label)", "\(formatSpend(micros))"))
    }
}

/// A sentence the host sent about why this is not the answer that was asked
/// for, with a sign-in button when signing in is the fix.
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
