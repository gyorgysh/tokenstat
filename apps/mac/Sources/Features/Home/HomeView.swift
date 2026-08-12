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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hostReady) private var hostReady
    /// Clicking a day on the heatmap goes to Insights filtered to it.
    var onSelectDay: ((HeatCell) -> Void)?
    /// Where the account flow lives, for the sign-in prompt when All machines
    /// cannot be shown without one.
    var onShowAccount: () -> Void

    var body: some View {
        // Same chrome shape as Insights: a fixed bar above the scrolling
        // content. Refresh lives here, not in the window toolbar, so it is
        // not a floating mark over the heatmap.
        VStack(spacing: 0) {
            DetailChromeBar {
                if hostReady {
                    ToolbarIconButton(
                        systemImage: "arrow.clockwise",
                        help: "Re-read the archive for this device's activity and plan usage",
                        isBusy: model.isRefreshing,
                        isEnabled: !model.isLoading && !model.isRefreshing
                    ) {
                        Task { await model.refresh() }
                    }
                }
            }
            ScrollView {
                WidthReader { width in
                    // Lazy so plan panels below the fold are not laid out until
                    // they scroll in. The heatmap at the top is still always
                    // built, but it is a single Canvas now rather than hundreds
                    // of day views, so the stack cost is the panels, not the
                    // year of squares.
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if let message = model.errorMessage {
                            ErrorBanner(message: message)
                        }

                        profile
                        activity

                        panels(width: width)

                        if showsLimitsSyncHint {
                            limitsSyncHint
                        }

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
        }
        .background(Theme.background)
        // Launch flow: app splash (logo) → these wireframes with a light pulse
        // → real content fades in. The splash is owned by RootView.
        // Leaving the screen while a cell is under the pointer: the popover
        // must not stay pinned to a grid that is no longer there.
        .onDisappear { model.hover(day: nil) }
        .task {
            // Wait until the host splash has finished (or the host already
            // answers). Loading during splash races ensureHosted and can open
            // a second in-process archive.
            await Self.waitForHost()
            guard !Task.isCancelled else { return }
            // Archive first: heatmap and streaks. Vendor limits load after.
            await model.load()
        }
        .task {
            guard model.planLimits.isEmpty else { return }
            await Self.waitForHost()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.loadPlanLimits()
        }
        // App came back to the front: quiet re-read if the last load is old.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshIfStale() }
        }
        // Insights Scan wrote new events into the archive; Home must not keep
        // showing yesterday's heatmap until the window is reopened.
        .onReceive(NotificationCenter.default.publisher(for: .archiveDidChange)) { _ in
            Task { await model.load(quiet: true) }
        }
    }

    /// Spin until `info` answers, matching the splash's readiness gate without
    /// sharing a binding. Bounded so a dead host still shows empty Home.
    private static func waitForHost() async {
        for _ in 0..<100 {
            if (try? await Bridge.info()) != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    /// Whether the archive has yet to fill the profile streaks and heatmap.
    ///
    /// Per-section, not a full-window veil: plan panels have their own
    /// placeholder and load on a separate task.
    private var isWarming: Bool {
        model.isLoading && model.calendar == nil && model.errorMessage == nil
    }

    // MARK: - Panels

    /// One panel per thing this machine can report, in rows.
    ///
    /// Every panel in a row is the height of the tallest one in it. Packing
    /// them into columns instead let each be exactly as tall as its contents,
    /// which is the honest use of the space and reads as broken: cards on one
    /// line ending at four different heights look like a layout that failed
    /// rather than one that fitted. A row of equal boxes is worth the empty
    /// half of a card with one quota window in it.
    ///
    /// A row that does not fill up divides the full width between what it has,
    /// so a single panel left over spans the window rather than sitting in the
    /// first third with a hole beside it.
    ///
    /// How many panels appear at all depends on what is installed. A vendor
    /// with nothing to report has no panel.
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
                // The row takes the tallest panel's own height, and the panels
                // in it fill that. Without this the row would grow to whatever
                // height was going spare and every card with it.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A panel joins when its vendor or plan data arrives; the fade keeps
        // that from reading as a layout that just changed under the cursor.
        .animation(.easeOut(duration: 0.18), value: panels.count)
    }

    /// The panels dealt into rows of as many as the width fits.
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
                fillsHeight: true
            ) {
                Task { await model.loadPlanLimits() }
            }
        case let .planUsage(rows):
            PlanUsageCard(rows: rows, fillsHeight: true)
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

    // MARK: - The plan limits the phone cannot see

    /// Dismissed for good, per person rather than per window.
    ///
    /// A suggestion that comes back after every launch is not a suggestion, it
    /// is an advert. Somebody who decided their quota numbers are not leaving
    /// this Mac has answered the question, and the answer is kept.
    @AppStorage("home.limitsSyncHint.dismissed") private var limitsSyncHintDismissed = false

    /// Whether to offer the setting that would put these numbers on the phone.
    ///
    /// Only with something to share and somewhere to share it. Signed out, the
    /// setting does nothing and the sentence would be a puzzle; with no panels
    /// on screen there is nothing to talk about yet, and a hint that appears
    /// before the first reading arrives looks like an error.
    private var showsLimitsSyncHint: Bool {
        !limitsSyncHintDismissed
            && account.signedIn
            && !account.limitsSyncEnabled
            && !PlanLimits.visible(model.planLimits).isEmpty
    }

    /// A line offering the setting, and the way out of being offered it.
    ///
    /// It says what the phone shows today rather than naming the switch,
    /// because the reason to want this is the phone being empty. The button
    /// goes to Account, where the toggle and its own explanation of what leaves
    /// the machine both live: flipping it from here would turn something off by
    /// default into something that happened because a card was in the way.
    private var limitsSyncHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your phone cannot see these numbers")
                    .font(.callout.weight(.medium))
                Text("Share plan limits with my devices posts how full each window is, "
                    + "so the phone still shows what is left while this Mac is asleep. "
                    + "Percentages and reset times only, never a credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Open Account") { onShowAccount() }
                .buttonStyle(SecondaryButtonStyle())
            Button {
                limitsSyncHintDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Do not offer this again")
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Space.s)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .transition(.opacity)
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
                // Pulsing wireframe in the same three slots the streaks will
                // fill, so the name does not shift when numbers arrive.
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
                        "Streak",
                        "\(calendar.streakCurrent)",
                        note: calendar.streakCurrent == 1 ? "day" : "days",
                        tint: calendar.streakCurrent > 0 ? Theme.accent : .secondary
                    )
                    streak("Best", "\(calendar.streakBest)", note: "days")
                    streak("Active", "\(calendar.activeDays)", note: "days")
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
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

    /// One panel's worth of room while the vendors are still being asked.
    ///
    /// A panel rather than a sentence about waiting. How many there will be
    /// depends on what is installed, so this claims one and no more.
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

    /// The activity card's own layout, with nothing in it yet.
    ///
    /// Same shapes and same heights as the real thing, so the card does not
    /// jump when the archive answers and the heatmap takes its place. Sharp,
    /// not blurred: the real card fades in over it.
    private var activityPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        bar(width: 54, height: 9, phase: Double(index) * 0.1)
                        bar(width: 88, height: 18, phase: Double(index) * 0.1 + 0.05)
                    }
                }
                Spacer(minLength: 0)
            }
            // The height the heatmap reserves for its grid, so the card is the
            // size it will still be a moment later.
            bar(width: nil, height: 187, phase: 0.12)
        }
        .transition(.opacity)
    }

    /// Home's own name for the shared placeholder bar, so the call sites below
    /// read the way they did before it moved into `Skeleton`.
    private func bar(width: CGFloat?, height: CGFloat, phase: Double = 0) -> some View {
        Skeleton.Bar(width: width, height: height, phase: phase)
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

    /// Switches what the grid counts.
    ///
    /// On the card rather than on the screen, because it changes this card and
    /// nothing else. Today and Last 7 days beside the grid stay local: they are
    /// "what have I spent here", which is the question Home opens with.
    private var scopePicker: some View {
        let binding = Binding<ActivityScope>(
            get: { model.scope },
            set: { new in
                Task { await model.setScope(new) }
            }
        )
        return SegmentedCapsulePicker(
            options: ActivityScope.allCases.map { (value: $0, label: $0.label, symbol: $0.symbol) },
            selection: binding
        )
        // Comfortable for the two labels, not the whole header: 220 squeezed
        // them, and the full width was more than a two-option switch needs.
        .frame(width: 280, alignment: .trailing)
    }

    /// What the figures under the title are counting, said plainly.
    ///
    /// Naming the scope matters here more than anywhere else on the screen. The
    /// same number means two different things depending on whether it is one
    /// laptop or every machine, and a grid that quietly fell back to local
    /// while the control still said All machines would be reporting the wrong
    /// one of the two.
    private var activitySubtitle: String {
        guard let calendar = model.calendar else {
            return "What each day was worth at list rates"
        }
        let base = "\(formatSpend(calendar.total)) at list rates over \(calendar.activeDays) active days"
        let source = model.deliveredScope == .allMachines
            ? ", across every device on your account"
            : ", on this device"
        if let notice = model.scopeNotice, !model.needsAccountSignIn {
            return base + source + ". " + notice
        }
        return base + source
    }

    @ViewBuilder
    private var activity: some View {
        Card(
            title: "Activity",
            subtitle: activitySubtitle,
            accessory: AnyView(scopePicker)
        ) {
            if let calendar = model.calendar {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if model.needsAccountSignIn {
                        accountSignInPrompt
                    }
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
                    HeatmapView(
                        calendar: calendar,
                        onSelect: onSelectDay,
                        onHover: { model.hover(day: $0) }
                    )
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
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
                EmptyHint(
                    symbol: "sparkles",
                    title: "Nothing scanned yet",
                    text: "Run a scan from Insights and your first heatmap will fill this grid."
                )
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.calendar != nil)
    }

    /// The account grid fell back because a sign-in is missing or stale.
    ///
    /// The heatmap below is this machine's own year, and saying that in the
    /// subtitle is not enough: the fix lives on the Account screen, so offer
    /// the jump from the card that failed rather than quoting `tokenstat login`
    /// at somebody who is already sitting in the app.
    private var accountSignInPrompt: some View {
        HStack(spacing: Theme.Space.s) {
            Label(
                "All devices needs your tokenstat.ai account",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer(minLength: Theme.Space.s)

            Button {
                account.signIn()
                onShowAccount()
            } label: {
                Text(account.signedIn ? "Reconnect" : "Sign in")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .padding(Theme.Space.m)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// Hold a card's own shape while it waits for its first answer.
///
/// One panel in the Home grid.
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
}
