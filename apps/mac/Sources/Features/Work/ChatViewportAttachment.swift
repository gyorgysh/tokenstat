// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreGraphics
import Observation

struct ChatViewportAttachmentIdentity: Hashable {
    let reporter: UUID
    let scroll: ObjectIdentifier
    let window: ObjectIdentifier
}

/// UIKit supplies eligibility on its next main-queue turn. Only a change in
/// actual attachment restarts placement; routine layout geometry stays local.
@MainActor
@Observable
final class ChatViewportAttachment {
    private(set) var identity: ChatViewportAttachmentIdentity?
    @ObservationIgnored private var reporter: UUID?
    @ObservationIgnored private var readinessIdentity: ChatViewportAttachmentIdentity?
    @ObservationIgnored private var readinessRemaining = 0
    @ObservationIgnored private var readinessTicket: UUID?

    func register(reporter: UUID) {
        if self.reporter != reporter { resetReadiness() }
        self.reporter = reporter
    }

    @discardableResult
    func publish(_ identity: ChatViewportAttachmentIdentity?, reporter: UUID) -> Bool {
        guard self.reporter == reporter, identity == nil || identity?.reporter == reporter,
              self.identity != identity else { return false }
        self.identity = identity
        if identity != nil { resetReadiness() }
        return true
    }

    @discardableResult
    func retire(reporter: UUID) -> Bool {
        guard self.reporter == reporter else { return false }
        self.reporter = nil
        resetReadiness()
        let changed = identity != nil
        identity = nil
        return changed
    }

    func resetReadiness() { readinessIdentity = nil; readinessRemaining = 0; readinessTicket = nil }

    func beginReadiness(_ identity: ChatViewportAttachmentIdentity) -> UUID? {
        guard reporter == identity.reporter, readinessIdentity != identity else { return nil }
        readinessIdentity = identity
        readinessRemaining = 12
        let ticket = UUID()
        readinessTicket = ticket
        return ticket
    }

    func takeReadinessAttempt(_ identity: ChatViewportAttachmentIdentity, ticket: UUID) -> Bool {
        guard reporter == identity.reporter, readinessIdentity == identity,
              readinessTicket == ticket, readinessRemaining > 0 else { return false }
        readinessRemaining -= 1
        return true
    }

    @discardableResult
    func finishReadiness(ticket: UUID) -> Bool {
        guard readinessTicket == ticket else { return false }
        readinessTicket = nil
        return true
    }

    static func isVisible(usable: CGRect, window: CGRect, ancestorsVisible: Bool) -> Bool {
        guard ancestorsVisible, usable.width > 0, usable.height > 0,
              usable.minX.isFinite, usable.minY.isFinite,
              usable.width.isFinite, usable.height.isFinite else { return false }
        let visible = usable.intersection(window)
        return !visible.isNull && visible.width > 0 && visible.height > 0
    }

    static func isCurrentPresentation(visible: Bool, layout: UInt64, currentLayout: UInt64,
                                     rootCover: WorkReference? = nil, currentCover: WorkReference? = nil,
                                     scope: WorkReference.Scope? = nil) -> Bool {
        guard visible else { return false }
        if let rootCover { return rootCover.scope == scope && rootCover == currentCover }
        return layout == currentLayout
    }
}
