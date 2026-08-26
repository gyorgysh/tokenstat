// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Where the money went, across every device on the account.
///
/// **Three cuts, not five.** The Mac's Insights has Models, Projects, Harnesses
/// and Sessions because it reads this machine's archive, where all four exist.
/// The account holds day, source and model and nothing else: a project key
/// arrives as an opaque HMAC and a session id never leaves the machine it was
/// made on. So the phone offers Models, Tools and Days, and does not grow a
/// Projects tab that could only ever be empty. That is the privacy boundary
/// showing through the interface, which is the correct place for it to show.
struct ClientInsightsView: View {
    @Environment(ConnectivityModel.self) private var connectivity
    @State private var model = ClientInsightsModel()
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                cutPicker
                content
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            // Clear of the floating tab bar and of the search field that sits
            // in the same glass.
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        // Always, not based on size. `basedOnSize` stops a short screen from
        // bouncing, and a screen that cannot bounce cannot be pulled: the
        // refresh gesture quietly disappeared exactly when the page was empty,
        // which is when somebody most wants to pull it.
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await ClientRefresh.pull("insights") { await model.refresh() }
        }
        // On iOS 26 this lands in the bottom bar beside the tabs, which is the
        // half of the screen a thumb reaches. Long model identifiers are
        // exactly the thing worth filtering.
        .searchable(text: $search, prompt: "Filter \(model.cut.plural)")
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: - Pieces

    private var cutPicker: some View {
        SegmentedTabs(
            options: ClientInsightsModel.Cut.allCases,
            selection: $model.cut
        ) { $0.label }
        .onChange(of: model.cut) { _, _ in
            // Each cut keeps its own rows, so going back to one already seen is
            // instant and costs nothing. The host serves them all from one
            // cached series anyway.
            Task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let rows = model.rows(for: model.cut) {
            if rows.isEmpty {
                ClientEmptyState(
                    kind: .nothingYet,
                    title: "Nothing recorded yet",
                    message: "Sync a device and its usage shows up here.",
                    mark: "mark_insights"
                )
            } else {
                summary(rows)
                let shown = filtered(rows)
                if shown.isEmpty {
                    Text("Nothing matches \"\(search)\".")
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Space.s)
                } else {
                    // A share bar needs something to be a share of, and the
                    // largest row is a steadier reference than the total: with
                    // 40 models every bar would otherwise be a sliver.
                    let peak = shown.map(\.valueMicros).max() ?? 1
                    ForEach(shown) { row in
                        InsightRow(row: row, cut: model.cut, peak: peak)
                    }
                }
            }
        } else if model.isLoading {
            ClientWireframe.Rows(count: 5)
        } else if let message = model.errorMessage {
            ClientEmptyState(
                kind: model.needsSignIn ? .needsAccount : .unreachable,
                title: connectivity.isOffline ? "You are offline" : "Could not load your usage",
                message: connectivity.isOffline
                    ? "This updates by itself when the connection is back."
                    : FriendlyError.from(message).message,
                actionTitle: connectivity.isOffline ? nil : "Try again",
                actionIcon: .refresh,
                action: connectivity.isOffline ? nil : { Task { await model.refresh() } }
            )
        }
    }

    private func summary(_ rows: [Bucket]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ClientSectionTitle(title: "This period", mark: "mark_insights")
                .padding(.bottom, 4)
            Text(rows.totalValue.formatted)
                .font(ClientType.figure)
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("at list rates, across every device")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            // A remembered answer says so. The numbers are real, they are just
            // not this minute's, and a figure with no date is a quiet claim to
            // be current.
            if let age = model.ageDescription {
                Text(age)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func filtered(_ rows: [Bucket]) -> [Bucket] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return rows }
        return rows.filter { row in
            row.key.lowercased().contains(term)
                || model.cut.title(for: row.key).lowercased().contains(term)
        }
    }
}

/// One row of a breakdown: what it is, what it was worth, and how big a share
/// of the screen's largest row that is.
private struct InsightRow: View {
    let row: Bucket
    let cut: ClientInsightsModel.Cut
    let peak: Int64

    private var share: Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, Double(row.valueMicros) / Double(peak)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                if cut == .source {
                    HarnessMark(id: row.key, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(cut.title(for: row.key))
                        .font(ClientType.label.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Compact, because these are read at a glance and compared,
                    // not audited. "1.6B" beside a name is a size; the full
                    // ten digits is a wall the eye slides off.
                    Text("\(formatTokens(row.counters.total)) tokens, \(row.events.formatted()) events")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.s)
                Text(row.value.formatted)
                    .font(ClientType.rowFigure)
                    .foregroundStyle(Theme.accent)
            }
            // The bar is a comparison, not a second copy of the number, so it
            // carries no label of its own and is hidden from VoiceOver: the
            // figure beside it already says the amount.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.accent.opacity(0.12))
                    Capsule()
                        .fill(Theme.accent.opacity(0.55))
                        .frame(width: max(2, geo.size.width * share))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(Theme.Space.s)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(cut.title(for: row.key)), \(row.value.formatted) at list rates, "
                + "\(formatTokens(row.counters.total)) tokens"
        )
    }
}

/// The three breakdowns, their rows, and how old the numbers are.
///
/// One model rather than one per cut: they all come from the same cached series
/// on the host's side, so three models would be three views of one fetch
/// pretending to be independent.
@Observable
@MainActor
final class ClientInsightsModel {
    enum Cut: String, CaseIterable, Identifiable {
        case model
        case source
        case day

        var id: String { rawValue }

        var label: String {
            switch self {
            case .model: return "Models"
            // The Mac calls these harnesses and so does the CLI. A phone using
            // a third word for the same thing makes them look like two
            // different breakdowns.
            case .source: return "Harnesses"
            case .day: return "Days"
            }
        }

        /// Used in the search prompt, where "Filter Models" reads as a command
        /// and "Filter models" reads as a description of the field.
        var plural: String { label.lowercased() }

        /// What the host calls it.
        var wire: String { rawValue }

        /// A row's key as a person reads it. A harness id is a slug, and a day
        /// is an ISO date nobody says out loud.
        func title(for key: String) -> String {
            switch self {
            case .model: return key
            case .source: return harnessName(key)
            case .day: return shortDate(key)
            }
        }
    }

    var cut: Cut = .model

    /// Rows per cut. Nil means "not asked yet", which is not the same as an
    /// empty account and must not draw like one.
    private var cached: [Cut: [Bucket]] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The failure is a sign-in, so the empty state offers one instead of
    /// reading as a fault.
    private(set) var needsSignIn = false
    private var fetchedAt: Date?
    private var isStale = false

    func rows(for cut: Cut) -> [Bucket]? { cached[cut] }

    /// "As of 12 minutes ago", and only when it is worth saying.
    ///
    /// A fresh answer gets no line: dating something that is current is noise.
    /// A remembered one always gets one, because the alternative is a number
    /// that quietly claims to be now.
    var ageDescription: String? {
        guard isStale, let fetchedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let phrase = formatter.localizedString(for: fetchedAt, relativeTo: Date())
        return "The refresh did not go through. Showing what this device last fetched, \(phrase)."
    }

    func load() async {
        // Already have it. Switching back to a cut somebody just looked at
        // should be instant, and a refresh is one pull away.
        if cached[cut] != nil { return }
        await fetch()
    }

    func refresh() async {
        // Drop everything rather than the current cut alone: they are three
        // views of one series, and refreshing one of them would leave the other
        // two describing an older account.
        cached.removeAll()
        await fetch()
    }

    private func fetch() async {
        let asked = cut
        isLoading = true
        defer { isLoading = false }
        do {
            let report = try await Bridge.accountReport(group: asked.wire)
            // The reader moved on while this was in flight. Keep the rows, they
            // are still true, and do not touch what is on screen.
            cached[asked] = report.rows
            fetchedAt = report.fetchedAt
            isStale = report.stale
            if asked == cut {
                errorMessage = nil
                needsSignIn = false
            }
        } catch {
            guard asked == cut else { return }
            let text = error.localizedDescription
            needsSignIn = text.lowercased().contains("sign in")
            errorMessage = text
        }
    }

}

#endif
