// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

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
            case .source: return L10n.text("apple.clientinsightsview.coding_tools.6032f740")
            case .day: return L10n.text("apple.clientinsightsview.days.e08c0aa8")
            }
        }

        var plural: String { label.lowercased() }

        var wire: String { rawValue }

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
        if cached[cut] != nil { return }
        await fetch()
    }

    func refresh() async {
        synchronizeOwner()
        requests.removeAll()
        errors.removeAll()
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
