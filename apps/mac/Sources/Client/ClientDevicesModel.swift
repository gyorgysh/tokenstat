// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

#if !os(macOS) || TOKENSTAT_TEST

/// What each device contributed, fetched once and kept.
///
/// One request per device on the host's side, so this is asked for when the
/// screen opens and not warmed behind one somebody might never visit.
///
/// The window follows the account tier's history depth: free 30 days,
/// supporter a year, patron all-time. Asking every tier for a month left a
/// paid account looking like it only spent a slice of what it really had.
@Observable
@MainActor
final class ClientDevicesModel {
    private(set) var rows: [MachineUsage] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private var loadedIDs: Set<String> = []
    private var loadedDays: Int = 0
    private var loadedScope: WorkReference.Scope?
    private var generation = UUID()

    func usage(for machine: Machine) -> MachineUsage? {
        guard let id = machine.machineID else { return nil }
        return rows.first { $0.machine == id }
    }

    var total: Int64 { rows.reduce(0) { $0.saturatingAdd($1.valueMicros) } }

    var windowDescription: String {
        guard let days = rows.first?.days else { return L10n.text("apple.clientdevicesview.across_this_account.2a6688f7") }
        return L10n.text("apple.clientdevicesview.share_of_0_at_api_list_price.3aad6111", "\(DeviceHistory.windowPhrase(days: days))")
    }

    func load(machines: [Machine], days: Int = 30, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let owner = WorkSessionContext.shared.scope
        if owner != loadedScope {
            rows = []
            loadedIDs = []
            loadedScope = owner
        }
        let request = UUID()
        generation = request
        // Hosts only. Clients never upload an archive, so asking for their
        // spend only produces $0 rows the UI does not show.
        let ids = machines.filter(\.isHost).compactMap(\.machineID)
        guard owner != nil, !ids.isEmpty else {
            isLoading = false
            rows = []
            loadedIDs = []
            loadedDays = days
            errorMessage = nil
            return
        }
        if !force, Set(ids) == loadedIDs, loadedDays == days, !rows.isEmpty {
            isLoading = false
            return
        }
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let answer = try await Bridge.machineUsage(machines: ids, days: days)
            guard !Task.isCancelled, generation == request, owner == WorkSessionContext.shared.scope else { return }
            rows = answer
            loadedIDs = Set(ids)
            loadedDays = days
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == request, owner == WorkSessionContext.shared.scope else { return }
            // The device list itself came from the account and is already on
            // screen. This failure costs the figures beside the names, which is
            // a line of explanation rather than an empty screen.
            errorMessage = L10n.text("apple.clientdevicesview.could_not_work_out_what_each_device_spent.908fa25b", "\(error.localizedDescription)")
        }
    }
}

#endif
