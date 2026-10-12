// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

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
            case .model: return L10n.text("apple.clientinsightsview.models.d17d2d78")
            // Same label as the Mac Insights tab. A different word here
            // makes the two screens look like different breakdowns.
            case .source: return L10n.text("apple.clientinsightsview.coding_tools.6032f740")
            case .day: return L10n.text("apple.clientinsightsview.days.e08c0aa8")
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
            case .day:
                return InsightDayAxis.title(key)
            }
        }
    }

    var cut: Cut = .model

    /// Rows per cut. Nil means "not asked yet", which is not the same as an
    /// empty account and must not draw like one.
    private var cached: [Cut: AccountReport] = [:]
    private var requests: [Cut: UUID] = [:]
    private var errors: [Cut: String] = [:]
    private var owner: WorkReference.Scope?
    var isLoading: Bool { requests[cut] != nil }
    var errorMessage: String? { errors[cut] }
    var needsSignIn: Bool { errorMessage?.lowercased().contains("sign in") == true }

    func rows(for cut: Cut) -> [Bucket]? {
        guard owner == WorkSessionContext.shared.scope else { return nil }
        return cached[cut]?.rows
    }

    private func synchronizeOwner() {
        let scope = WorkSessionContext.shared.scope
        guard owner != scope else { return }
        owner = scope
        cached.removeAll()
        requests.removeAll()
        errors.removeAll()
    }

    /// "As of 12 minutes ago", and only when it is worth saying.
    ///
    /// A fresh answer gets no line: dating something that is current is noise.
    /// A remembered one always gets one, because the alternative is a number
    /// that quietly claims to be now.
    var ageDescription: String? {
        guard owner == WorkSessionContext.shared.scope, let report = cached[cut], report.stale else { return nil }
        let fetchedAt = report.fetchedAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let phrase = formatter.localizedString(for: fetchedAt, relativeTo: Date())
        return L10n.text("apple.clientinsightsview.the_refresh_did_not_go_through_showing_wha.790fad9d", "\(phrase)")
    }

    func load() async {
        synchronizeOwner()
        // Already have it. Switching back to a cut somebody just looked at
        // should be instant, and a refresh is one pull away.
        if cached[cut] != nil { return }
        await fetch()
    }

    func refresh() async {
        synchronizeOwner()
        requests.removeAll()
        errors.removeAll()
        // Drop everything rather than the current cut alone: they are three
        // views of one series, and refreshing one of them would leave the other
        // two describing an older account.
        cached.removeAll()
        await fetch()
    }

    private func fetch() async {
        guard !Task.isCancelled, let owner, owner == WorkSessionContext.shared.scope else { return }
        let asked = cut
        let request = UUID()
        requests[asked] = request
        defer { if requests[asked] == request { requests[asked] = nil } }
        do {
            let report = try await Bridge.accountReport(group: asked.wire)
            guard !Task.isCancelled, self.owner == owner, owner == WorkSessionContext.shared.scope,
                  requests[asked] == request else { return }
            cached[asked] = report
            errors[asked] = nil
        } catch {
            guard !Task.isCancelled, self.owner == owner, owner == WorkSessionContext.shared.scope,
                  requests[asked] == request else { return }
            errors[asked] = error.localizedDescription
        }
    }
}
