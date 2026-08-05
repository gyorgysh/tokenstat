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
                        panelPlaceholder
                    }
                }
            }
            // Tighter than the old inset all round. This screen is a stack of
            // cards, and a card already carries its own padding, so the gutter
            // outside it only has to separate the stack from the window edge.
            .padding(Theme.Space.s)
        }
        .background(Theme.background)
        .overlay {
            if isWarming {
                // The mark alone, over the blurred cards. No panel, no
                // headline, no sentence about opening an archive: by the time
                // anyone finishes reading one, the data is already there.
                LogoMark(size: 34, animated: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: isWarming)
        .task {
            // Started together, not one after the other. The vendor limits
            // include a network call for one provider, and waiting for the
            // archive first only meant the panels arrived a round trip later
            // than they had to. They land in whichever order they finish.
            async let archive: Void = model.load()
            // Once on arrival rather than on every refresh.
            if model.planLimits.isEmpty { await model.loadPlanLimits() }
            await archive
        }
    }

    /// Whether the archive has yet to say anything.
    ///
    /// The screen is drawn either way. There is no separate launch screen: the
    /// cards are the launch screen, quiet until they have something to say.
    private var isWarming: Bool {
        model.isLoading && model.calendar == nil && model.errorMessage == nil
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
                        view(for: panel).modifier(SteppedHeight())
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
            if isWarming {
                // The same three slots the streaks will fill, so the name
                // beside them does not shift sideways when they arrive.
                HStack(spacing: Theme.Space.l) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            bar(width: 44, height: 8)
                            bar(width: 62, height: 20)
                        }
                    }
                }
                .warming(true)
            } else if let calendar = model.calendar {
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

    /// One panel's worth of room while the vendors are still being asked.
    ///
    /// A panel rather than a sentence about waiting. How many there will be
    /// depends on what is installed, so this claims one and no more.
    private var panelPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            bar(width: 96, height: 11)
            bar(width: nil, height: 10)
            bar(width: nil, height: 10)
        }
        .padding(Theme.cardPadding)
        .frame(width: .panelWidth, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .warming(true)
    }

    /// The activity card's own layout, with nothing in it yet.
    ///
    /// Same shapes and same heights as the real thing, so the card does not
    /// jump when the archive answers and the heatmap takes its place.
    private var activityPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        bar(width: 54, height: 9)
                        bar(width: 88, height: 18)
                    }
                }
                Spacer(minLength: 0)
            }
            // The height the heatmap reserves for its grid, so the card is the
            // size it will still be a moment later.
            bar(width: nil, height: 187)
        }
        .warming(true)
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.border)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
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
                activityPlaceholder
            } else {
                // A brand new install, not a failure. Saying so beats an empty
                // grid that looks like a year of doing nothing.
                EmptyHint(text: "Nothing scanned yet. Run a scan from Insights to fill this in.")
            }
        }
    }
}

/// Round a panel's height up to the next hundred points, to a ceiling of four.
///
/// Packed columns put panels of wildly different heights beside each other: a
/// vendor with one quota window next to one with three left a card barely
/// taller than its own title. Snapping to a ladder makes them read as a set
/// without stretching a short card the full height of the tallest.
///
/// The measurement is of the panel as laid out, and the floor only ever grows
/// it, so a panel measured at 130 settles at 200 and stays there. A panel
/// taller than the ceiling keeps its own height: the ladder is a floor, never
/// a limit on what a card may say.
private struct SteppedHeight: ViewModifier {
    @State private var measured: CGFloat = 0

    private static let step: CGFloat = 100
    private static let ceiling: CGFloat = 400

    private var floor: CGFloat {
        guard measured > 0 else { return Self.step }
        return min(Self.ceiling, (measured / Self.step).rounded(.up) * Self.step)
    }

    func body(content: Content) -> some View {
        content
            .frame(minHeight: floor, alignment: .top)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measured = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in measured = height }
                }
            )
    }
}

/// Hold a card's own shape while it waits for its first answer.
///
/// Blurred and dimmed rather than replaced by something that spins. The screen
/// people are waiting for is already the best thing to show them: it says how
/// much is coming and where each piece will be, and it does not put a brand
/// animation between them and their own data. Nothing here moves, and nothing
/// here is tinted: a launch is not an event worth celebrating.
private struct Warming: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 7 : 0)
            .opacity(active ? 0.45 : 1)
            .allowsHitTesting(!active)
            // Short, and only on the way out. Arriving data should look like
            // the screen coming into focus, not like a transition playing.
            .animation(.easeOut(duration: 0.22), value: active)
    }
}

extension View {
    fileprivate func warming(_ active: Bool) -> some View {
        modifier(Warming(active: active))
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
