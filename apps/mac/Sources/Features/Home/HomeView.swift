// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The screen the window opens on.
///
/// Not Insights, and not an empty Workspaces pane on a fresh install. The
/// question people have when they open the app is what they have left before
/// they start, and that is a different question from what they spent last
/// month. This screen answers the first, Insights answers the second.
struct HomeView: View {
    @Bindable var model: HomeModel
    @Bindable var account: AccountModel
    /// Clicking a day on the heatmap goes to Insights filtered to it.
    var onSelectDay: ((HeatCell) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    Banner(text: message, severity: .warning)
                }

                profile
                activity

                // What is left of each plan. This is the "can I start another
                // session right now" question, which is why it is on the screen
                // that opens rather than under two report tables.
                PlanLimitsCard(
                    providers: model.planLimits,
                    isLoading: model.isLoadingLimits
                ) {
                    Task { await model.loadPlanLimits() }
                }

                if !model.planBySource.isEmpty {
                    PlanUsageCard(rows: model.planBySource)
                }
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.background)
        .task {
            await model.load()
            // A network call for one provider, so once on arrival rather than
            // on every refresh.
            if model.planLimits.isEmpty { await model.loadPlanLimits() }
        }
        .overlay {
            if model.isLoading && model.calendar == nil {
                ProgressView()
            }
        }
    }

    // MARK: - Profile

    private var profile: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Avatar(
                url: account.account?.avatar,
                handle: account.account?.handle,
                size: 52
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.account?.handle ?? "Not signed in")
                    .font(.system(size: 20, weight: .semibold))
                HStack(spacing: Theme.Space.xs) {
                    if let tier = account.account?.tier, !tier.isEmpty {
                        Text(tier.capitalized)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    Text(account.signedIn
                         ? (account.lastSyncSummary ?? "Everything stays on this machine until you sync.")
                         : "Working locally. Sign in to sync aggregate numbers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            // Streaks live beside the name rather than inside the activity
            // card: they are about the person, and the card below is about the
            // data.
            if let calendar = model.calendar {
                HStack(spacing: Theme.Space.l) {
                    streak(
                        "Streak",
                        "\(calendar.streakCurrent)",
                        note: calendar.streakCurrent == 1 ? "day" : "days",
                        tint: calendar.streakCurrent > 0 ? Theme.accent : .secondary
                    )
                    streak("Best", "\(calendar.streakBest)", note: "days")
                    streak("Active", "\(calendar.activeDays)", note: "days")
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activity: some View {
        Card(
            title: "Activity",
            subtitle: model.calendar.map {
                "\(formatTokens($0.total)) over \($0.activeDays) active days"
            } ?? "Input and output per day, cache excluded"
        ) {
            if let calendar = model.calendar {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.xl) {
                        Stat(label: "Today", value: formatTokens(model.todayTotal), size: 20)
                        Stat(label: "Last 7 days", value: formatTokens(model.weekTotal), size: 20)
                        if let busiest = calendar.busiest {
                            Stat(
                                label: "Busiest",
                                value: formatTokens(busiest.value),
                                note: busiest.date,
                                size: 20
                            )
                        }
                    }
                    HeatmapView(calendar: calendar, onSelect: onSelectDay)
                }
            } else {
                // A brand new install, not a failure. Saying so beats an empty
                // grid that looks like a year of doing nothing.
                EmptyHint(text: "Nothing scanned yet. Run a scan from Insights to fill this in.")
            }
        }
    }
}
