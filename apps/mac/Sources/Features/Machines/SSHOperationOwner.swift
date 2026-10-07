// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// One library's login lifetime. Geometry changes never change this ticket;
/// leaving A and later returning to A creates a different lifetime.
@MainActor
final class SSHOperationOwner {
    struct Ticket: Equatable, Sendable {
        let scope: WorkReference.Scope
        let generation: UInt64
    }
    private var binding: Ticket?
    private var retired = false

    init(scope: WorkReference.Scope? = nil) {
        if let scope {
            binding = Ticket(scope: scope, generation: WorkSessionContext.shared.generation)
        }
    }

    func claim() -> Ticket? {
        guard !retired, !Task.isCancelled, let scope = WorkSessionContext.shared.scope else { return nil }
        let now = Ticket(scope: scope, generation: WorkSessionContext.shared.generation)
        if binding == nil { binding = now }
        return binding == now ? now : nil
    }

    func permits(_ ticket: Ticket) -> Bool {
        !retired && !Task.isCancelled && binding == ticket
            && WorkSessionContext.shared.scope == ticket.scope
            && WorkSessionContext.shared.generation == ticket.generation
    }

    var captured: Ticket? { binding }

    func retire() { retired = true }
}

extension SSHHost {
    /// Labels and colors may change during a connection. Its destination and
    /// trusted identity must stay pinned to what the person approved.
    func sameConnectionTarget(as other: SSHHost) -> Bool {
        id == other.id && hostname == other.hostname && port == other.port
            && username == other.username && jumpHostID == other.jumpHostID
            && hostKeys == other.hostKeys && credentialID == other.credentialID
    }
}
