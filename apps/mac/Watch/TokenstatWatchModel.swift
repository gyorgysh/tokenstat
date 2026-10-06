// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation
import WatchConnectivity
import WidgetKit

@MainActor @Observable
final class TokenstatWatchModel: NSObject, WCSessionDelegate {
    static let shared = TokenstatWatchModel()
    private(set) var snapshot = EcosystemSnapshot.empty
    private(set) var refreshing = false
    private(set) var message: String?
    var destination: WatchScreen = .usage
    var projectID: String?
    var selectedApproval: EcosystemApproval?
    var approvals: [EcosystemApproval] { (lastPacket?.approvals ?? []).filter { $0.expiresAt > Date() } }
    var omittedProviders: Int { lastPacket?.omittedProviders ?? 0 }
    var omittedApprovals: Int { lastPacket?.omittedApprovals ?? 0 }
    @ObservationIgnored private var lastPacket: EcosystemWatchPacket?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private let session = WCSession.default

    override private init() {
        super.init()
        lastPacket = EcosystemWatchPacketStore().read()
        snapshot = lastPacket?.snapshot ?? .empty
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func handleBackgroundTransfer() async {
        activate()
        let deadline = Date().addingTimeInterval(15)
        while !Task.isCancelled, Date() < deadline,
              session.activationState != .activated || session.hasContentPending {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let data = session.receivedApplicationContext["snapshot"] as? Data { receive(data) }
    }

    func refresh() {
        send(["action": destination == .requests ? "approvals" : "refresh"])
    }

    func resolve(_ approval: EcosystemApproval, choice: String) {
        guard approval.allows(choice), let owner = snapshot.owner,
              let data = try? JSONEncoder().encode(approval) else {
            message = "This request expired. Refresh to check pending requests."
            return
        }
        send(["action": "resolve", "owner": owner, "choice": choice, "approval": data],
             success: choice == "deny" ? "Request denied." : choice == "allowAlways" ? "Allowed for this chat." : "Allowed once.")
    }

    private func send(_ values: [String: Any], success: String? = nil) {
        guard !refreshing else { return }
        guard session.activationState == .activated, session.isReachable else {
            message = "Could not reach your iPhone. Keep it nearby and unlock it, then try again."
            return
        }
        refreshing = true
        message = nil
        let requestID = UUID()
        request = requestID
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self.request == requestID else { return }
            self.finish(message: "Your iPhone did not confirm. Refresh to check the latest state.")
        }
        var payload = values
        if let owner = snapshot.owner { payload["owner"] = owner }
        session.sendMessage(payload, replyHandler: { reply in
            let data = reply["snapshot"] as? Data
            Task { @MainActor in
                guard self.request == requestID else { return }
                if let data, let packet = EcosystemWatchPacket.decode(data) {
                    let received = self.receive(data)
                    guard self.request == requestID else { return }
                    if received || packet.snapshot.owner == self.snapshot.owner { self.finish(message: success); return }
                }
                self.finish(message: "Could not confirm with your host. Refresh to check pending requests, or open tokenstat on your iPhone.")
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                guard self.request == requestID else { return }
                self.finish(message: "Could not reach your iPhone. Try again when it is nearby.")
            }
        })
    }

    private func finish(message: String?) {
        refreshing = false
        request = nil
        timeout?.cancel()
        timeout = nil
        self.message = message
    }

    @discardableResult private func receive(_ data: Data) -> Bool {
        guard let packet = EcosystemWatchPacket.decode(data) else { return false }
        if packet == lastPacket { return true }
        guard packet.isNewer(than: lastPacket), EcosystemWatchPacketStore().write(packet) else { return false }
        let previousOwner = snapshot.owner
        lastPacket = packet
        snapshot = packet.snapshot
        if previousOwner != nil, previousOwner != snapshot.owner {
            finish(message: "Your account changed. Review the latest synced requests before choosing.")
        }
        if let projectID, !snapshot.projects.contains(where: { $0.id == projectID }) { self.projectID = nil }
        if let selectedApproval, !(packet.approvals ?? []).contains(selectedApproval) { self.selectedApproval = nil }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        Task { @MainActor in if let data { self.receive(data) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["snapshot"] as? Data
        Task { @MainActor in if let data { self.receive(data) } }
    }
}
