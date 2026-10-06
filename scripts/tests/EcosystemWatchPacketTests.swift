// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with EcosystemSnapshot.swift and EcosystemApproval.swift and EcosystemWatchPacket.swift.
import Foundation

@main struct EcosystemWatchPacketTests {
    static func main() throws {
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
