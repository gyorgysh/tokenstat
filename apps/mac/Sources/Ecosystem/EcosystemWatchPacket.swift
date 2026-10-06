// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum EcosystemWatchAction: String, Sendable {
    case refresh, limits, approvals, resolve

    static func refreshAction(for screen: String) -> Self {
        switch screen {
        case "limits": .limits
        case "requests": .approvals
        default: .refresh
        }
    }
}

/// WatchConnectivity transports aggregate activity and bounded, expiring requests.
/// A monotonic revision rejects replies that arrive after a newer account reset.
struct EcosystemWatchPacket: Codable, Equatable, Sendable {
    let installation: UUID
    let revision: UInt64
    let sentAt: Date
    var snapshot: EcosystemSnapshot
    var approvals: [EcosystemApproval]? = nil
    var omittedApprovals: Int? = nil
    var omittedProviders: Int? = nil

    var isValid: Bool {
        snapshot.isValid && sentAt.timeIntervalSince1970.isFinite
            && (snapshot.owner != nil || approvals?.isEmpty != false)
            && (approvals?.count ?? 0) <= 12
            && (approvals?.allSatisfy(\.isValid) ?? true)
            && Set(approvals?.map(\.id) ?? []).count == (approvals?.count ?? 0)
            && (0...12).contains(omittedApprovals ?? 0)
            && (0...32).contains(omittedProviders ?? 0)
    }

    /// Leave headroom for the property-list envelope used by WatchConnectivity.
    /// Keep urgent requests first and explain any omitted requests on Watch.
    func encodedForTransfer(maximumBytes: Int = 60 * 1024) -> Data? {
        guard isValid else { return nil }
        var packet = self
        while let data = try? JSONEncoder().encode(packet) {
            if data.count <= maximumBytes { return data }
            if !packet.snapshot.projects.isEmpty { packet.snapshot.projects.removeLast() }
            else if packet.snapshot.limits?.isEmpty == false {
                packet.snapshot.limits?.removeLast()
                packet.omittedProviders = min(32, (packet.omittedProviders ?? 0) + 1)
            }
            else if packet.approvals?.isEmpty == false {
                packet.approvals?.removeLast()
                packet.omittedApprovals = min(12, (packet.omittedApprovals ?? 0) + 1)
            } else { return nil }
        }
        return nil
    }

    func isNewer(than previous: Self?) -> Bool {
        guard isValid else { return false }
        guard let previous else { return true }
        if installation == previous.installation { return revision > previous.revision }
        return sentAt > previous.sentAt
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 256 * 1024, let packet = try? JSONDecoder().decode(Self.self, from: data),
              packet.isValid else { return nil }
        return packet
    }
}

struct EcosystemWatchPacketStore {
    let directory: URL?
    init(directory: URL? = EcosystemSnapshotStore().directory) { self.directory = directory }
    func read() -> EcosystemWatchPacket? {
        guard let directory, let data = EcosystemSnapshotStore.readBoundedData(at: directory.appendingPathComponent("watch-packet.json")) else { return nil }
        return EcosystemWatchPacket.decode(data)
    }
    func write(_ packet: EcosystemWatchPacket) -> Bool {
        guard let directory, packet.isValid, let data = try? JSONEncoder().encode(packet), data.count <= 256 * 1024 else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appendingPathComponent("watch-packet.json")
            try data.write(to: url, options: .atomic)
            #if os(watchOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch { return false }
    }
}
