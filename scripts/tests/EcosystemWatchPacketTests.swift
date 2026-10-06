// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with EcosystemSnapshot.swift and EcosystemApproval.swift and EcosystemWatchPacket.swift.
import Foundation

@main struct EcosystemWatchPacketTests {
    static func main() throws {
        assert(EcosystemWatchAction.refreshAction(for: "limits") == .limits)
        assert(EcosystemWatchAction.refreshAction(for: "requests") == .approvals)
        assert(EcosystemWatchAction.refreshAction(for: "usage") == .refresh)
        assert(EcosystemWatchAction.refreshAction(for: "projects") == .refresh)
        assert(EcosystemWatchAction(rawValue: "limits") == .limits)
        assert(EcosystemWatchAction(rawValue: "unrecognized") == nil)
        let installation = UUID()
        let time = Date()
        let first = EcosystemWatchPacket(installation: installation, revision: 10, sentAt: time, snapshot: .preview)
        let reset = EcosystemWatchPacket(installation: installation, revision: 11, sentAt: time, snapshot: .empty)
        assert(reset.isNewer(than: first))
        assert(!first.isNewer(than: reset)) // Late refresh cannot resurrect signed-out data.
        assert(!reset.isNewer(than: reset)) // Duplicate delivery.
        let oldInstall = EcosystemWatchPacket(installation: UUID(), revision: 99, sentAt: time.addingTimeInterval(-1), snapshot: .preview)
        assert(!oldInstall.isNewer(than: reset))
        let newInstall = EcosystemWatchPacket(installation: UUID(), revision: 1, sentAt: time.addingTimeInterval(1), snapshot: .empty)
        assert(newInstall.isNewer(than: reset))
        var invalid = EcosystemSnapshot.preview
        invalid.projects.append(invalid.projects[0])
        let invalidData = try JSONEncoder().encode(EcosystemWatchPacket(installation: installation, revision: 12, sentAt: time, snapshot: invalid))
        assert(EcosystemWatchPacket.decode(invalidData) == nil)
        assert(EcosystemWatchPacket.decode(Data(repeating: 0, count: 257 * 1024)) == nil)
        var approval = EcosystemApproval(requestID: "request", conversationID: "chat", peer: "host", host: "MacBook", verb: "shell",
                                         preview: "git status", fingerprint: String(repeating: "a", count: 64), expiresAt: time.addingTimeInterval(30))
        assert(approval.allows("allow", at: time) && approval.allows("deny", at: time))
        assert(!approval.allows("allowAlways", at: time) && !approval.allows("invalid", at: time))
        approval.alwaysAllowScope = "git status"
        assert(approval.allows("allowAlways", at: time))
        assert(!approval.allows("allow", at: time.addingTimeInterval(31)))
        approval.requiresPhoneReview = true
        assert(!approval.allows("allow", at: time) && !approval.allows("allowAlways", at: time))
        assert(approval.allows("deny", at: time))
        let withApproval = EcosystemWatchPacket(installation: installation, revision: 12, sentAt: time, snapshot: .preview, approvals: [approval])
        let approvalData = try JSONEncoder().encode(withApproval)
        assert(EcosystemWatchPacket.decode(approvalData) == withApproval)
        assert(!EcosystemWatchPacket(installation: installation, revision: 12, sentAt: time, snapshot: .empty, approvals: [approval]).isValid)
        assert(!EcosystemWatchPacket(installation: installation, revision: 12, sentAt: time, snapshot: .preview, approvals: [approval, approval]).isValid)
        assert(!EcosystemWatchPacket(installation: installation, revision: 12, sentAt: time, snapshot: .preview, approvals: Array(repeating: approval, count: 13)).isValid)
        let smallRequests = (0..<13).map { index in
            EcosystemApproval(requestID: "small-\(index)", conversationID: "chat", peer: "host", host: "MacBook", verb: "shell",
                              preview: "git status", fingerprint: String(repeating: "a", count: 64), expiresAt: time.addingTimeInterval(Double(30 + index)))
        }
        let expired = EcosystemApproval(requestID: "expired", conversationID: "chat", peer: "host", host: "MacBook", verb: "shell",
                                       preview: "git status", fingerprint: String(repeating: "a", count: 64), expiresAt: time)
        let selection = EcosystemApproval.watchSelection(Array(smallRequests.reversed()) + [smallRequests[0], expired], at: time)
        assert(selection.requests == Array(smallRequests.prefix(12)))
        assert(selection.omittedCount == 1) // Count truncation needs a hint even when the packet fits.
        let selectedPacket = EcosystemWatchPacket(installation: installation, revision: 13, sentAt: time, snapshot: .preview,
                                                 approvals: selection.requests, omittedApprovals: selection.omittedCount)
        assert(EcosystemWatchPacket.decode(selectedPacket.encodedForTransfer()!) == selectedPacket)
        let manySmallRequests = (0..<40).map { index in
            EcosystemApproval(requestID: "many-\(index)", conversationID: "chat", peer: "host", host: "MacBook", verb: "shell",
                              preview: "git status", fingerprint: String(repeating: "a", count: 64), expiresAt: time.addingTimeInterval(30))
        }
        assert(EcosystemApproval.watchSelection(manySmallRequests, at: time).omittedCount == 12)
        let bulky = (0..<12).map { index in
            EcosystemApproval(requestID: "request-\(index)", conversationID: "chat", peer: "host", host: "MacBook", verb: "shell",
                              preview: String(repeating: "x", count: 8192), fingerprint: String(repeating: "a", count: 64), expiresAt: time.addingTimeInterval(30))
        }
        let bulkyPacket = EcosystemWatchPacket(installation: installation, revision: 13, sentAt: time, snapshot: .preview, approvals: bulky)
        let bounded = bulkyPacket.encodedForTransfer()!
        assert(bounded.count <= 60 * 1024)
        let trimmed = EcosystemWatchPacket.decode(bounded)!
        assert(trimmed.approvals!.count > 0 && trimmed.approvals!.first == bulky.first)
        assert(trimmed.omittedApprovals == 12 - trimmed.approvals!.count)
        assert(bulkyPacket.encodedForTransfer(maximumBytes: 1) == nil)
        var alreadyOmitted = bulkyPacket
        alreadyOmitted.omittedApprovals = 12
        let furtherTrimmed = EcosystemWatchPacket.decode(alreadyOmitted.encodedForTransfer()!)!
        assert(furtherTrimmed.approvals!.count < bulky.count && furtherTrimmed.omittedApprovals == 12)
        var providersSnapshot = EcosystemSnapshot.preview
        providersSnapshot.limits = (0..<32).map { index in
            EcosystemLimitProvider(source: "vendor_\(index)", observedAt: time, stale: false,
                windows: (0..<8).map { .init(label: "window-\($0)-" + String(repeating: "x", count: 140), percent: 95, resetsAt: time.addingTimeInterval(60)) })
        }
        let quotaPacket = EcosystemWatchPacket(installation: installation, revision: 14, sentAt: time, snapshot: providersSnapshot, approvals: [approval])
        let quotaTrimmed = EcosystemWatchPacket.decode(quotaPacket.encodedForTransfer(maximumBytes: 8 * 1024)!)!
        assert(quotaTrimmed.approvals == [approval]) // Quotas cannot displace urgent review requests.
        assert((quotaTrimmed.omittedProviders ?? 0) > 0)
        assert((quotaTrimmed.omittedProviders ?? 0) + (quotaTrimmed.snapshot.limits?.count ?? 0) == 32)
        var alreadyOmittedProviders = quotaPacket
        alreadyOmittedProviders.omittedProviders = 32
        let furtherQuotaTrimmed = EcosystemWatchPacket.decode(alreadyOmittedProviders.encodedForTransfer(maximumBytes: 8 * 1024)!)!
        assert(furtherQuotaTrimmed.snapshot.limits!.count < 32 && furtherQuotaTrimmed.omittedProviders == 32)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EcosystemWatchPacketStore(directory: directory)
        assert(store.read() == nil)
        assert(store.write(first) && store.read() == first)
        assert(store.write(reset) && store.read()?.snapshot == .empty)
        assert(!EcosystemWatchPacketStore(directory: nil).write(first))
        print("Watch packets: out-of-order replies, account reset, reinstall, invalid data and atomic persistence passed")
    }
}
