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
            WidthReader { width in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let message = model.errorMessage {
                        Banner(text: message, severity: .warning)
                    }

                    profile
                    activity

                    panels(width: width)

                    if limitsPending {
                        Text("Reading what each vendor says is left…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Space.s)
                    }
                }
            }
            // Tighter than the old inset all round. This screen is a stack of
            // cards, and a card already carries its own padding, so the gutter
            // outside it only has to separate the stack from the window edge.
            .padding(Theme.Space.s)
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
                HomeWarmupView()
            }
        }
    }

    // MARK: - Panels

    /// One panel per thing this machine can report, packed into columns.
    ///
    /// Columns rather than a grid. A grid gives every panel in a row the height
    /// of the tallest one in it, so a vendor with a single quota window sat in a
    /// box sized for the one beside it with three, and the screen was mostly
    /// empty card. Packed into columns each panel is exactly as tall as what it
    /// has to say, and the next panel starts where the last one ended.
    ///
    /// How many panels appear at all depends on what is installed. A vendor
    /// with nothing to report has no panel.
    @ViewBuilder
    private func panels(width: CGFloat) -> some View {
        let columns = packed(panels, into: columnCount(for: width))
        HStack(alignment: .top, spacing: Theme.Space.s) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(column) { panel in
                        view(for: panel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func view(for panel: HomePanel) -> some View {
        switch panel.kind {
        case let .limits(provider):
            PlanLimitPanel(
                provider: provider,
                isLoading: model.isLoadingLimits
            ) {
                Task { await model.loadPlanLimits() }
            }
        case let .planUsage(rows):
            PlanUsageCard(rows: rows)
        }
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

    /// Deal the panels out to the column that has the least in it so far.
    ///
    /// Rough by design: the weight is how many rows a panel draws, not its
    /// measured height, because measuring would mean laying the panels out
    /// twice. Filling left to right instead leaves one very long column beside
    /// three short ones whenever the biggest panel comes last.
    private func packed(_ panels: [HomePanel], into count: Int) -> [[HomePanel]] {
        var columns = Array(repeating: [HomePanel](), count: max(1, count))
        var filled = Array(repeating: 0, count: columns.count)
        for panel in panels {
            let target = filled.indices.min { filled[$0] < filled[$1] } ?? 0
            columns[target].append(panel)
            filled[target] += panel.weight
        }
        return columns.filter { !$0.isEmpty }
    }

    /// Whether to say the vendors are still being asked.
    ///
    /// Only while nothing has arrived. A panel that is already on screen says
    /// more than a sentence about a refresh in progress, and every panel
    /// carries its own spinner.
    private var limitsPending: Bool {
        model.isLoadingLimits && model.planLimits.isEmpty
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
                HStack(spacing: Theme.Space.s) {
                    Text(account.account?.title ?? "Not signed in")
                        .font(.system(size: 20, weight: .semibold))
                    if let tier = account.account?.tier, !tier.isEmpty {
                        // The glyph the profile page uses, not the written
                        // pill. Beside a 20pt name a crown reads as a mark on
                        // the person; a word in a capsule reads as a label
                        // stuck to them.
                        TierMark(tier: tier, size: 16)
                    }
                }
                // The handle, and nothing else. The privacy sentence that was
                // here is on the Account screen where someone reading about
                // privacy would go looking for it, and repeating it on the
                // screen you see every single launch turns a real guarantee
                // into a slogan.
                if let handle = account.account?.handle,
                   handle != account.account?.title
                {
                    Text("@\(handle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !account.signedIn {
                    Text("Working locally")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
        .padding(Theme.cardPadding)
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
                "\(formatSpend($0.total)) at list rates over \($0.activeDays) active days"
            } ?? "What each day was worth at list rates"
        ) {
            if let calendar = model.calendar {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    // Grouped at the leading edge rather than spread across
                    // the card. These three are meant to be read against each
                    // other, and a full-screen window put them a third of a
                    // metre apart.
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        Stat(
                            label: "Today",
                            value: model.todayValue.formatted,
                            size: 20,
                            expands: false
                        )
                        Stat(
                            label: "Last 7 days",
                            value: model.weekValue.formatted,
                            size: 20,
                            expands: false
                        )
                        if let busiest = calendar.busiest {
                            Stat(
                                label: "Busiest",
                                value: formatSpend(busiest.value),
                                note: busiest.date,
                                size: 20,
                                expands: false
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    HeatmapView(calendar: calendar, onSelect: onSelectDay)
                }
            } else if model.errorMessage != nil {
                // "We could not look" and "there is nothing" are different
                // answers, and telling someone with a full archive that they
                // have never scanned is the wrong one.
                EmptyHint(text: "The activity could not be read. See the message above.")
            } else if model.isLoading {
                EmptyHint(text: "Reading the archive…")
            } else {
                // A brand new install, not a failure. Saying so beats an empty
                // grid that looks like a year of doing nothing.
                EmptyHint(text: "Nothing scanned yet. Run a scan from Insights to fill this in.")
            }
        }
    }
}

private struct HomeWarmupView: View {
    @State private var animate = false

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent.opacity(0.55 + Double(index) * 0.15))
                        .frame(width: 9, height: CGFloat(18 + index * 10))
                        .scaleEffect(y: animate ? 1 : 0.55, anchor: .bottom)
                        .animation(
                            .easeInOut(duration: 0.7)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
                            value: animate
                        )
                }
            }
            Text("Warming up tokenstat")
                .font(.headline)
            Text("Opening your local archive…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .onAppear { animate = true }
        .transition(.opacity)
    }
}

/// One panel in the Home grid, and roughly how much room it wants.
///
/// The weight is a row count, not a height. It only has to be good enough to
/// decide which column the next panel should go in, and a row count is
/// something the data already knows without laying anything out.
private struct HomePanel: Identifiable {
    enum Kind {
        case limits(ProviderLimits)
        case planUsage([Bucket])
    }

    let kind: Kind

    var id: String {
        switch kind {
        case let .limits(provider): return "limits.\(provider.source)"
        case .planUsage: return "planUsage"
        }
    }

    var weight: Int {
        switch kind {
        // A header, then a bar per window, or a sentence where the bars would
        // have been.
        case let .limits(provider): return 1 + max(1, provider.windows.count)
        case let .planUsage(rows): return 1 + rows.count
        }
    }
}
