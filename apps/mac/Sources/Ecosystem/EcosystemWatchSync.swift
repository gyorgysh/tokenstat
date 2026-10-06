// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(iOS)
import Foundation
import WatchConnectivity

@MainActor
final class EcosystemWatchSync: NSObject, WCSessionDelegate {
    static let shared = EcosystemWatchSync()
    private let session = WCSession.default
    private var pending: EcosystemSnapshot?

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func publish(_ snapshot: EcosystemSnapshot) {
        if snapshot.owner == nil { EcosystemApprovalService.clear() }
        pending = snapshot
        sendPending()
    }

    private func packet(_ snapshot: EcosystemSnapshot) -> Data? {
        let defaults = UserDefaults.standard
        let installation = defaults.string(forKey: "ecosystem.watch.installation").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(installation.uuidString, forKey: "ecosystem.watch.installation")
        let revision = max(UInt64(max(0, defaults.integer(forKey: "ecosystem.watch.revision"))) + 1,
                           UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000)))
        defaults.set(revision, forKey: "ecosystem.watch.revision")
        return EcosystemWatchPacket(installation: installation, revision: revision, sentAt: Date(), snapshot: snapshot,
                                   approvals: EcosystemApprovalService.requests(for: snapshot.owner)).encodedForTransfer()
    }

    private func sendPending() {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let snapshot = pending, let data = packet(snapshot) else { return }
        do { try session.updateApplicationContext(["snapshot": data]); pending = nil }
        catch { /* Activation and subsequent successful loads retry the latest state. */ }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.sendPending() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            if let lease = EcosystemPublisher.lease {
                let snapshot = EcosystemSnapshotStore().read()
                if snapshot.owner == lease.owner { self.publish(snapshot) }
            }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let requestedOwner = message["owner"] as? String
        let action = message["action"] as? String
        let choice = message["choice"] as? String
        let approvalData = message["approval"] as? Data
        Task { @MainActor in
            guard ["refresh", "approvals", "resolve"].contains(action ?? ""),
                  requestedOwner == nil || requestedOwner == EcosystemSnapshotStore().read().owner else {
                replyHandler(["error": "accountChanged"]); return
            }
            do {
                if action == "resolve" {
                    guard let requestedOwner, let choice, let approvalData, approvalData.count <= 60 * 1024,
                          let approval = try? JSONDecoder().decode(EcosystemApproval.self, from: approvalData) else {
                        replyHandler(["error": "invalidRequest"]); return
                    }
                    try await EcosystemApprovalService.resolve(approval, owner: requestedOwner, choice: choice)
                } else if action == "approvals" {
                    _ = try await EcosystemApprovalService.load(owner: requestedOwner)
                } else { try await EcosystemPublisher.refresh() }
                let snapshot = EcosystemSnapshotStore().read()
                self.publish(snapshot)
                guard let data = self.packet(snapshot) else { replyHandler(["error": "unavailable"]); return }
                replyHandler(["snapshot": data])
            } catch { replyHandler(["error": "unavailable"]) }
        }
    }
}
#endif
