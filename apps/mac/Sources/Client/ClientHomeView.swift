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
    @State private var model = HomeModel()
    /// The day whose detail sheet is open. A sheet rather than the Mac's hover
    /// popover, because a finger has no hover.
    @State private var selectedDay: HeatCell?
    /// A finger is holding the heatmap, so this page does not scroll.
    @State private var pickingADay = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                greeting
                if let calendar = model.calendar {
                    totals(calendar)
                    heatmapCard(calendar)
                    // What is left, on the screen that opens, next to what was
                    // spent. See `ClientLimitsCard` for why this is not a tab.
                    ClientLimitsCard(
                        providers: model.planLimits,
                        isLoading: model.isLoadingLimits
                    )
                    if let notice = model.scopeNotice {
                        NoticeCard(text: notice, showSignIn: model.needsAccountSignIn)
                    }
                } else if model.isLoading {
                    // Shaped like what is coming, so nothing moves when it
                    // lands. See `ClientWireframe`.
                    ClientWireframe.Totals()
                    ClientWireframe.Heatmap()
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
                        title: connectivity.isOffline ? "You are offline" : "Could not load your activity",
                        message: connectivity.isOffline
                            ? "This updates by itself when the connection is back."
                            : FriendlyError.from(message).message,
                        actionTitle: connectivity.isOffline ? nil : "Try again",
                        action: connectivity.isOffline ? nil : { Task { await model.refresh() } }
                    )
                } else {
                    ClientEmptyState(
                        kind: .nothingYet,
                        title: "Nothing recorded yet",
                        message: "Sync a device and its usage shows up here."
                    )
                }
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
        .refreshable {
            await ClientRefresh.pull("home") { await model.refresh() }
        }
        .task {
            // Account scope always. There is no local archive to fall back to,
            // and asking for one would only produce a refusal to render.
            model.scope = .allMachines
            await model.load()
            // After the grid, not beside it. The heatmap is what the screen is
            // for and it should not queue behind a provider read that has
            // nothing to say yet on a phone.
            await model.loadPlanLimits()
        }
        // The connection came back. Fetch now rather than leaving somebody
        // looking at an offline card on a phone that is plainly online again,
        // which is the moment they would otherwise force-quit the app.
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await model.refresh() }
        }
        .sheet(item: $selectedDay) { day in
            DayDetailSheet(day: day)
        }
    }

    // MARK: - Pieces

    /// Same line the website and the Mac home use: a local-clock phrase,
    /// the first name, and the star / crown / badge next to it.
    @ViewBuilder
    private var greeting: some View {
        if let name = account.account?.title, !name.isEmpty {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Text(HomeGreeting.line(name: name, hasHistory: hasHistory))
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

    private var hasHistory: Bool {
        (model.calendar?.activeDays ?? 0) > 0
    }

    private func totals(_ calendar: ActivityCalendar) -> some View {
        HStack(spacing: Theme.Space.s) {
            TotalTile(label: "Today", micros: todayValue(calendar))
            TotalTile(label: "This week", micros: weekValue(calendar))
        }
    }

    private func heatmapCard(_ calendar: ActivityCalendar) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(ClientType.sectionTitle)
                Spacer()
                Text("\(calendar.activeDays) active days")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            PhoneHeatmap(
                calendar: calendar,
                onSelect: { day in selectedDay = day },
                // The page holds still while a day is being picked. A grid
                // scrubbed with a finger inside a page that scrolls under it
                // is two gestures fighting over one touch.
                onScrub: { pickingADay = $0 }
            )
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

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(formatSpend(micros)) at list rates")
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
                Button("Sign in") { account.signIn() }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }
}

#endif
