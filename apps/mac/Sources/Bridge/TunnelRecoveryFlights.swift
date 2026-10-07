// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Share overlapping recovery work. Returning to the foreground can supersede
/// a soft check without waiting for a suspended transport's timeout.
actor TunnelRecoveryFlights {
    enum Urgency: Int, Sendable { case soft, foreground, reconnect }
    private struct Flight {
        let ticket: UUID
        let urgency: Urgency
        let task: Task<Void, Never>
    }
    private var flights: [Data: Flight] = [:]
    func run(owner: Data, urgency: Urgency, operation: @escaping @Sendable () async -> Void) async {
        guard !Task.isCancelled else { return }
        let flight: Flight
        if let existing = flights[owner], existing.urgency.rawValue >= urgency.rawValue {
            flight = existing
        } else {
            flights[owner]?.task.cancel()
            flight = Flight(ticket: UUID(), urgency: urgency, task: Task { await operation() })
            flights[owner] = flight
        }
        await flight.task.value
        if flights[owner]?.ticket == flight.ticket { flights.removeValue(forKey: owner) }
    }
}
