// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatViewportAttachment.swift ChatViewportContinuity.swift
// ChatReadingPosition.swift ChatReadingStore.swift WorkReference.swift.
import Foundation
import CoreGraphics

@main struct ChatViewportAttachmentTests {
    @MainActor static func main() {
        let scrollA = NSObject(), scrollB = NSObject(), window = NSObject()
        let tokenA = UUID(), tokenB = UUID()
        let a = ChatViewportAttachmentIdentity(reporter: tokenA,
            scroll: ObjectIdentifier(scrollA), window: ObjectIdentifier(window))
        let b = ChatViewportAttachmentIdentity(reporter: tokenB,
            scroll: ObjectIdentifier(scrollB), window: ObjectIdentifier(window))
        let attachment = ChatViewportAttachment()
        attachment.register(reporter: tokenA)
        precondition(attachment.identity == nil)
        precondition(attachment.publish(a, reporter: tokenA))
        for _ in 0..<100 {
            precondition(!attachment.publish(a, reporter: tokenA), "layout without attachment change cannot restart placement")
        }
        attachment.register(reporter: tokenB)
        precondition(!attachment.publish(a, reporter: tokenA), "queued predecessor cannot reactivate")
        precondition(!attachment.retire(reporter: tokenA), "old dismantle cannot retire successor")
        precondition(attachment.publish(b, reporter: tokenB))
        precondition(attachment.retire(reporter: tokenB) && attachment.identity == nil)
        precondition(!attachment.publish(b, reporter: tokenB), "late detached callback cannot reactivate")
        attachment.register(reporter: tokenA)
        precondition(attachment.publish(a, reporter: tokenA), "late real attachment wakes the destination")

        attachment.publish(nil, reporter: tokenA)
        let firstProbe = attachment.beginReadiness(a)!
        for _ in 0..<12 { precondition(attachment.takeReadinessAttempt(a, ticket: firstProbe)) }
        precondition(!attachment.takeReadinessAttempt(a, ticket: firstProbe), "visibility readiness has a finite budget")
        for _ in 0..<100 {
            precondition(attachment.beginReadiness(a) == nil, "ordinary hidden layout frames cannot restart a spent episode")
        }
        let movedWindow = NSObject()
        let moved = ChatViewportAttachmentIdentity(reporter: tokenA,
            scroll: ObjectIdentifier(scrollA), window: ObjectIdentifier(movedWindow))
        let movedProbe = attachment.beginReadiness(moved)!
        precondition(!attachment.takeReadinessAttempt(a, ticket: firstProbe), "late retries cannot spend the replacement's budget")
        precondition(attachment.takeReadinessAttempt(moved, ticket: movedProbe))
        attachment.resetReadiness()
        let retriedProbe = attachment.beginReadiness(moved)!
        precondition(retriedProbe != movedProbe, "a new scene/appearance activity may retry the same attachment")
        precondition(attachment.publish(moved, reporter: tokenA))
        // Eligible and hidden callbacks can both arrive before the old
        // probe's next wake. Its delayed cleanup cannot clear the successor.
        attachment.publish(nil, reporter: tokenA)
        let successorProbe = attachment.beginReadiness(moved)!
        precondition(!attachment.finishReadiness(ticket: retriedProbe))
        precondition(!attachment.takeReadinessAttempt(moved, ticket: retriedProbe))
        for _ in 0..<12 { precondition(attachment.takeReadinessAttempt(moved, ticket: successorProbe)) }
        precondition(!attachment.takeReadinessAttempt(moved, ticket: successorProbe))
        precondition(attachment.finishReadiness(ticket: successorProbe))
        precondition(attachment.beginReadiness(moved) == nil, "finishing a spent episode does not replenish it")
        attachment.register(reporter: tokenB)
        precondition(attachment.beginReadiness(moved) == nil && !attachment.takeReadinessAttempt(moved, ticket: successorProbe))
        let bProbe = attachment.beginReadiness(b)!
        attachment.retire(reporter: tokenB)
        precondition(!attachment.takeReadinessAttempt(b, ticket: bProbe), "a retired reporter cannot continue readiness")

        let bounds = CGRect(x: 0, y: 0, width: 951, height: 669)
        let usable = CGRect(x: 312, y: 135, width: 523, height: 306)
        precondition(ChatViewportAttachment.isVisible(usable: usable, window: bounds, ancestorsVisible: true))
        precondition(!ChatViewportAttachment.isVisible(usable: usable, window: bounds, ancestorsVisible: false))
        precondition(!ChatViewportAttachment.isVisible(usable: usable.offsetBy(dx: -1000, dy: 0), window: bounds, ancestorsVisible: true))
        precondition(!ChatViewportAttachment.isVisible(usable: .zero, window: bounds, ancestorsVisible: true))
        precondition(!ChatViewportAttachment.isVisible(usable: CGRect(x: CGFloat.nan, y: 0, width: 3, height: 3), window: bounds, ancestorsVisible: true))

        let viewport = ChatViewportContinuity(), front = UUID(), transient = UUID()
        let mark = ChatReadingMark(eventID: "text-s12", offset: 0.2, updatedAt: Date())
        precondition(viewport.beginPlacement(generation: 1, owner: front, eligible: true))
        viewport.record(.away(mark), generation: 1, owner: front)
        let unchangedVacancy = viewport.vacancy
        precondition(!viewport.beginPlacement(generation: 1, owner: transient, eligible: false))
        precondition(!viewport.release(generation: 1, owner: transient))
        precondition(viewport.vacancy == unchangedVacancy && viewport.owns(generation: 1, owner: front))
        precondition(viewport.completePlacement(generation: 1, owner: front))
        precondition(viewport.isPlaced(generation: 1, owner: front), "unattached/hidden transient cannot block reveal")

        // A briefly eligible transient can disappear while the front remains
        // attached. Only vacancy wakes the front; its own acquisition is quiet.
        precondition(viewport.beginPlacement(generation: 1, owner: transient, eligible: true))
        precondition(viewport.vacancy == unchangedVacancy)
        precondition(viewport.release(generation: 1, owner: transient))
        precondition(viewport.vacancy == unchangedVacancy + 1 && viewport.mark(generation: 1) == mark)
        let wake = viewport.vacancy
        precondition(viewport.beginPlacement(generation: 1, owner: front, eligible: true))
        precondition(viewport.vacancy == wake && viewport.completePlacement(generation: 1, owner: front))

        for successorFirst in [false, true] {
            var current = front
            for _ in 0..<30 {
                let successor = UUID()
                if !successorFirst { precondition(viewport.release(generation: 1, owner: current)) }
                let beforeClaim = viewport.vacancy
                precondition(viewport.beginPlacement(generation: 1, owner: successor, eligible: true))
                precondition(!viewport.release(generation: 1, owner: current))
                precondition(viewport.vacancy == beforeClaim && viewport.mark(generation: 1) == mark)
                precondition(viewport.completePlacement(generation: 1, owner: successor))
                current = successor
            }
            viewport.beginPlacement(generation: 1, owner: front, eligible: true)
        }

        // Latest retires old reading intent before a destination attaches;
        // obsolete selection choices cannot clear a later generation's place.
        viewport.release(generation: 1, owner: front)
        viewport.chooseLatest(generation: 0)
        precondition(viewport.mark(generation: 1) == mark)
        viewport.chooseLatest(generation: 1)
        precondition(viewport.mark(generation: 1) == nil)
        precondition(viewport.beginPlacement(generation: 1, owner: front, eligible: true))
        precondition(viewport.mark(generation: 1) == nil)
        let waiting = UUID(), latest = UUID()
        precondition(!viewport.canPlace(generation: 1, currentGeneration: 1,
            owner: front, ticket: waiting, currentTicket: latest))

        let suite = "ChatViewportAttachmentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatReadingStore(defaults: defaults)
        let reference = WorkReference(scope: .local(installationID: "fixture"), hostIdentity: "mac",
            workspaceID: "p", kind: .conversation, itemID: "b")
        precondition(ChatViewportAttachment.isCurrentPresentation(visible: true, layout: 1, currentLayout: 1))
        precondition(!ChatViewportAttachment.isCurrentPresentation(visible: false, layout: 1, currentLayout: 1))
        precondition(!ChatViewportAttachment.isCurrentPresentation(visible: true, layout: 1, currentLayout: 2))
        for generation in 1...30 {
            precondition(ChatViewportAttachment.isCurrentPresentation(visible: true, layout: 0,
                currentLayout: UInt64(generation), rootCover: reference, currentCover: reference,
                scope: reference.scope), "a stable root cover survives underlying layout replacements")
        }
        let otherReference = WorkReference(scope: reference.scope, hostIdentity: "other-host",
            workspaceID: "p", kind: .conversation, itemID: "b")
        precondition(!ChatViewportAttachment.isCurrentPresentation(visible: true, layout: 1, currentLayout: 1,
            rootCover: reference, currentCover: otherReference, scope: reference.scope))
        precondition(!ChatViewportAttachment.isCurrentPresentation(visible: true, layout: 1, currentLayout: 1,
            rootCover: reference, currentCover: reference, scope: .local(installationID: "other")))
        precondition(!ChatViewportAttachment.isCurrentPresentation(visible: false, layout: 1, currentLayout: 1,
            rootCover: reference, currentCover: reference, scope: reference.scope))
        precondition(!ChatViewportAttachment.isCurrentPresentation(visible: true, layout: 1, currentLayout: 1,
            rootCover: reference, currentCover: nil, scope: reference.scope))
        store.request(mark, for: reference)
        store.requestLatest(for: reference)
        precondition(store.takeRequest(for: reference) == nil, "attachment after Latest cannot consume an obsolete request")
        print("Viewport attachment: transient denial, vacancy recovery,60 teardown orders, late attachment, unchanged callbacks, stale reporters, bounded readiness, presentation roles, local visibility and waiting Latest passed")
    }
}
