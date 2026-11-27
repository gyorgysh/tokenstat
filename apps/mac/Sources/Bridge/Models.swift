// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI


// Every SSH record below spells its ids `…Id` on the wire, because the host
// derives its keys with `#[serde(rename_all = "camelCase")]` and Rust's
// `resource_id` becomes `resourceId`, never `resourceID`. Swift's synthesized
// keys use the property name, so a property called `resourceID` silently asks
// for a key nothing sends.
//
// Silently is the problem. An optional field arrives as nil and a save appears
// to succeed while the host writes nothing, which is how servers went on
// forgetting their folder and their key every time somebody pressed Save. A
// non-optional one throws and takes the whole list with it, which is why
// snippets and trusted servers were always empty.
//
// So these maps are load-bearing, not decoration. `scripts/check-bridge-keys.sh`
// fails the build when a bridge model grows an `…ID` property with no entry
// here, and `ssh_records.rs` asserts the key sets from the other side.

struct SSHProviderReference: Codable, Sendable, Hashable {
    var kind: String
    var resourceID: String
    var region: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case resourceID = "resourceId"
        case region
    }
}

struct SSHHost: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var hostname: String
    var port: Int
    var username: String
    var initialDirectory: String?
    var credentialID: String?
    var jumpHostID: String?
    var tags: [String]
    var provider: SSHProviderReference?
    var hostKeys: [String]
    var folderID: String?
    var color: String?
    var keepaliveSeconds: Int = 0
    var env: [SSHEnvPair] = []
    var agentForwarding: Bool = false
    var lastConnectedMs: Int64?
    var favorite: Bool = false
    var sort: Int = 0
    var updatedMs: Int64 = 0

    var address: String { "\(username)@\(hostname):\(port)" }

    enum CodingKeys: String, CodingKey {
        case id, label, hostname, port, username, initialDirectory
        case credentialID = "credentialId"
        case jumpHostID = "jumpHostId"
        case tags, provider, hostKeys
        case folderID = "folderId"
        case color, keepaliveSeconds, env, agentForwarding, lastConnectedMs
        case favorite, sort, updatedMs
    }
}

struct SSHEnvPair: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var value: String
    var id: String { name }
}

struct SSHFolder: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var parentID: String?
    var color: String?
    var sort: Int = 0
    var updatedMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parentId"
        case color, sort, updatedMs
    }
}

enum SSHColor {
    static let names = ["violet", "blue", "green", "amber", "red", "grey"]

    static func color(_ name: String?) -> Color {
        switch name {
        case "violet": Theme.accent
        case "blue": Color.blue
        case "green": Color.green
        case "amber": Theme.warning
        case "red": Theme.danger
        case "grey": Theme.stateIdle
        default: Theme.stateIdle
        }
    }
}

struct SSHKeyRecord: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var algorithm: String
    var publicKey: String
    /// Reference into Keychain/ssh-agent. This is never private key material.
    var secretRef: String
    var hardwareBacked: Bool
    var fingerprint: String = ""
    var createdMs: Int64 = 0
    var passphraseProtected: Bool = false
    var updatedMs: Int64 = 0
}

struct SSHSnippet: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var command: String
    var tags: [String]
    var hostIDs: [String]
    var variables: [String] = []
    var runOnConnect: Bool = false
    var updatedMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, command, tags
        case hostIDs = "hostIds"
        case variables, runOnConnect, updatedMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        if let ids = try container.decodeIfPresent([String].self, forKey: .hostIDs) {
            hostIDs = ids
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            hostIDs = try legacy.decodeIfPresent([String].self, forKey: .hostIDs) ?? []
        }
        variables = try container.decodeIfPresent([String].self, forKey: .variables) ?? []
        runOnConnect = try container.decodeIfPresent(Bool.self, forKey: .runOnConnect) ?? false
        updatedMs = try container.decodeIfPresent(Int64.self, forKey: .updatedMs) ?? 0
    }

    init(
        id: String,
        title: String,
        command: String,
        tags: [String],
        hostIDs: [String],
        variables: [String] = [],
        runOnConnect: Bool = false,
        updatedMs: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.tags = tags
        self.hostIDs = hostIDs
        self.variables = variables
        self.runOnConnect = runOnConnect
        self.updatedMs = updatedMs
    }

    private enum LegacyKeys: String, CodingKey {
        case hostIDs
    }

    static func bytesToRun(_ command: String) -> [UInt8] {
        Array((command + "\r").utf8)
    }

    static func placeholders(in command: String) -> [String] {
        var found: [String] = []
        var rest = Substring(command)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !found.contains(name) { found.append(name) }
            rest = rest[close.upperBound...]
        }
        return found
    }

    func filled(with values: [String: String]) -> String {
        var text = command
        for name in variables {
            guard let value = values[name] else { continue }
            text = text.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return text
    }
}

struct SSHKnownHost: Codable, Sendable, Hashable, Identifiable {
    var hostID: String
    var label: String
    var hostname: String
    var port: Int
    var fingerprints: [String]
    var id: String { hostID }

    enum CodingKeys: String, CodingKey {
        case hostID = "hostId"
        case label, hostname, port, fingerprints
    }
}

struct SSHConfigCandidate: Codable, Sendable, Hashable, Identifiable {
    var label: String
    var hostname: String
    var username: String
    var port: Int
    var identityFile: String?
    var alreadySaved: Bool
    var id: String { "\(label)|\(hostname)|\(port)" }
}

struct SSHConfigImport: Codable, Sendable, Hashable { var imported: Int; var found: Int }
struct SSHKnownHostForget: Codable, Sendable, Hashable { var forgotten: Bool }

struct SSHSessionHandle: Codable, Sendable, Hashable { var id: String }

struct SSHSessionSummary: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var hostID: String?
    var label: String
    var openedMs: Int64
    var alive: Bool
    var droppedBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "hostId"
        case label, openedMs, alive, droppedBytes
    }
}
struct SSHHostFingerprint: Codable, Sendable, Hashable { var fingerprint: String }

struct ServerCheck: Codable, Sendable, Hashable {
    var os: String?
    var arch: String?
    var distro: String?
    var user: String?
    var home: String?
    var uid: Int?
    var root: Bool?
    var systemd: Bool?
    var curl: Bool?
    var git: Bool?
    var homeWritable: Bool?
    var installed: Bool?
    var diskFreeMb: UInt64?
    var blockers: [String] = []
    var ready: Bool = false
}

struct RemoteListing: Codable, Sendable, Hashable {
    struct Root: Codable, Sendable, Hashable, Identifiable {
        var path: String
        var label: String
        var kind: String
        var id: String { path }
    }

    struct Entry: Codable, Sendable, Hashable, Identifiable {
        var name: String
        var path: String?
        var kind: String
        var symlink: Bool = false
        var hidden: Bool = false
        var isRepo: Bool = false
        var isRegistered: Bool = false
        var size: UInt64?
        var modified: UInt64?

        var id: String { path ?? name }
        var isDirectory: Bool { kind == "directory" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            kind = try container.decode(String.self, forKey: .kind)
            symlink = try container.decodeIfPresent(Bool.self, forKey: .symlink) ?? false
            hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            isRepo = try container.decodeIfPresent(Bool.self, forKey: .isRepo) ?? false
            isRegistered = try container.decodeIfPresent(Bool.self, forKey: .isRegistered) ?? false
            size = try container.decodeIfPresent(UInt64.self, forKey: .size)
            modified = try container.decodeIfPresent(UInt64.self, forKey: .modified)
        }
    }

    var path: String
    var parent: String?
    var roots: [Root] = []
    var entries: [Entry] = []
    var truncated: Bool = false
}

struct RemoteCloneStatus: Codable, Sendable, Hashable {
    var state: String
    var path: String
    var workspaceId: String?
    var error: String?
}

struct InstallLine: Codable, Sendable, Hashable {
    var oneLine: String
    var annotated: String
}

struct PairingCode: Codable, Sendable, Hashable {
    var code: String
    var expiresIn: UInt64
}

struct ProvisionStatus: Codable, Sendable, Hashable {
    struct Account: Codable, Sendable, Hashable {
        var signedIn: Bool?
        var handle: String?
        var tier: String?
    }

    struct RunsAs: Codable, Sendable, Hashable {
        var uid: Int?
        var name: String?
        var root: Bool?
    }

    struct Agent: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var name: String
        var installed: Bool
        var signedIn: Bool?
        var readiness: AgentReadiness?
        var expiresAt: Double?
        var signIn: AgentSignIn?
    }

    struct Tunnel: Codable, Sendable, Hashable {
        var enabled: Bool?
        var online: Bool?
        var error: String?
    }

    var headless: Bool
    var desktop: Bool?
    var screen: Bool?
    var serviceScope: String?
    var runsAs: RunsAs?
    var alwaysOn: Bool?
    var account: Account
    var machineName: String
    var machineKey: String
    var keyFingerprint: String
    var protocolVersion: String
    var hostVersion: String
    var allowedDevices: Int
    var pendingRequests: Int
    var agents: [Agent] = []
    var folders: Int
    var tunnel: Tunnel
}
struct SSHSessionRead: Codable, Sendable, Hashable {
    var data: [UInt8]
    var nextOffset: UInt64
    var dropped: Bool
    var closed: Bool
    var error: String?
}

struct SSHSuggestion: Codable, Sendable, Hashable, Identifiable {
    var kind: String
    var title: String
    var detail: String
    var insert: String
    var replace: Int
    var variables: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        insert = try c.decode(String.self, forKey: .insert)
        replace = try c.decodeIfPresent(Int.self, forKey: .replace) ?? 0
        variables = try c.decodeIfPresent([String].self, forKey: .variables) ?? []
    }

    var id: String { "\(kind)\u{1}\(insert)" }

    var isSnippet: Bool { kind == "snippet" }
    var isDirectory: Bool { kind == "directory" }
    var readsAsCode: Bool { kind != "snippet" }
}

struct SSHSuggestions: Codable, Sendable, Hashable {
    var fragment: String
    var rows: [SSHSuggestion]
    var pending: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fragment = try c.decodeIfPresent(String.self, forKey: .fragment) ?? ""
        rows = try c.decodeIfPresent([SSHSuggestion].self, forKey: .rows) ?? []
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}

struct SSHKeyMaterial: Codable, Sendable, Hashable {
    var algorithm: String
    var publicKey: String
    var fingerprint: String
    var privateKey: String
}

struct SSHVaultStatus: Codable, Sendable, Hashable {
    var vaultSession: String? = nil
    var created: Bool
    var recordCount: Int
    var enrolled: Bool?
    var locked: Bool?
    var needsRecreate: Bool?
    var unreachable: String?
}
struct SSHVaultReset: Codable, Sendable, Hashable { var reset: Bool }
struct SSHVaultRecovery: Codable, Sendable, Hashable { var recovery: String }
struct SSHVaultPasswordChange: Codable, Sendable, Hashable {
    var changed: Bool
    var recovery: String?
}
struct SSHVaultUnlock: Codable, Sendable, Hashable { var unlocked: Bool; var recovery: String? }
struct SSHVaultRecord: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var version: UInt64
    var plaintext: String
    var deleted: Bool?
}
struct SSHVaultPut: Codable, Sendable, Hashable { var id: String; var version: UInt64 }
struct SSHVaultDelete: Codable, Sendable, Hashable { var id: String; var version: UInt64; var deleted: Bool }
struct SSHVaultRecords: Codable, Sendable, Hashable { var records: [SSHVaultRecord] }
struct SSHHostImport: Codable, Sendable, Hashable { var imported: Int; var hosts: [SSHHost] }
struct ScreenPermission: Codable, Sendable, Hashable, Identifiable {
    var peerID: String
    var view: Bool
    var control: Bool
    var id: String { peerID }

    enum CodingKeys: String, CodingKey {
        case peerID = "peerId"
        case view, control
    }
}
struct ScreenCapability: Codable, Sendable, Hashable { var token: String; var expiresAt: UInt64; var control: Bool }
enum ScreenQualityChoice: String, CaseIterable, Identifiable, Sendable {
    case auto
    case sharp
    case smooth
    case dataSaver

    var id: String { rawValue }

    var wire: String? { self == .auto ? nil : rawValue }

    var title: String {
        switch self {
        case .auto: return L10n.text("apple.models.automatic.d461a493")
        case .sharp: return L10n.text("apple.models.sharp.1a3c4b30")
        case .smooth: return L10n.text("apple.models.smooth.da519387")
        case .dataSaver: return L10n.text("apple.models.data_saver.5b444f24")
        }
    }

    var detail: String {
        switch self {
        case .auto: return L10n.text("apple.models.best_the_connection_allows.6532539b")
        case .sharp: return L10n.text("apple.models.every_detail_on_a_fast_link.ef30d0aa")
        case .smooth: return L10n.text("apple.models.steady_over_the_relay.6391fb1b")
        case .dataSaver: return L10n.text("apple.models.least_data_softest_picture.383ee72b")
        }
    }
}

struct ScreenQualityProfile: Sendable, Hashable {
    var maxWidth: CGFloat
    var averageBitRate: Int
    var viewingFPS: Int32
    var controlFPS: Int32
    var keyframeSeconds: Int32

    static let relay = ScreenQualityProfile(
        maxWidth: 1920,
        averageBitRate: 1_500_000,
        viewingFPS: 30,
        controlFPS: 60,
        keyframeSeconds: 4
    )

    static let dataSaver = ScreenQualityProfile(
        maxWidth: 1280,
        averageBitRate: 800_000,
        viewingFPS: 20,
        controlFPS: 30,
        keyframeSeconds: 4
    )

    static let direct = ScreenQualityProfile(
        maxWidth: 2560,
        averageBitRate: 8_000_000,
        viewingFPS: 30,
        controlFPS: 60,
        keyframeSeconds: 2
    )

    static let directSharp = ScreenQualityProfile(
        maxWidth: 3840,
        averageBitRate: 16_000_000,
        viewingFPS: 30,
        controlFPS: 60,
        keyframeSeconds: 2
    )
}

struct ScreenCaptureSession: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var peerID: String
    var control: Bool
    var dropped: UInt64
    var route: String?
    var quality: String?

    enum CodingKeys: String, CodingKey {
        case id
        case peerID = "peerId"
        case control, dropped, route, quality
    }

    var profile: ScreenQualityProfile {
        switch quality {
        case "sharp": return .directSharp
        case "smooth": return .relay
        case "dataSaver": return .dataSaver
        default: return route == "direct" ? .direct : .relay
        }
    }
}
struct ScreenCapturePush: Codable, Sendable, Hashable { var accepted: Bool; var dropped: UInt64 }
struct ScreenCaptureInput: Codable, Sendable, Hashable {
    var data: String?
    var batch: [String]? = nil

    var events: [String] { batch ?? data.map { [$0] } ?? [] }
}
struct ScreenViewerSession: Codable, Sendable, Hashable {
    var id: String
    var control: Bool
    var transport: String
    var sessionId: String? = nil
}
struct ScreenViewerRead: Codable, Sendable, Hashable { var frame: String?; var audio: String?; var metadata: String?; var active: Bool; var dropped: UInt64; var error: String? }
struct ScreenTransferDestination: Codable, Sendable, Hashable { var path: String? }
struct ScreenTransferOpen: Codable, Sendable, Hashable { var id: String; var offset: UInt64; var chunkBytes: Int }
struct ScreenTransferChunk: Codable, Sendable, Hashable { var offset: UInt64 }
struct ScreenTransferSaved: Codable, Sendable, Hashable { var saved: Bool; var path: String }
struct ScreenTransferCancelled: Codable, Sendable, Hashable { var cancelled: Bool; var removed: Bool }
struct ScreenAccessRequest: Codable, Sendable, Hashable { var sent: UInt32; var enabled: Bool; var signedIn: Bool }

struct ScreenAccessAsk: Codable, Sendable, Hashable {
    var pending: Bool
    var granted: Bool?
}

enum DeviceAccessKind: String, Sendable, Hashable {
    case screen
    case workspace
}

struct DeviceAccessPending: Codable, Sendable, Hashable, Identifiable {
    var peerID: String
    var label: String?
    var control: Bool
    var askedAt: UInt64
    var expiresAt: UInt64
    var kind: DeviceAccessKind = .screen

    var id: String { "\(kind.rawValue):\(peerID)" }

    enum CodingKeys: String, CodingKey {
        case peerID = "peerId"
        case label, control
        case askedAt, expiresAt
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return L10n.text("apple.models.device_0.625b47c6", "\(peerID.prefix(8))")
    }

    var headline: String {
        switch kind {
        case .screen: return L10n.text("apple.models.0_wants_to_see_this_screen.a07f03f2", "\(displayName)")
        case .workspace: return L10n.text("apple.models.0_wants_to_open_your_work.24c50659", "\(displayName)")
        }
    }

    var detail: String {
        switch kind {
        case .screen:
            return control
                ? L10n.text("apple.models.it_asked_for_the_picture_and_for_mouse_and.d24fdc88")
                : L10n.text("apple.models.it_asked_for_the_picture_only.b6be05b5")
        case .workspace:
            return L10n.text("apple.models.folders_files_terminals_and_the_agents_run.5abdd984")
        }
    }
}

struct Query: Sendable, Equatable {
    var since: String?
    var until: String?
    var model: String?
    var project: String?
    var billing: String?
    var limit: Int?

    var payload: [String: Any] {
        var out: [String: Any] = [:]
        if let since { out["since"] = since }
        if let until { out["until"] = until }
        if let model { out["model"] = model }
        if let project { out["project"] = project }
        if let billing { out["billing"] = billing }
        if let limit { out["limit"] = limit }
        return out
    }
}

enum GroupBy: String, Sendable, CaseIterable, Identifiable {
    case day, week, model, project, source, session

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return L10n.text("apple.models.day.8f2364e1")
        case .week: return L10n.text("apple.models.week.e78041ab")
        case .model: return L10n.text("apple.models.model.5e2c614c")
        case .project: return L10n.text("apple.models.project.98595978")
        case .source: return L10n.text("apple.models.coding_tool.9f48285d")
        case .session: return L10n.text("apple.models.session.6959b415")
        }
    }
}

struct Counters: Codable, Sendable, Hashable {
    var inputFresh: UInt64?
    var cacheRead: UInt64?
    var cacheWrite5m: UInt64?
    var cacheWrite1h: UInt64?
    var output: UInt64?
    var total: UInt64
    var inputTotal: UInt64
    var hasUnknown: Bool

    var workTokens: UInt64 {
        (inputFresh ?? 0).saturatingAdd(output ?? 0)
    }
}

struct Bucket: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var valueMicros: Int64
    var estimated: Bool
    var unpricedModels: [String]
    var local: Bool?

    var id: String { key }

    var value: Money {
        Money(micros: valueMicros, estimated: estimated, complete: unpricedModels.isEmpty,
              local: local == true)
    }
}

struct AccountReport: Codable, Sendable, Hashable {
    var rows: [Bucket]
    var group: String
    var fetchedAtMs: Int64
    var stale: Bool

    var fetchedAt: Date { Date(timeIntervalSince1970: Double(fetchedAtMs) / 1000) }
}

struct MachineUsage: Codable, Sendable, Hashable, Identifiable {
    var machine: String
    var valueMicros: Int64
    var events: UInt64
    var activeDays: Int
    var days: Int

    var id: String { machine }

    var value: Money {
        Money(micros: valueMicros, estimated: false, complete: true)
    }
}

struct Totals: Codable, Sendable, Hashable {
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var days: UInt64
    var firstDate: String?
    var lastDate: String?
}

struct InsightsSnapshot: Codable, Sendable, Hashable {
    var info: Info
    var totals: Totals
    var daily: [Bucket]
    var byModel: [Bucket]
    var byProject: [Bucket]
    var bySource: [Bucket]
    var byProfile: [Bucket]? = nil
    var bySession: [Bucket]
    var activeBlock: Block?
    var projectHarnesses: [SplitBucket]
}

struct Block: Codable, Sendable, Hashable, Identifiable {
    var startMs: Int64
    var endMs: Int64
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var active: Bool

    var id: Int64 { startMs }

    var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    var end: Date { Date(timeIntervalSince1970: Double(endMs) / 1000) }
}

struct ScanReport: Codable, Sendable, Hashable {
    var filesFound: UInt64
    var filesRead: UInt64
    var rowsSeen: UInt64
    var eventsNew: UInt64
    var eventsRecovered: UInt64
    var daysRecovered: UInt64
    var elapsedMs: UInt64
    var warnings: [String]
}

struct FetchReport: Codable, Sendable, Hashable {
    var vendor: String
    var events: Int
    var fromCache: Bool
    var skippedNoToken: Bool
    var failed: Bool?
    var message: String?
}

struct FileText: Codable, Sendable, Hashable {
    var path: String
    var content: String
}


struct HeatCell: Codable, Sendable, Hashable, Identifiable {
    var date: String
    var value: UInt64
    var level: Int
    var locked: Bool?

    var id: String { date }

    var isLocked: Bool { locked == true }
}

struct MonthLabel: Codable, Sendable, Hashable, Identifiable {
    var column: Int
    var name: String

    var id: Int { column }
}

struct ActivityCalendar: Codable, Sendable, Hashable {
    var rows: [[HeatCell?]]
    var months: [MonthLabel]
    var weeks: Int
    var total: UInt64
    var activeDays: Int
    var streakCurrent: Int
    var streakBest: Int
    var busiest: HeatCell?
    var first: String
    var last: String
    var scope: String?
    var notice: String?
    var noticeCode: String?
    var unlockFrom: String?
    var historyLocked: Bool?
    var historyDays: Int?
    var historyUpgrade: Bool?
    var fetchedAtMs: Int64?

    var isHistoryLocked: Bool { historyLocked == true }

    var fetchedAt: Date? {
        guard let fetchedAtMs, fetchedAtMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(fetchedAtMs) / 1000)
    }

    var isStaleGrid: Bool { noticeCode == "stale" }

    var freshness: String? {
        guard let fetchedAt else { return nil }
        let ago = fetchedAt.formatted(.relative(presentation: .named))
        return isStaleGrid ? L10n.text("apple.models.stale_last_updated_0.72c66d79", "\(ago)") : L10n.text("apple.models.updated_0.01a31c30", "\(ago)")
    }
}


struct DayDetail: Codable, Sendable, Hashable, Identifiable {
    var date: String
    var tokens: UInt64
    var events: UInt64
    var valueMicros: Int64
    var estimated: Bool
    var unpricedModels: [String]
    var rows: [DayPart]

    var id: String { date }

    var value: Money {
        Money(micros: valueMicros, estimated: estimated, complete: unpricedModels.isEmpty)
    }
}

struct DayPart: Codable, Sendable, Hashable, Identifiable {
    var model: String
    var src: String
    var fresh: UInt64?
    var cacheRead: UInt64?
    var cacheWrite5m: UInt64?
    var cacheWrite1h: UInt64?
    var output: UInt64?
    var tokens: UInt64
    var events: UInt64

    var id: String { "\(src)\u{1}\(model)" }
}

func shortModel(_ id: String) -> String {
    var raw = id.trimmingCharacters(in: .whitespaces)
    if raw.lowercased().hasPrefix("local:") { raw = String(raw.dropFirst(6)) }
    let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
    let lower = leaf.lowercased()
    if ["default", "auto", "cursor-auto", "cursor-default", "cursor-router-auto"].contains(lower) {
        return "cursor-router-auto"
    }
    if let colon = leaf.range(of: ": ") {
        let after = String(leaf[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !after.isEmpty { return after }
    }
    return leaf.isEmpty ? "model" : leaf
}


struct SyntaxSpan: Codable, Sendable, Hashable {
    var start: Int
    var len: Int
    var kind: SyntaxKind

    var range: NSRange { NSRange(location: start, length: len) }
}

struct SyntaxRules: Codable, Sendable, Hashable {
    var lineComment: String?
    var blockComment: [String]?
    var indent: Int

    var indentUnit: String { String(repeating: " ", count: max(1, indent)) }

    static let fallback = SyntaxRules(lineComment: nil, blockComment: nil, indent: 4)
}

struct Highlighting: Codable, Sendable, Hashable {
    var language: String?
    var syntax: SyntaxRules?
    var spans: [SyntaxSpan]
    var note: String?

    static let none = Highlighting(language: nil, syntax: nil, spans: [], note: nil)

    var rules: SyntaxRules { syntax ?? .fallback }
}

struct Info: Codable, Sendable, Hashable {
    var protocolVersion: String
    var coreVersion: String
    var dbPath: String?
    var hasArchive: Bool
    var lastScanMs: Int64? = nil
    var timezone: String
    var priceBookEffectiveFrom: String
    var hasPrices: Bool
}

struct PricingRefresh: Codable, Sendable, Hashable {
    var effectiveFrom: String
    var models: UInt64
    var hasPrices: Bool
}

struct PricingSeed: Codable, Sendable, Hashable {
    var adopted: Bool
    var effectiveFrom: String
    var models: UInt64
    var hasPrices: Bool
}

struct AppUpdate: Codable, Sendable, Hashable {
    var current: String
    var latest: String
    var newer: Bool
    var htmlURL: String
    var dmgURL: String?
    var retryAt: Double?

    enum CodingKeys: String, CodingKey {
        case current, latest, newer, retryAt, htmlURL = "htmlUrl", dmgURL = "dmgUrl"
    }

    var downloadURL: URL? {
        URL(string: dmgURL ?? htmlURL)
    }

    var isAvailable: Bool { newer && latest != current }
}

struct DownloadedFile: Codable, Sendable {
    var path: String
}

struct Money: Sendable, Hashable {
    var micros: Int64
    var estimated: Bool
    var complete: Bool
    var local = false

    var dollars: Double { Double(micros) / 1_000_000 }

    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.currencyCode = "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    var formatted: String {
        if local && micros == 0 { return L10n.text("common.value.local") }
        let amount = Self.currency.string(from: NSNumber(value: dollars))
            ?? String(format: "$%.2f", dollars)
        if !complete { return "\(amount)+" }
        if estimated { return "~\(amount)" }
        return amount
    }
}

extension Sequence where Element == Bucket {
    var totalValue: Money {
        reduce(Money(micros: 0, estimated: false, complete: true)) { acc, row in
            Money(
                micros: acc.micros.saturatingAdd(row.valueMicros),
                estimated: acc.estimated || row.estimated,
                complete: acc.complete && row.unpricedModels.isEmpty
            )
        }
    }
}

extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other >= 0 ? .max : .min) : sum
    }
}

extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

func formatSpend(_ micros: UInt64) -> String {
    Money(micros: Int64(clamping: micros), estimated: false, complete: true).formatted
}

func formatTokens(_ n: UInt64) -> String {
    let value = Double(n)
    switch n {
    case 1_000_000_000...:
        return String(format: "%.1fB", value / 1_000_000_000)
    case 1_000_000...:
        return String(format: "%.1fM", value / 1_000_000)
    case 10_000...:
        return String(format: "%.0fk", value / 1_000)
    case 1_000...:
        return String(format: "%.1fk", value / 1_000)
    default:
        return "\(n)"
    }
}


struct DeviceLogin: Codable, Sendable, Hashable {
    var host: String
    var userCode: String
    var openURL: String
    var verificationURI: String
    var expiresIn: UInt64
    var interval: UInt64

    enum CodingKeys: String, CodingKey {
        case host
        case userCode
        case openURL = "openUrl"
        case verificationURI = "verificationUri"
        case expiresIn
        case interval
    }
}

struct DevicePoll: Codable, Sendable, Hashable {
    var state: String
    var interval: UInt64?
    var handle: String?
    var host: String?
    var machine: String?

    var isConfirmed: Bool { state == "confirmed" }
}

struct AgentProfiles: Codable, Sendable, Hashable {
    var `default`: String
    var agents: [String]
    var profiles: [AgentProfile]
    var workspaceLocks: [String: String]?

    static let system = "system"
    var named: [AgentProfile] { profiles.filter { !$0.system } }
    func profile(_ id: String?) -> AgentProfile? { profiles.first { $0.id == (id ?? Self.system) } }
}

struct AgentProfile: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var system: Bool
    var platform: String? = nil
    var own: [String]

    var title: String {
        if system { return L10n.text("common.profiles.main") }
        return name ?? id
    }
}

struct AccountProfile: Codable, Sendable, Hashable {
    var isPublic: Bool
    var indexable: Bool
    var handleChangeDays: Int
    var handlePrompted: Bool

    enum CodingKeys: String, CodingKey {
        case isPublic = "public"
        case indexable, handleChangeDays, handlePrompted
    }
}

struct HandleCheck: Codable, Sendable, Hashable {
    var handle: String
    var available: Bool
    var reason: String?
    var message: String
}

struct Account: Codable, Sendable, Hashable {
    var signedIn: Bool
    var host: String
    var handle: String?
    var accountSession: String? = nil
    var displayName: String?
    var profilePublic: Bool? = nil
    var profile: AccountProfile? = nil
    var tier: String?
    var avatar: String?
    var lastSyncAt: String?
    var thisMachineID: String?
    var accountId: String?
    var machines: [Machine]
    var schemaCurrent: UInt32?
    var machineLimit: Int?
    var hostsLinked: Int?
    var canRemote: Bool?
    var syncInterval: Int?
    var billing: AccountBilling?
    var relayUsage: RelayUsage?

    enum CodingKeys: String, CodingKey {
        case signedIn, host, handle, displayName, profilePublic, profile
        case tier, avatar, lastSyncAt, accountSession
        case thisMachineID = "thisMachineId"
        case accountId = "accountId"
        case machines, schemaCurrent
        case machineLimit, hostsLinked, canRemote, syncInterval
        case billing, relayUsage
    }

    var hostMachines: [Machine] { machines.filter(\.isHost) }

    var title: String? {
        let name = displayName?.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty { return name }
        return handle
    }

    var isPaidTier: Bool {
        switch tier?.lowercased() {
        case "supporter", "patron", "legend": return true
        default: return false
        }
    }

    var allowsVaultSync: Bool { isPaidTier }

    var vaultTierForSsh: String? {
        guard signedIn else { return nil }
        if allowsVaultSync { return tier?.lowercased() ?? "legend" }
        return tier?.lowercased() ?? "free"
    }

    /// Live App Store subscription. StoreKit manage UI is only honest here.
    var isAppleBilled: Bool {
        billing?.isApple == true && billing?.blocksOtherStore == true
    }

    var isPaddleBilled: Bool {
        billing?.isPaddle == true && billing?.blocksOtherStore == true
    }

    /// Paid access that did not come from the App Store.
    ///
    /// Founder / family access sets a paid tier with no `subscriptions` row.
    /// The iOS paywall must not treat that as an Apple purchase.
    var isWebManagedPlan: Bool {
        isPaidTier && !isAppleBilled
    }
}

/// Cross-store billing snapshot from `/api/v1/me`.
///
/// iOS uses this to pick the paywall, the App Store manage sheet, or the
/// "you subscribed on the website" card. Mac ignores it and keeps Paddle.
struct AccountBilling: Codable, Sendable, Hashable {
    var provider: String?
    var status: String?
    var entitled: Bool?
    var periodEnd: String?
    var cancelScheduled: Bool?
    var scheduledTier: String?
    var scheduledInterval: String?
    var interval: String?
    var trialUsed: Bool?
    var hasLiveSub: Bool?
    var appAccountToken: String?

    var isApple: Bool { provider == "apple" }
    var isGooglePlay: Bool { provider == "google_play" }
    var isPaddle: Bool { provider == "paddle" }
    var isLive: Bool {
        switch status {
        case "active", "trialing", "past_due": return true
        default: return entitled == true
        }
    }

    var blocksOtherStore: Bool { hasLiveSub ?? isLive }
}

struct HostStats: Codable, Sendable, Hashable {
    var power: String?
    var charging: Bool?
    var percent: UInt8?
    var cpu: Double?
    var ramUsedBytes: UInt64?
    var ramTotalBytes: UInt64?
}

struct HostUpdateState: Codable, Sendable, Hashable {
    var hostVersion: String
    var protocolVersion: String
    var latest: String
    var newer: Bool
    var htmlUrl: String
    var autoApply: Bool
    var restartPending: Bool
    var liveWork: Int
    var canRestart: Bool
    var appManaged: Bool
    var appImage: String?
}

struct HostUpdateResult: Codable, Sendable, Hashable {
    var from: String? = nil
    var to: String? = nil
    var hostBinaryUpdated: Bool? = nil
    var restarting: Bool? = nil
    var restartPending: Bool? = nil
    var liveWork: Int? = nil
    var canRestart: Bool? = nil
    var appManaged: Bool? = nil
    var appImage: String? = nil
    var hostVersion: String? = nil
    var detail: String? = nil
}

struct Machine: Codable, Sendable, Hashable, Identifiable {
    var machineID: String?
    var label: String?
    var lastSyncAt: String?
    var online: Bool?
    var lastSeenAt: String?
    var publicIdentity: String?
    var trustState: String?
    var kind: String?
    var platform: String?
    var labelSource: String?

    enum CodingKeys: String, CodingKey {
        case machineID = "id"
        case label
        case lastSyncAt
        case online
        case lastSeenAt
        case publicIdentity
        case trustState
        case kind
        case platform
        case labelSource
    }

    var isHost: Bool { kind != "client" }

    var reportsArchiveSync: Bool { isHost }

    var id: String { machineID ?? label ?? "unidentified" }

    var displayName: String {
        switch (label, machineID) {
        case let (label?, _) where !label.isEmpty:
            return label
        case let (_, id?):
            return id
        default:
            return L10n.text("apple.models.unnamed_device.72ac73e4")
        }
    }

    var subtitle: String? {
        guard let machineID, label?.isEmpty == false else { return nil }
        return machineID
    }
}

struct SyncOutcome: Codable, Sendable, Hashable {
    var host: String
    var rows: UInt64
    var dryRun: Bool
    var schemaV: UInt32
    var from: String
    var to: String
}

struct ProxyListen: Codable, Sendable, Hashable {
    var url: String
}

struct RemoteLaunchProfile: Codable, Sendable, Hashable {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var bypassArgs: [String]
    var harnessId: String?
    var symbol: String?
    var openUrl: String?
    var installed: Bool
    var hidden: Bool?
    var installCommand: String?
    var readiness: AgentReadiness?
    var expiresAt: Double?
    var signIn: AgentSignIn?
}

enum AgentReadiness: String, Codable, Sendable, Hashable {
    case notInstalled, needsSignIn, signedIn, expired, unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentReadiness(rawValue: raw) ?? .unknown
    }

    var summary: String {
        switch self {
        case .notInstalled: L10n.text("apple.models.not_installed.d177cdc0")
        case .needsSignIn: L10n.text("apple.models.not_signed_in.491fc91c")
        case .signedIn: L10n.text("apple.models.signed_in.ca566c89")
        case .expired: L10n.text("apple.models.sign_in_expired.07fd892e")
        case .unknown: L10n.text("apple.models.sign_in_not_checked.58904f56")
        }
    }
}

struct AgentSignIn: Codable, Sendable, Hashable {
    var supported: Bool
    var kind: String?
}

struct LauncherInstallResult: Codable, Sendable {
    var ok: Bool
    var exitCode: Int?
    var output: String
}

struct AgentUpdateRow: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var version: String?
    var latest: String?
    var updateAvailable: Bool?
    var canUpdate: Bool
    var canCheck: Bool
    var busy: Bool
    var error: String?
}

struct AgentUpdateResult: Codable, Sendable {
    var ok: Bool
    var exitCode: Int?
    var output: String
    var before: String?
    var after: String?
}

struct HarnessConfig: Codable, Sendable {
    var id: String
    var path: String?
    var available: Bool
    var reason: String?
    var fields: [HarnessConfigField]
}

struct HarnessConfigField: Codable, Sendable, Identifiable {
    var key: String
    var label: String
    var kind: String
    var options: [String]
    var hint: String?
    var min: Int?
    var max: Int?
    var step: Int?
    var fallback: Int?
    var value: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, kind, options, hint, min, max, step
        case fallback = "default"
        case value
    }
}

struct LocalProvider: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var baseURL: String
    var port: Int? = nil
    var defaultPort: Int? = nil
    var currentPort: Int { port ?? URL(string: baseURL)?.port ?? standardPort }
    var standardPort: Int { defaultPort ?? (id == "lmstudio" ? 1234 : 11434) }
    var available: Bool
    var models: [LocalModel]
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL = "baseUrl", port, defaultPort, available, models, error
    }
}

struct LocalModel: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var sizeBytes: UInt64?

    var sizeDescription: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(clamping: sizeBytes))
    }
}

struct SyncScheduleStatus: Codable, Sendable {
    let loggedIn: Bool
    let cliScheduleActive: Bool
    let scheduledNetworkAllowed: Bool
    let due: Bool
}

func formatRelativeDate(_ raw: String?) -> String? {
    guard let date = parseServerDate(raw) else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

func parseServerDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let parsers = [ISO8601DateFormatter(), {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()]
    for p in parsers {
        if let date = p.date(from: raw) { return date }
    }
    return nil
}

func formatServerDate(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let parsers = [ISO8601DateFormatter(), {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()]
    for p in parsers {
        if let date = p.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }
    return raw
}

struct SplitBucket: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var split: String
    var counters: Counters
    var events: UInt64
    var sessions: UInt64

    var id: String { "\(key)\u{1}\(split)" }
}

struct ProjectHarnesses: Identifiable, Hashable {
    var path: String
    var harnesses: [SplitBucket]
    var tokens: UInt64

    var id: String { path }

    var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let leaf = trimmed.split(separator: "/").last.map(String.init)
        return leaf?.isEmpty == false ? leaf! : (trimmed.isEmpty ? "unknown" : trimmed)
    }
}

func harnessID(forCommand command: String) -> String? {
    switch URL(fileURLWithPath: command).lastPathComponent {
    case "claude": return "claude_code"
    case "codex": return "codex"
    case "opencode", "opencode2": return "opencode"
    case "grok": return "grok"
    case "copilot": return "copilot"
    case "cline": return "cline"
    case "openclaw": return "openclaw"
    case "muse": return "muse"
    case "pi": return "pi"
    case "omp": return "omp"
    case "zed": return "zed"
    case "agy": return "antigravity"
    case "agent", "cursor": return "cursor"
    case "hermes": return "hermes"
    case "kilocode", "kilo": return "kilo"
    default: return nil
    }
}

func harnessCanonicalID(_ id: String) -> String {
    if id == "agy" { return "antigravity" }
    if id.hasPrefix("antigravity") { return "antigravity" }
    if id == "claude" { return "claude_code" }
    if id == "opencode2" { return "opencode" }
    return id
}

func harnessToolKey(_ id: String) -> String {
    switch id {
    case "claude_code_estimate", "claude_code_rollup": return "claude_code"
    default: return id
    }
}

func harnessName(_ id: String) -> String {
    if id == "opencode2" { return "OpenCode 2" }
    let canonical = harnessCanonicalID(id)
    switch canonical {
    case "claude_code": return L10n.text("apple.models.claude_code.246ef8c1")
    case "claude_code_rollup", "claude_code_estimate": return L10n.text("apple.models.claude_code_recovered.93f5e6b2")
    case "codex": return "Codex"
    case "grok": return L10n.text("apple.models.grok_build.fd3bf01a")
    case "opencode": return "OpenCode"
    case "cline": return "Cline"
    case "openclaw": return "OpenClaw"
    case "muse": return "Muse"
    case "devin": return L10n.text("apple.models.devin_cli.29247d05")
    case "pi": return "Pi"
    case "omp": return "Oh My Pi"
    case "dsh": return L10n.text("apple.models.deepseek_harness.e562a9c5")
    case "zed": return "Zed"
    case "copilot": return L10n.text("apple.models.copilot_cli.c73e38d4")
    case "antigravity": return "Antigravity"
    case "cursor": return "Cursor"
    case "gemini": return "Gemini"
    case "hermes": return L10n.text("apple.models.hermes_agent.873e989a")
    case "kilo": return L10n.text("apple.models.kilo_code.83abecfd")
    case "kimi": return L10n.text("apple.models.kimi_code.0c486180")
    case "qwen": return L10n.text("apple.models.qwen_code.47487dbd")
    case "": return "unknown"
    default: return canonical.isEmpty ? "unknown" : canonical
    }
}

/// Whether an account machine's platform string names a Linux host.
///
/// Only a first guess, used before the host itself has answered
/// `host.provisionStatus` (its `screen` and `headless` fields are the truth)
/// or when it cannot. Matched by whole word, so "aarch64" is not Arch Linux,
/// and a string that names macOS or Windows is never Linux whatever else it
/// carries. Empty stays false, never hiding anything for a machine that did
/// not say what it runs.
func isHeadlessPlatform(_ platform: String?) -> Bool {
    let words = Set(
        (platform ?? "").lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    )
    guard !words.isEmpty else { return false }
    if !words.isDisjoint(with: ["macos", "darwin", "osx", "windows", "win32"]) { return false }
    return !words.isDisjoint(with: [
        "linux", "ubuntu", "debian", "fedora", "alpine", "arch", "archlinux",
        "centos", "rocky", "almalinux", "rhel", "opensuse", "suse", "nixos", "gentoo", "mint",
    ])
}

/// Asset name for a harness's brand mark, or nil when none is bundled.
///
/// Vendor marks, not ours. See TRADEMARK.md. A missing one falls back to a
/// letter tile rather than borrowing another tool's logo.
func harnessBrandAsset(_ id: String) -> String? {
    let canonical = harnessCanonicalID(id)
    let assetId: String
    switch canonical {
    case "claude_code_estimate", "claude_code_rollup": assetId = "claude_code"
    default: assetId = canonical
    }
    let known: Set<String> = [
        "claude_code", "codex", "grok", "opencode",
        "cline", "openclaw", "muse", "devin", "pi", "omp", "dsh", "zed", "copilot",
        "antigravity", "cursor", "gemini", "hermes", "kilo", "kimi", "qwen",
    ]
    return known.contains(assetId) ? "brand_\(assetId)" : nil
}


enum ChangeKind: String, Codable, Sendable {
    case added, modified, deleted, renamed, untracked, conflicted

    var symbol: String {
        switch self {
        case .added: return "plus.square"
        case .modified: return "square.righthalf.filled"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.right.square"
        case .untracked: return "questionmark.square"
        case .conflicted: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        case .untracked: return .secondary
        case .modified, .renamed: return Theme.secondary
        }
    }

    var label: String {
        switch self {
        case .added: return L10n.text("apple.models.added.6b02e0d3")
        case .modified: return L10n.text("apple.models.modified.e8ce5dca")
        case .deleted: return L10n.text("apple.models.deleted.b48ff39c")
        case .renamed: return L10n.text("apple.models.renamed.05487af3")
        case .untracked: return L10n.text("apple.models.untracked.c7ba5477")
        case .conflicted: return L10n.text("apple.models.conflicted.916a464e")
        }
    }
}

struct FileChange: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var kind: ChangeKind
    var added: UInt64?
    var removed: UInt64?

    var id: String { path }

    var directory: String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    var fileName: String {
        String(path.split(separator: "/").last ?? "")
    }
}

struct GitStatus: Codable, Sendable, Hashable {
    var isRepo: Bool
    var branch: String?
    var upstream: String?
    var ahead: UInt32
    var behind: UInt32
    var files: [FileChange]
    var added: UInt64
    var removed: UInt64
    var partial: Bool

    var hasLineChanges: Bool { added > 0 || removed > 0 }

    var compactChangeSummary: String {
        if !hasLineChanges {
            return files.count == 1
                ? L10n.text("apple.git_status.change_count.one", files.count.formatted())
                : L10n.text("apple.git_status.change_count.other", files.count.formatted())
        }
        return "+\(added.formatted())" + (removed > 0 ? " −\(removed.formatted())" : "")
    }
}

struct GitBranch: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var current: Bool
    var upstream: String?
    var ahead: UInt32
    var behind: UInt32
    var lastCommit: Int64
    var remote: Bool

    var id: String { "\(remote ? "remote" : "local"):\(name)" }
    var date: Date? { lastCommit > 0 ? Date(timeIntervalSince1970: TimeInterval(lastCommit)) : nil }
}


struct PullAvailability: Codable, Sendable, Hashable {
    var state: String
    var host: String?
    var owner: String?
    var repo: String?
    var login: String?
    var source: String?
    var installUrl: String?
    var installationId: UInt64?

    var repositoryName: String? {
        guard let owner, let repo else { return nil }
        return "\(owner)/\(repo)"
    }
}

struct PullDeviceLogin: Codable, Sendable, Hashable {
    var host: String
    var userCode: String
    var openUrl: String
    var expiresIn: UInt64
    var interval: UInt64
}

struct PullDevicePoll: Codable, Sendable, Hashable {
    var state: String
    var interval: UInt64?
    var source: String?
}

enum PullScope: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case mine
    case assigned
    case reviewRequested

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return L10n.text("apple.models.all.a52ace42")
        case .mine: return L10n.text("apple.models.mine.f57afb7d")
        case .assigned: return L10n.text("apple.models.assigned.8191888d")
        case .reviewRequested: return L10n.text("apple.models.review_requested.744f7028")
        }
    }
}

enum PullStateFilter: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case open
    case merged
    case closed
    case draft

    var id: String { rawValue }
    var label: String { self == .all ? L10n.text("apple.models.all.a52ace42") : rawValue.capitalized }
}

enum PullCheckState: String, Codable, Sendable, Hashable {
    case passing
    case failing
    case pending
}

struct PullSummary: Codable, Sendable, Hashable, Identifiable {
    var number: UInt32
    var title: String
    var author: String
    var authorAvatar: String?
    var createdAt: String
    var updatedAt: String
    var headRef: String
    var baseRef: String
    var additions: UInt32
    var deletions: UInt32
    var changedFiles: UInt32
    var state: String
    var draft: Bool
    var reviewDecision: String?
    var labels: [String]
    var comments: UInt32
    var checks: PullCheckState?

    var id: UInt32 { number }
    var updatedDate: Date? { parseServerDate(updatedAt) }
}

struct PullListPage: Codable, Sendable {
    var rows: [PullSummary]
    var nextCursor: String?
}

struct PullActor: Codable, Sendable, Hashable, Identifiable {
    var login: String
    var avatar: String?
    var id: String { login }
}

struct PullReview: Codable, Sendable, Hashable, Identifiable {
    var author: PullActor
    var state: String
    var body: String
    var submittedAt: String
    var id: String { "\(author.login):\(submittedAt)" }
}

struct PullFile: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var additions: UInt32
    var deletions: UInt32
    var changeType: String
    var id: String { path }
}

struct PullCheck: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var workflow: String?
    var state: String
    var startedAt: String?
    var completedAt: String?
    var url: String?
    var id: String { "\(workflow ?? ""):\(name)" }

    var durationText: String? {
        guard let started = parseServerDate(startedAt),
              let completed = parseServerDate(completedAt)
        else { return nil }
        let seconds = max(0, Int(completed.timeIntervalSince(started).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct PullDetail: Codable, Sendable, Hashable, Identifiable {
    var number: UInt32
    var title: String
    var body: String
    var url: String
    var author: PullActor
    var createdAt: String
    var updatedAt: String
    var headRef: String
    var baseRef: String
    var additions: UInt32
    var deletions: UInt32
    var changedFiles: UInt32
    var state: String
    var draft: Bool
    var reviewDecision: String?
    var mergeable: String
    var mergeState: String
    var labels: [String]
    var assignees: [PullActor]
    var reviewRequests: [PullActor]
    var reviews: [PullReview]
    var files: [PullFile]
    var checks: [PullCheck]
    var checksTruncated: Bool?

    var id: UInt32 { number }
    var createdDate: Date? { parseServerDate(createdAt) }
    var hasIncompleteChecks: Bool { checksTruncated ?? (checks.count >= 50) }
}

struct PullTimelineEvent: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: String
    var actor: PullActor
    var createdAt: String
    var body: String?
    var subject: String?
    var state: String?
    var url: String?
    var createdDate: Date? { parseServerDate(createdAt) }
}

struct PullTimelinePage: Codable, Sendable, Hashable {
    var events: [PullTimelineEvent]
    var nextCursor: String?
}

enum PullReviewVerdict: String, Codable, Sendable, CaseIterable, Identifiable {
    case approve
    case requestChanges
    case comment
    var id: String { rawValue }
}

enum PullMergeMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case merge
    case squash
    case rebase
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct PullWriteResult: Codable, Sendable, Hashable {
    var ok: Bool
}

struct PullForgeConnection: Codable, Sendable, Hashable {
    var state: String
    var host: String
    var login: String?
    var source: String?
}

struct TreeEntry: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var path: String
    var isDir: Bool
    var ignored: Bool

    var id: String { path }
}

extension DiffLineKind {
    var tint: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }
}

enum GitOutcomeAction: Sendable, Hashable {
    case commit
    case push

    var done: String {
        switch self {
        case .commit: return L10n.text("apple.models.committed.3160c5e5")
        case .push: return L10n.text("apple.models.pushed.73b8b141")
        }
    }

    var failed: String {
        switch self {
        case .commit: return L10n.text("apple.models.could_not_commit.48fd13cb")
        case .push: return L10n.text("apple.models.could_not_push.ba04327e")
        }
    }
}

struct GitOutcome: Codable, Sendable, Hashable {
    var ok: Bool
    var message: String
}

struct Commit: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var subject: String
    var author: String
    /// Author email. Optional because the running daemon can be older than the
    /// app: a launchd agent is updated on its own schedule, and a field it does
    /// not send must not fail the whole decode.
    var email: String?
    var timestamp: Int64
    var unpushed: Bool
    var mine: Bool?
    var tags: [String]?

    var shortID: String { String(id.prefix(7)) }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    var tagList: [String] { tags ?? [] }
}

enum LimitSeverity: String, Codable, Sendable {
    case normal, warning, critical

    var tint: Color {
        switch self {
        case .normal: return Theme.accent
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    var label: String
    var scope: String?
    var percent: Double
    var resetsAtMs: Int64?
    var severity: LimitSeverity

    var id: String {
        "\(label)|\(scope ?? "")"
    }

    var displayLabel: String {
        guard let scope else {
            return label
        }
        switch scope.lowercased() {
        case "secondary":
            return L10n.text("apple.models.0_all_models.31683c25", "\(label)")
        case "primary":
            return L10n.text("apple.models.0_primary.57ab87b8", "\(label)")
        case "current model":
            return L10n.text("apple.models.0_secondary.6cd2b67a", "\(label)")
        default:
            return "\(label) (\(scope))"
        }
    }

    var resetsAt: Date? {
        resetsAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    var fraction: Double { min(1, max(0, percent / 100)) }
}

struct LimitsSyncState: Codable, Sendable {
    var enabled: Bool
    var skip: [String]
    var providers: [ProviderLimits]

    init(enabled: Bool = false, skip: [String] = [], providers: [ProviderLimits] = []) {
        self.enabled = enabled
        self.skip = skip
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case enabled, skip, providers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        skip = try c.decodeIfPresent([String].self, forKey: .skip) ?? []
        providers = try c.decodeIfPresent([ProviderLimits].self, forKey: .providers) ?? []
    }
}

struct ProviderLimits: Codable, Sendable, Hashable, Identifiable {
    var source: String
    var profileId: String? = nil
    var plan: String?
    var windows: [UsageWindow]
    var observedAtMs: Int64
    var note: String?
    var stale: Bool?

    var id: String { profileId.map { "\(source):\($0)" } ?? source }

    var observedAt: Date? {
        observedAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000) : nil
    }

    var isStale: Bool { stale == true }

    var hasWindows: Bool { !windows.isEmpty }

    var nextReset: Date? {
        windows.compactMap(\.resetsAt).min()
    }
}

struct CommitDetail: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var subject: String
    var body: String
    var author: String
    var email: String
    var timestamp: Int64
    var parents: [String]
    var files: [FileChange]
    var added: UInt64
    var removed: UInt64
    var diffs: [FileDiff]
    var tags: [String]?

    var shortID: String { String(id.prefix(7)) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var isMerge: Bool { parents.count > 1 }

    var tagList: [String] { tags ?? [] }
}

struct WorkspaceSummary: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var sessions: Int
    var chats: Int?
    var changed: Int?
    var pulls: Int?
    var tasks: Int
    var notes: Int?
    var workflows: Int
    var workflowsRunning: Int
    var automations: Int
}

struct WorkspaceFolder: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var path: String
    var name: String
    var addedAtMs: Int64
    var exists: Bool
    var git: GitStatus?
    var machineID: String?
    var machineLabel: String?
    var teamOrganizations: [String]?
    var general: Bool? = nil

    var changeCount: Int { git?.files.count ?? 0 }
    var isGeneral: Bool { general == true }
    var symbol: String { isGeneral ? "bubble.left.and.bubble.right" : isRemote ? "globe" : "folder" }

    var diffStat: String? {
        guard let git, git.isRepo, !git.files.isEmpty else { return nil }
        return git.compactChangeSummary
    }

    var subtitle: String? {
        guard !isGeneral else { return nil }
        guard exists else { return L10n.text("apple.models.folder_missing.f06c68a6") }
        guard let git, git.isRepo else { return L10n.text("apple.models.not_a_git_repo.86308fef") }
        var parts: [String] = []
        if let branch = git.branch, !branch.isEmpty {
            parts.append(branch)
        }
        if git.ahead > 0 { parts.append("⇡\(git.ahead)") }
        if git.behind > 0 { parts.append("⇣\(git.behind)") }
        if let stat = diffStat { parts.append(stat) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var isRemote: Bool { machineID != nil }

    var presented: WorkspaceFolder {
        guard isGeneral else { return self }
        var folder = self
        folder.name = L10n.text("common.new_chat.no_repository")
        return folder
    }
}


struct ChatSharingMarker: Codable, Sendable, Hashable {
    var id: String
}

struct ChatConversation: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var workspaceID: String
    var title: String
    var backend: String
    var teamShare: ChatSharingMarker? = nil
    var personaID: String?
    var model: String?
    var effort: String?
    var fastMode = false
    var systemPrompt: String
    var mode: String
    var autonomy: String
    var resumeToken: String?
    var allowedTools: [String]
    var allowedShellPrefixes: [String]
    var budgetSeconds: UInt64
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var profileId: String? = nil
    var lastMessageAtMs: Int64?
    var lastMessageAuthor: String?
    var sendRevision: UInt64?
    var runRevision: UInt64? = nil
    var runStartedAtMs: Int64? = nil
    var running: Bool
    var waiting: Bool? = nil
    var pendingSteer: String?
    var nativeSteer: Bool? = nil
    var nativeSteerAttachments: Bool? = nil
    var routing: ChatRoutingState? = nil
    var branch: String?
    var pull: BranchPull?
    var pulls: [ChatPull] = []
    var promptCache: ChatPromptCache? = nil
    var continuedFrom: String? = nil

    init(saved reference: WorkReference, title: String, backend: String?) {
        id = reference.itemID ?? ""
        workspaceID = reference.workspaceID
        self.title = title
        self.backend = backend ?? "agent"
        systemPrompt = ""
        mode = "execute"
        autonomy = "standard"
        allowedTools = []
        allowedShellPrefixes = []
        budgetSeconds = 0
        createdAtMs = 0
        updatedAtMs = 0
        running = false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case title, backend, teamShare
        case personaID = "personaId"
        case model, effort, fastMode, systemPrompt, mode, autonomy, resumeToken
        case allowedTools, allowedShellPrefixes, budgetSeconds
        case createdAtMs, updatedAtMs, lastMessageAtMs, lastMessageAuthor, running, waiting, sendRevision, runRevision, runStartedAtMs, pendingSteer, nativeSteer, nativeSteerAttachments
        case branch, pull, pulls, routing, promptCache, continuedFrom, profileId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sendRevision = try c.decodeIfPresent(UInt64.self, forKey: .sendRevision)
        runRevision = try c.decodeIfPresent(UInt64.self, forKey: .runRevision)
        runStartedAtMs = try c.decodeIfPresent(Int64.self, forKey: .runStartedAtMs)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        title = try c.decode(String.self, forKey: .title)
        backend = try c.decode(String.self, forKey: .backend)
        teamShare = try c.decodeIfPresent(ChatSharingMarker.self, forKey: .teamShare)
        personaID = try c.decodeIfPresent(String.self, forKey: .personaID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        fastMode = try c.decodeIfPresent(Bool.self, forKey: .fastMode) ?? false
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "plan"
        autonomy = try c.decodeIfPresent(String.self, forKey: .autonomy) ?? "standard"
        resumeToken = try c.decodeIfPresent(String.self, forKey: .resumeToken)
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        allowedShellPrefixes = try c.decodeIfPresent([String].self, forKey: .allowedShellPrefixes) ?? []
        budgetSeconds = try c.decodeIfPresent(UInt64.self, forKey: .budgetSeconds) ?? 0
        createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        updatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
        lastMessageAtMs = try c.decodeIfPresent(Int64.self, forKey: .lastMessageAtMs)
        lastMessageAuthor = try c.decodeIfPresent(String.self, forKey: .lastMessageAuthor)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting)
        routing = try? c.decodeIfPresent(ChatRoutingState.self, forKey: .routing)
        pendingSteer = try c.decodeIfPresent(String.self, forKey: .pendingSteer)
        nativeSteer = try c.decodeIfPresent(Bool.self, forKey: .nativeSteer)
        nativeSteerAttachments = try c.decodeIfPresent(Bool.self, forKey: .nativeSteerAttachments)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        pull = try? c.decodeIfPresent(BranchPull.self, forKey: .pull)
        pulls = (try? c.decodeIfPresent([ChatPull].self, forKey: .pulls)) ?? pull.map { [ChatPull($0)] } ?? []
        promptCache = try? c.decodeIfPresent(ChatPromptCache.self, forKey: .promptCache)
        continuedFrom = try c.decodeIfPresent(String.self, forKey: .continuedFrom)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sendRevision, forKey: .sendRevision)
        try c.encodeIfPresent(runRevision, forKey: .runRevision)
        try c.encodeIfPresent(runStartedAtMs, forKey: .runStartedAtMs)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(title, forKey: .title)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(teamShare, forKey: .teamShare)
        try c.encodeIfPresent(personaID, forKey: .personaID)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encode(fastMode, forKey: .fastMode)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(mode, forKey: .mode)
        try c.encode(autonomy, forKey: .autonomy)
        try c.encodeIfPresent(resumeToken, forKey: .resumeToken)
        try c.encode(allowedTools, forKey: .allowedTools)
        try c.encode(allowedShellPrefixes, forKey: .allowedShellPrefixes)
        try c.encode(budgetSeconds, forKey: .budgetSeconds)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encodeIfPresent(lastMessageAtMs, forKey: .lastMessageAtMs)
        try c.encodeIfPresent(lastMessageAuthor, forKey: .lastMessageAuthor)
        try c.encode(running, forKey: .running)
        try c.encodeIfPresent(routing, forKey: .routing)
        try c.encodeIfPresent(pendingSteer, forKey: .pendingSteer)
        try c.encodeIfPresent(nativeSteer, forKey: .nativeSteer)
        try c.encodeIfPresent(nativeSteerAttachments, forKey: .nativeSteerAttachments)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(pull, forKey: .pull)
        try c.encodeIfPresent(promptCache, forKey: .promptCache)
        try c.encodeIfPresent(continuedFrom, forKey: .continuedFrom)
        try c.encodeIfPresent(profileId, forKey: .profileId)
    }
}

struct ChatPromptCache: Codable, Sendable, Hashable {
    var backend: String
    var tokens: UInt64
    var model: String?
    var selection: String?
    var atMs: Int64
    var ttlMs: Int64
}

/// Answer from `chat.steerDeliver`.
///
/// `delivered` is false when the note did not start a turn. The conversation,
/// when present, is the disk record of the turn that did start, and it does
/// not carry the parked note.
struct ChatSteerDelivery: Codable, Sendable {
    var delivered: Bool
    var conversation: ChatConversation?
}

struct ChatRecentConversation: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var workspaceID: String
    var title: String
    var backend: String
    var lastMessageAtMs: Int64?
    var lastMessageAuthor: String?
    var running: Bool
    var needsAttention: Bool
    var pulls: [ChatPull] = []

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case title, backend, lastMessageAtMs, lastMessageAuthor, running, needsAttention, pulls, pull
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(title, forKey: .title)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(lastMessageAtMs, forKey: .lastMessageAtMs)
        try c.encodeIfPresent(lastMessageAuthor, forKey: .lastMessageAuthor)
        try c.encode(running, forKey: .running)
        try c.encode(needsAttention, forKey: .needsAttention)
        try c.encode(pulls, forKey: .pulls)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        title = try c.decode(String.self, forKey: .title)
        backend = try c.decode(String.self, forKey: .backend)
        lastMessageAtMs = try c.decodeIfPresent(Int64.self, forKey: .lastMessageAtMs)
        lastMessageAuthor = try c.decodeIfPresent(String.self, forKey: .lastMessageAuthor)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        needsAttention = try c.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
        let pull = try? c.decodeIfPresent(BranchPull.self, forKey: .pull)
        pulls = (try? c.decodeIfPresent([ChatPull].self, forKey: .pulls)) ?? pull.map { [ChatPull($0)] } ?? []
    }
}

enum LocalModelLaunch {
    static func accepts(_ launcherID: String) -> Bool {
        ["claude_code", "codex", "opencode", "opencode2", "copilot"].contains(launcherID)
    }

    static func parse(_ key: String?) -> (provider: String, model: String)? {
        guard let key, let separator = key.firstIndex(of: ":") else { return nil }
        let provider = String(key[key.startIndex ..< separator])
        let model = String(key[key.index(after: separator)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }
}

struct LocalChatModelInfo: Codable, Sendable, Hashable {
    var id: String
    var contextLength: Int?
}

enum LocalChatModel {
    static func parse(_ id: String?) -> (provider: String, model: String)? {
        guard let rest = id?.trimmingCharacters(in: .whitespaces), rest.hasPrefix("local:"),
              let slash = rest.dropFirst(6).firstIndex(of: "/") else { return nil }
        let provider = String(rest[rest.index(rest.startIndex, offsetBy: 6) ..< slash])
        let model = String(rest[rest.index(after: slash)...])
        return provider.isEmpty || model.isEmpty ? nil : (provider, model)
    }

    static func providerName(_ id: String) -> String {
        switch id {
        case "lmstudio": "LM Studio"
        case "ollama": "Ollama"
        default: id
        }
    }

    static let roomyContext = 65_536

    static func title(_ id: String) -> String {
        guard let local = parse(id) else { return id }
        return "\(providerName(local.provider)): \(local.model)"
    }
}

struct ChatBackend: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var label: String
    var command: String
    var models: [String]
    var efforts: [String]
    var fastModeModels: [String]? = nil
    var fastModeLive = false
    var modelListStatus: String? = nil
    var installed: Bool? = nil
    var launcherID: String? = nil
    var canInstall: Bool = false
    var readiness: String? = nil
    var signIn: AgentSignIn? = nil
    var canCheckSignIn: Bool = false
    var signInVerified: Bool = false
    var gateTier: String
    var updateAvailable: Bool = false
    var latestVersion: String? = nil
    var installedVersion: String? = nil
    var localModels: [LocalChatModelInfo] = []

    var signInFlow: AgentSignIn? {
        if let signIn { return signIn }
        switch launcherID {
        case "claude_code": return AgentSignIn(supported: true, kind: "browserCode")
        case "codex": return AgentSignIn(supported: true, kind: "deviceCode")
        default: return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, label, name, command, models, efforts, fastModeModels, fastModeLive, gateTier, modelListStatus, installed
        case launcherID = "launcherId"
        case canInstall, readiness, signIn, canCheckSignIn
        case updateAvailable, latestVersion, installedVersion
        case localModels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        modelListStatus = try c.decodeIfPresent(String.self, forKey: .modelListStatus)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed)
        launcherID = try c.decodeIfPresent(String.self, forKey: .launcherID)
        canInstall = try c.decodeIfPresent(Bool.self, forKey: .canInstall) ?? false
        readiness = try c.decodeIfPresent(String.self, forKey: .readiness)
        signIn = try c.decodeIfPresent(AgentSignIn.self, forKey: .signIn)
        canCheckSignIn = try c.decodeIfPresent(Bool.self, forKey: .canCheckSignIn) ?? false
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? id
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        fastModeModels = try c.decodeIfPresent([String].self, forKey: .fastModeModels)
        fastModeLive = try c.decodeIfPresent(Bool.self, forKey: .fastModeLive) ?? false
        gateTier = try c.decodeIfPresent(String.self, forKey: .gateTier) ?? "full"
        localModels = (try? c.decodeIfPresent([LocalChatModelInfo].self, forKey: .localModels)) ?? []
    }

    func contextLength(of id: String) -> Int? {
        localModels.first { $0.id == id }?.contextLength
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(command, forKey: .command)
        try c.encode(models, forKey: .models)
        try c.encode(efforts, forKey: .efforts)
        try c.encodeIfPresent(fastModeModels, forKey: .fastModeModels)
        try c.encode(fastModeLive, forKey: .fastModeLive)
        try c.encode(gateTier, forKey: .gateTier)
        try c.encodeIfPresent(modelListStatus, forKey: .modelListStatus)
        try c.encodeIfPresent(installed, forKey: .installed)
        try c.encodeIfPresent(launcherID, forKey: .launcherID)
        try c.encode(canInstall, forKey: .canInstall)
        try c.encodeIfPresent(readiness, forKey: .readiness)
        try c.encodeIfPresent(signIn, forKey: .signIn)
        try c.encode(canCheckSignIn, forKey: .canCheckSignIn)
        try c.encode(updateAvailable, forKey: .updateAvailable)
        try c.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try c.encodeIfPresent(installedVersion, forKey: .installedVersion)
        if !localModels.isEmpty { try c.encode(localModels, forKey: .localModels) }
    }
}

struct ChatPersona: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var workspaceID: String?
    var name: String
    var systemPrompt: String
    var seed: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case name
        case systemPrompt
        case seed
    }

    static func blank() -> ChatPersona {
        ChatPersona(id: "", workspaceID: nil, name: "", systemPrompt: "", seed: 0)
    }
}

struct ChatPersonaList: Codable, Sendable {
    var personas: [ChatPersona]
    var defaultId: String
}

struct ChatPersonaDraft: Codable, Sendable, Hashable {
    var name: String
    var systemPrompt: String
}

struct ChatSendReceipt: Codable, Sendable, Hashable {
    enum State: String, Codable, Sendable {
        case accepted
        case pending
        case needsRecovery
        case unknown
    }

    var state: State
    var atMs: Int64?
    var eventAtMs: Int64?

    var isAccepted: Bool { state == .accepted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? container.decode(State.self, forKey: .state)) ?? .unknown
        atMs = try container.decodeIfPresent(Int64.self, forKey: .atMs)
        eventAtMs = try container.decodeIfPresent(Int64.self, forKey: .eventAtMs)
    }
}

struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var mediaType: String?
    var size: UInt64?
    var toolCallId: String? = nil
}

struct ChatAttachmentData: Codable, Sendable {
    var attachment: ChatAttachment
    var data: String
}

struct ChatEventChunk: Codable, Sendable {
    var events: [ChatTimelineEvent]
    var nextOffset: UInt64
    var tailCursor: String?

    var reset: Bool
    var hasMore: Bool

    enum CodingKeys: String, CodingKey { case events, nextOffset, tailCursor, reset, hasMore }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextOffset = try c.decodeIfPresent(UInt64.self, forKey: .nextOffset) ?? 0
        tailCursor = try c.decodeIfPresent(String.self, forKey: .tailCursor)
        reset = try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        events = (try c.decodeIfPresent([FailableChatEvent].self, forKey: .events) ?? [])
            .compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(events, forKey: .events)
        try c.encode(nextOffset, forKey: .nextOffset)
        try c.encodeIfPresent(tailCursor, forKey: .tailCursor)
        try c.encode(reset, forKey: .reset)
        try c.encode(hasMore, forKey: .hasMore)
    }
}

struct ChatEventPage: Codable, Sendable {
    var events: [ChatTimelineEvent]
    var nextOffset: UInt64
    var tailCursor: String?
    var cursor: String?
    var hasEarlier: Bool
    var historyTrimmed: Bool
    var reset: Bool
    var usage: ChatUsageTotals?

    enum CodingKeys: String, CodingKey {
        case events, nextOffset, tailCursor, cursor, hasEarlier, historyTrimmed, reset, usage
    }

    init(events: [ChatTimelineEvent], nextOffset: UInt64, cursor: String? = nil,
         hasEarlier: Bool = false, reset: Bool = false, usage: ChatUsageTotals? = nil, tailCursor: String? = nil, historyTrimmed: Bool = false) {
        self.events = events
        self.nextOffset = nextOffset
        self.tailCursor = tailCursor
        self.cursor = cursor
        self.hasEarlier = hasEarlier
        self.historyTrimmed = historyTrimmed
        self.reset = reset
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextOffset = try c.decodeIfPresent(UInt64.self, forKey: .nextOffset) ?? 0
        tailCursor = try c.decodeIfPresent(String.self, forKey: .tailCursor)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        hasEarlier = try c.decodeIfPresent(Bool.self, forKey: .hasEarlier) ?? false
        historyTrimmed = try c.decodeIfPresent(Bool.self, forKey: .historyTrimmed) ?? false
        reset = try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false
        usage = try c.decodeIfPresent(ChatUsageTotals.self, forKey: .usage)
        events = (try c.decodeIfPresent([FailableChatEvent].self, forKey: .events) ?? [])
            .compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(events, forKey: .events)
        try c.encode(nextOffset, forKey: .nextOffset)
        try c.encodeIfPresent(tailCursor, forKey: .tailCursor)
        try c.encodeIfPresent(cursor, forKey: .cursor)
        try c.encode(hasEarlier, forKey: .hasEarlier)
        try c.encode(historyTrimmed, forKey: .historyTrimmed)
        try c.encode(reset, forKey: .reset)
        try c.encodeIfPresent(usage, forKey: .usage)
    }
}

private struct FailableChatEvent: Decodable {
    var value: ChatTimelineEvent?
    init(from decoder: Decoder) throws {
        value = try? ChatTimelineEvent(from: decoder)
    }
}


struct ChatInstructions: Codable, Sendable, Hashable {
    var brief: String
    var added: String
    var channel: String

    var travelsAsSystemPrompt: Bool { channel == "systemPrompt" }
}

struct ChatApproval: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var conversationID: String
    var verb: String
    var preview: String
    var shellPrefix: String?
    var createdAtMs: Int64
    var expiresAtMs: Int64
    var decision: String?
    var readOnly: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversationId"
        case verb, preview, shellPrefix, createdAtMs, expiresAtMs, decision, readOnly
    }
}
extension ChatApproval {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        conversationID = readOnly ? "" : try c.decode(String.self, forKey: .conversationID)
        verb = try c.decode(String.self, forKey: .verb)
        preview = try c.decode(String.self, forKey: .preview)
        shellPrefix = try c.decodeIfPresent(String.self, forKey: .shellPrefix)
        createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        expiresAtMs = try c.decode(Int64.self, forKey: .expiresAtMs)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
    }
}


/// An agent CLI the daemon can run: a backend, a prompt, a workspace, and a
/// schedule with a budget the run stops at.
struct Automation: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var backend: String
    var model: String?
    var effort: String?
    var workspaceID: String
    var prompt: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
    var enabled: Bool
    var lastRunAtMs: Int64?
    var nextRunAtMs: Int64?
    var lastRunID: String?
    var revision: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name, backend, model, effort, workspaceID = "workspaceId", prompt, schedule
        case budgetSeconds, enabled, lastRunAtMs, nextRunAtMs, lastRunID = "lastRunId", revision
    }

    init(
        id: String,
        name: String,
        backend: String,
        model: String? = nil,
        effort: String? = nil,
        workspaceID: String,
        prompt: String,
        schedule: AutomationSchedule,
        budgetSeconds: UInt64,
        enabled: Bool,
        lastRunAtMs: Int64? = nil,
        nextRunAtMs: Int64? = nil,
        lastRunID: String? = nil,
        revision: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.model = model
        self.effort = effort
        self.workspaceID = workspaceID
        self.prompt = prompt
        self.schedule = schedule
        self.budgetSeconds = budgetSeconds
        self.enabled = enabled
        self.lastRunAtMs = lastRunAtMs
        self.nextRunAtMs = nextRunAtMs
        self.lastRunID = lastRunID
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        backend = try values.decode(String.self, forKey: .backend)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        prompt = try values.decode(String.self, forKey: .prompt)
        schedule = try values.decode(AutomationSchedule.self, forKey: .schedule)
        budgetSeconds = try values.decode(UInt64.self, forKey: .budgetSeconds)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        lastRunAtMs = try values.decodeIfPresent(Int64.self, forKey: .lastRunAtMs)
        nextRunAtMs = try values.decodeIfPresent(Int64.self, forKey: .nextRunAtMs)
        lastRunID = try values.decodeIfPresent(String.self, forKey: .lastRunID)
        revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    }

    var lastRun: Date? { lastRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var nextRun: Date? { nextRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    var payload: [String: Any] {
        [
            "id": id, "name": name, "backend": backend,
            "model": model as Any, "effort": effort as Any, "workspaceId": workspaceID,
            "prompt": prompt,
            "schedule": [
                "kind": schedule.kind.rawValue,
                "everySeconds": schedule.everySeconds,
                "hour": schedule.hour,
                "minute": schedule.minute,
                "weekday": schedule.weekday,
                "weekdays": schedule.weekdays,
            ],
            "budgetSeconds": budgetSeconds, "enabled": enabled,
            "lastRunAtMs": lastRunAtMs as Any, "nextRunAtMs": nextRunAtMs as Any,
            "lastRunId": lastRunID as Any,
            "revision": revision,
        ]
    }
}

struct AutomationCreationOutcome: Codable, Equatable, Sendable {
    var operationID: String
    var jobID: String
    var createdAtMs: Int64
    var job: Automation?

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case jobID = "jobId"
        case createdAtMs, job
    }
}

struct AutomationSchedule: Codable, Sendable, Hashable {
    var kind: ScheduleKind
    var everySeconds: UInt64
    var hour: Int
    var minute: Int
    var weekday: Int
    var weekdays: Int

    enum CodingKeys: String, CodingKey {
        case kind, everySeconds, hour, minute, weekday, weekdays
    }

    init(
        kind: ScheduleKind,
        everySeconds: UInt64 = 0,
        hour: Int = 9,
        minute: Int = 0,
        weekday: Int = 0,
        weekdays: Int = 0
    ) {
        self.kind = kind
        self.everySeconds = everySeconds
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.weekdays = weekdays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ScheduleKind.self, forKey: .kind)
        everySeconds = try c.decodeIfPresent(UInt64.self, forKey: .everySeconds) ?? 0
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 0
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 0
        weekdays = try c.decodeIfPresent(Int.self, forKey: .weekdays) ?? 0
    }

    static let `default` = AutomationSchedule(kind: .once, everySeconds: 3600, hour: 9, minute: 0, weekday: 0)
    static let weekdaysMask = 0b0001_1111

    var summary: String {
        let time = String(format: "%d:%02d", hour, minute)
        switch kind {
        case .once: return L10n.text("apple.models.once_when_you_run_it.cbb9301d")
        case .interval:
            let minutes = everySeconds / 60
            if minutes >= 60, minutes % 60 == 0 {
                let hours = minutes / 60
                return (hours == 1 ? L10n.text("apple.models.every_0_hour_1.ed193624.one", "\(hours)") : L10n.text("apple.models.every_0_hour_1.ed193624.other", "\(hours)"))
            }
            return (minutes == 1 ? L10n.text("apple.models.every_0_minute_1.fd623530.one", "\(minutes)") : L10n.text("apple.models.every_0_minute_1.fd623530.other", "\(minutes)"))
        case .daily: return L10n.text("apple.models.daily_at_0.c0d8484c", "\(time)")
        case .weekdays: return L10n.text("apple.models.weekdays_at_0.6459d30a", "\(time)")
        case .weekly:
            if weekdays & 0b0111_1111 != 0 {
                return L10n.text("apple.models.0_at_1.f0a220c8", "\(Self.dayList(weekdays))", "\(time)")
            }
            let names = [L10n.text("apple.models.monday.6a00dfc1"), L10n.text("apple.models.tuesday.7d8af1de"), L10n.text("apple.models.wednesday.c0a6cc82"), L10n.text("apple.models.thursday.fc266206"), L10n.text("apple.models.friday.e21f3f37"), L10n.text("apple.models.saturday.dbe35c73"), L10n.text("apple.models.sunday.873fef76")]
            let day = weekday >= 0 && weekday < 7 ? names[weekday] : "?"
            return L10n.text("apple.models.0_at_1.f0a220c8", "\(day)", "\(time)")
        case .custom:
            let days = Self.dayList(weekdays)
            if days.isEmpty { return L10n.text("apple.models.custom_at_0.55fdfc5a", "\(time)") }
            return L10n.text("apple.models.0_at_1.f0a220c8", "\(days)", "\(time)")
        }
    }

    var repeats: Bool { kind != .once }

    private static func dayList(_ mask: Int) -> String {
        let short = [L10n.text("apple.models.mon.f40d7f51"), L10n.text("apple.models.tue.d1eb39b0"), L10n.text("apple.models.wed.58339f45"), L10n.text("apple.models.thu.7da11212"), L10n.text("apple.models.fri.66dab40c"), L10n.text("apple.models.sat.fdeb71b5"), L10n.text("apple.models.sun.db18f17f")]
        return (0..<7).compactMap { bit -> String? in
            (mask & (1 << bit)) != 0 ? short[bit] : nil
        }.joined(separator: ", ")
    }
}

enum ScheduleKind: String, Codable, Sendable, Hashable, CaseIterable {
    case once
    case interval
    case daily
    case weekdays
    case weekly
    case custom

    var label: String {
        switch self {
        case .once: return L10n.text("apple.models.once.d88f6d83")
        case .interval: return L10n.text("apple.models.interval.6f45b000")
        case .daily: return L10n.text("apple.models.daily.b36c2611")
        case .weekdays: return L10n.text("apple.models.weekdays.6f4b602b")
        case .weekly: return L10n.text("apple.models.weekly.29751324")
        case .custom: return L10n.text("apple.models.custom.494ca78f")
        }
    }
}

struct RunRecord: Codable, Sendable, Identifiable {
    var id: String
    var jobId: String
    var name: String
    var backend: String
    var workspaceID: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var exitCode: Int?
    var status: String
    var transcriptPath: String
    var ptyID: String?
    var interactive: Bool?
    var parentRunID: String?

    enum CodingKeys: String, CodingKey {
        case id, jobId, name, backend, workspaceID = "workspaceId"
        case startedAtMs, endedAtMs, exitCode, status, transcriptPath, interactive
        case ptyID = "ptyId"
        case parentRunID = "parentRunId"
    }

    var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    var isRunning: Bool { ["starting", "queued", "running", "stopping"].contains(status) }
    var endedLabel: String {
        switch status {
        case "starting": return L10n.text("apple.models.starting.aeed4d26")
        case "queued": return L10n.text("common.queued")
        case "running": return L10n.text("common.running")
        case "stopping": return L10n.text("apple.models.stopping.a71ee1d4")
        case "ok": return L10n.text("common.done")
        case "stopped": return L10n.text("apple.models.stopped.1a4f630a")
        case "error": return L10n.text("common.failed")
        case "interrupted": return L10n.text("apple.models.interrupted_by_restart.012812fe")
        default: return status
        }
    }
}

struct AutomationRunSubmission: Codable, Equatable, Sendable {
    let operationID: String
    let jobID: String
    enum CodingKeys: String, CodingKey { case operationID = "operationId", jobID = "jobId" }
}

struct AutomationRunOutcome: Codable, Sendable {
    var operationID: String
    var jobID: String
    var runID: String
    var createdAtMs: Int64
    var job: Automation?
    var run: RunRecord?

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case jobID = "jobId"
        case runID = "runId"
        case createdAtMs, job, run
    }
}

struct AutomationQueue: Codable, Sendable {
    var defaultBudgetSeconds: UInt64
    var maxConcurrent: UInt32
    var timezone: String? = nil
}


struct WorkflowGraph: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var scope: WorkflowScope
    var workspaceID: String?
    var budgetSeconds: UInt64
    var schedule: AutomationSchedule
    var enabled: Bool
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
    var lastRunAtMs: Int64?
    var nextRunAtMs: Int64?
    var lastRunID: String?
    var revision: UInt64 = 0
    var extraFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, scope, workspaceID = "workspaceId"
        case budgetSeconds, schedule, enabled, nodes, edges
        case lastRunAtMs, nextRunAtMs, lastRunID = "lastRunId", revision
    }

    init(
        id: String = "",
        name: String,
        scope: WorkflowScope = .global,
        workspaceID: String? = nil,
        budgetSeconds: UInt64 = 10_800,
        schedule: AutomationSchedule = .default,
        enabled: Bool = false,
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        lastRunAtMs: Int64? = nil,
        nextRunAtMs: Int64? = nil,
        lastRunID: String? = nil,
        revision: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.workspaceID = workspaceID
        self.budgetSeconds = budgetSeconds
        self.schedule = schedule
        self.enabled = enabled
        self.nodes = nodes
        self.edges = edges
        self.lastRunAtMs = lastRunAtMs
        self.nextRunAtMs = nextRunAtMs
        self.lastRunID = lastRunID
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        scope = try c.decodeIfPresent(WorkflowScope.self, forKey: .scope) ?? .global
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        budgetSeconds = try c.decodeIfPresent(UInt64.self, forKey: .budgetSeconds) ?? 10_800
        schedule = try c.decodeIfPresent(AutomationSchedule.self, forKey: .schedule) ?? .default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        nodes = try c.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? []
        lastRunAtMs = try c.decodeIfPresent(Int64.self, forKey: .lastRunAtMs)
        nextRunAtMs = try c.decodeIfPresent(Int64.self, forKey: .nextRunAtMs)
        lastRunID = try c.decodeIfPresent(String.self, forKey: .lastRunID)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        extraFields = try UnknownFields.decode(
            from: decoder,
            known: Set(CodingKeys.allCases.map(\.stringValue))
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try c.encode(budgetSeconds, forKey: .budgetSeconds)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(edges, forKey: .edges)
        try c.encodeIfPresent(lastRunAtMs, forKey: .lastRunAtMs)
        try c.encodeIfPresent(nextRunAtMs, forKey: .nextRunAtMs)
        try c.encodeIfPresent(lastRunID, forKey: .lastRunID)
        try c.encode(revision, forKey: .revision)
        try UnknownFields.encode(extraFields, to: encoder)
    }

    var lastRun: Date? { lastRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var nextRun: Date? { nextRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    static func blank(name: String = L10n.text("apple.models.untitled.f59ab8d1"), scope: WorkflowScope = .global, workspaceID: String? = nil) -> WorkflowGraph {
        WorkflowGraph(
            name: name,
            scope: scope,
            workspaceID: workspaceID,
            nodes: [WorkflowNode(id: "in", kind: .input, x: 80, y: 120, title: L10n.text("common.start"))]
        )
    }

    mutating func layoutIfNeeded() {
        guard !nodes.isEmpty else { return }
        if nodes.contains(where: { $0.x != 0 || $0.y != 0 }) { return }

        let layer = WorkflowLayering.depths(nodes: nodes, edges: edges)

        var siblingInLayer: [Int: Int] = [:]
        for idx in nodes.indices {
            let depth = layer[nodes[idx].id] ?? 0
            let sibling = siblingInLayer[depth] ?? 0
            siblingInLayer[depth] = sibling + 1
            nodes[idx].x = 80 + Double(sibling) * 252
            nodes[idx].y = 80 + Double(depth) * 160
        }
    }
}

enum WorkflowScope: String, Codable, Sendable, Hashable, CaseIterable {
    case global
    case workspace

    var label: String {
        switch self {
        case .global: return L10n.text("apple.models.global.a258b30f")
        case .workspace: return L10n.text("apple.models.this_project.d0f62545")
        }
    }
}

enum WorkflowNodeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case input
    case agent
    case automation
    case http
    case command
    case gate
    case condition
    case loop
    case mcp

    var label: String {
        switch self {
        case .input: return L10n.text("apple.models.input.36ecb4f8")
        case .agent: return L10n.text("apple.models.agent.11b39c93")
        case .automation: return L10n.text("apple.models.automation.d909750b")
        case .http: return L10n.text("apple.models.http.56d6f321")
        case .command: return L10n.text("apple.models.command.71316697")
        case .gate: return L10n.text("apple.models.gate.fa77a525")
        case .condition: return L10n.text("apple.models.if.1e3abf61")
        case .loop: return L10n.text("apple.models.loop.f2f6a018")
        case .mcp: return L10n.text("apple.models.mcp.53f13ae9")
        }
    }

    var mark: String {
        switch self {
        case .input: return "mark_todo"
        case .agent: return "mark_workflow"
        case .automation: return "mark_automation"
        case .http: return "mark_sync"
        case .command: return "mark_terminal"
        case .gate: return "mark_note"
        case .condition: return "mark_plan"
        case .loop: return "mark_scheduler"
        case .mcp: return "mark_host"
        }
    }
}

enum WorkflowEdgeWhen: String, Codable, Sendable, Hashable {
    case ok
    case error
    case always

    var label: String {
        switch self {
        case .ok: return L10n.text("apple.models.on_success.97a99d2e")
        case .error: return L10n.text("apple.models.on_error.deef8196")
        case .always: return L10n.text("apple.models.always.9cdc6c47")
        }
    }
}

struct WorkflowNode: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: WorkflowNodeKind
    var x: Double
    var y: Double
    var title: String
    var backend: String?
    var model: String?
    var effort: String?
    var prompt: String?
    var wait: String?
    var waitPattern: String?
    var automationID: String?
    var promptOverride: String?
    var method: String?
    var url: String?
    var headers: [String: String]?
    var body: String?
    var command: String?
    var test: String?
    var pattern: String?
    var times: UInt32?
    var until: String?
    var extraFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, x, y, title, backend, model, effort, prompt, wait
        case waitPattern, automationID = "automationId", promptOverride
        case method, url, headers, body, command, test, pattern, times, until
    }

    init(
        id: String,
        kind: WorkflowNodeKind,
        x: Double = 0,
        y: Double = 0,
        title: String = "",
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        prompt: String? = nil,
        wait: String? = nil,
        waitPattern: String? = nil,
        automationID: String? = nil,
        promptOverride: String? = nil,
        method: String? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        body: String? = nil,
        command: String? = nil,
        test: String? = nil,
        pattern: String? = nil,
        times: UInt32? = nil,
        until: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.title = title
        self.backend = backend
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.wait = wait
        self.waitPattern = waitPattern
        self.automationID = automationID
        self.promptOverride = promptOverride
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.command = command
        self.test = test
        self.pattern = pattern
        self.times = times
        self.until = until
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(WorkflowNodeKind.self, forKey: .kind) ?? .input
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        wait = try c.decodeIfPresent(String.self, forKey: .wait)
        waitPattern = try c.decodeIfPresent(String.self, forKey: .waitPattern)
        automationID = try c.decodeIfPresent(String.self, forKey: .automationID)
        promptOverride = try c.decodeIfPresent(String.self, forKey: .promptOverride)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        test = try c.decodeIfPresent(String.self, forKey: .test)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        times = try c.decodeIfPresent(UInt32.self, forKey: .times)
        until = try c.decodeIfPresent(String.self, forKey: .until)
        extraFields = try UnknownFields.decode(
            from: decoder,
            known: Set(CodingKeys.allCases.map(\.stringValue))
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(backend, forKey: .backend)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(wait, forKey: .wait)
        try c.encodeIfPresent(waitPattern, forKey: .waitPattern)
        try c.encodeIfPresent(automationID, forKey: .automationID)
        try c.encodeIfPresent(promptOverride, forKey: .promptOverride)
        try c.encodeIfPresent(method, forKey: .method)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(test, forKey: .test)
        try c.encodeIfPresent(pattern, forKey: .pattern)
        try c.encodeIfPresent(times, forKey: .times)
        try c.encodeIfPresent(until, forKey: .until)
        try UnknownFields.encode(extraFields, to: encoder)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind.label
    }

    var subtitle: String {
        switch kind {
        case .input:
            return L10n.text("apple.models.starting_prompt.407bec2f")
        case .agent:
            return [backend, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .automation:
            return automationID ?? L10n.text("apple.models.run_automation.4c10763f")
        case .http:
            let verb = (method?.isEmpty == false ? method! : "GET")
            return [verb, url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case .command:
            return command ?? prompt ?? L10n.text("apple.models.command.71316697")
        case .gate:
            return L10n.text("apple.models.waits_for_you.0851c4a2")
        case .condition:
            return pattern?.isEmpty == false ? (pattern ?? L10n.text("apple.models.if.1e3abf61")) : L10n.text("apple.models.then_or_else.2318a255")
        case .loop:
            if let until, !until.isEmpty { return L10n.text("apple.models.until_0.b5b51017", "\(until)") }
            let n = times ?? 3
            return "\(n)×"
        case .mcp:
            return L10n.text("apple.models.reserved.3385ffe6")
        }
    }
}

struct WorkflowEdge: Codable, Sendable, Hashable, Identifiable {
    var from: String
    var to: String
    var when: WorkflowEdgeWhen

    var id: String { "\(from)>\(to):\(when.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case from, to, when
    }

    init(from: String, to: String, when: WorkflowEdgeWhen = .ok) {
        self.from = from
        self.to = to
        self.when = when
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        when = try c.decodeIfPresent(WorkflowEdgeWhen.self, forKey: .when) ?? .ok
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(when, forKey: .when)
    }
}

struct WorkflowStep: Codable, Sendable, Hashable, Identifiable {
    var nodeID: String
    var kind: String
    var title: String
    var status: String
    var output: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var exitCode: Int?

    var id: String { nodeID }

    enum CodingKeys: String, CodingKey {
        case nodeID = "nodeId", kind, title, status, output
        case startedAtMs, endedAtMs, exitCode
    }

    var endedLabel: String {
        WorkflowRunRecord.label(for: status)
    }
}

struct WorkflowRunRecord: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var workflowID: String
    var name: String
    var workspaceID: String
    var input: String
    var status: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var currentNodeID: String?
    var steps: [WorkflowStep]
    var budgetSeconds: UInt64

    enum CodingKeys: String, CodingKey {
        case id, workflowID = "workflowId", name, workspaceID = "workspaceId"
        case input, status, startedAtMs, endedAtMs
        case currentNodeID = "currentNodeId", steps, budgetSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workflowID = try c.decodeIfPresent(String.self, forKey: .workflowID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID) ?? ""
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        startedAtMs = try c.decodeIfPresent(Int64.self, forKey: .startedAtMs) ?? 0
        endedAtMs = try c.decodeIfPresent(Int64.self, forKey: .endedAtMs)
        currentNodeID = try c.decodeIfPresent(String.self, forKey: .currentNodeID)
        steps = try c.decodeIfPresent([WorkflowStep].self, forKey: .steps) ?? []
        budgetSeconds = try c.decodeIfPresent(UInt64.self, forKey: .budgetSeconds) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workflowID, forKey: .workflowID)
        try c.encode(name, forKey: .name)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(input, forKey: .input)
        try c.encode(status, forKey: .status)
        try c.encode(startedAtMs, forKey: .startedAtMs)
        try c.encodeIfPresent(endedAtMs, forKey: .endedAtMs)
        try c.encodeIfPresent(currentNodeID, forKey: .currentNodeID)
        try c.encode(steps, forKey: .steps)
        try c.encode(budgetSeconds, forKey: .budgetSeconds)
    }

    var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    var isLive: Bool { status == "running" || status == "waiting" }
    var isWaiting: Bool { status == "waiting" }

    var endedLabel: String { Self.label(for: status) }

    static func label(for status: String) -> String {
        switch status {
        case "queued": return L10n.text("common.queued")
        case "running": return L10n.text("common.working")
        case "waiting": return L10n.text("apple.models.needs_attention.c1ebc781")
        case "ok": return L10n.text("common.done")
        case "stopped": return L10n.text("apple.models.stopped.1a4f630a")
        case "error": return L10n.text("common.failed")
        case "interrupted": return L10n.text("apple.models.interrupted_by_restart.012812fe")
        default: return status
        }
    }
}

struct WorkflowDesignResult: Codable, Sendable {
    var workflow: WorkflowGraph
    var transcript: String
}

struct TranscriptChunk: Codable, Sendable {
    var text: String
    var nextOffset: UInt64
}

struct InteractiveCommandArgv: Codable, Sendable {
    var argv: [String]
}

struct AgentBackend: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var command: String
    var models: [String]
    var efforts: [String]

    init(id: String, label: String, command: String, models: [String] = [], efforts: [String] = []) {
        self.id = id
        self.label = label
        self.command = command
        self.models = models
        self.efforts = efforts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        command = try c.decode(String.self, forKey: .command)
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
    }
}


enum TodoKind: String, Codable, Sendable, Hashable {
    case task
    case note
}

struct TodoCard: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var revision: UInt64?
    var title: String
    var kind: TodoKind
    var notes: String
    var column: String
    var order: Int64
    var priority: String
    var backend: String
    var model: String?
    var effort: String?
    var workspaceID: String
    var budgetSeconds: UInt64
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var delegate: TodoDelegate?

    enum CodingKeys: String, CodingKey {
        case id, revision, title, notes, column, order, priority, backend, model, effort
        case kind
        case workspaceID = "workspaceId", budgetSeconds, createdAtMs, updatedAtMs, delegate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        revision = try values.decodeIfPresent(UInt64.self, forKey: .revision)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decodeIfPresent(TodoKind.self, forKey: .kind) ?? .task
        notes = try values.decode(String.self, forKey: .notes)
        column = try values.decode(String.self, forKey: .column)
        order = try values.decode(Int64.self, forKey: .order)
        priority = try values.decodeIfPresent(String.self, forKey: .priority) ?? "normal"
        backend = try values.decode(String.self, forKey: .backend)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        budgetSeconds = try values.decode(UInt64.self, forKey: .budgetSeconds)
        createdAtMs = try values.decode(Int64.self, forKey: .createdAtMs)
        updatedAtMs = try values.decode(Int64.self, forKey: .updatedAtMs)
        delegate = try values.decodeIfPresent(TodoDelegate.self, forKey: .delegate)
    }

    var columnLabel: String {
        switch column {
        case "doing": return L10n.text("apple.models.doing.cd742c53")
        case "done": return L10n.text("common.done")
        case "archive": return L10n.text("common.archive")
        default: return L10n.text("apple.models.to_do.150d92c4")
        }
    }

    var isArchived: Bool { column == "archive" }

    var isNote: Bool { kind == .note }

    init(pendingNote text: String, workspaceID: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        id = "pending:\(UUID().uuidString)"
        revision = nil
        title = text
        kind = .note
        notes = ""
        column = "backlog"
        order = 0
        priority = "normal"
        backend = ""
        model = nil
        effort = nil
        self.workspaceID = workspaceID
        budgetSeconds = 0
        createdAtMs = now
        updatedAtMs = now
        delegate = nil
    }

    var cleanedModel: String {
        Self.cleanModelID(model ?? "")
    }

    var promptForRun: String {
        let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanModelID(_ raw: String) -> String {
        let first = raw.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).first
            .map(String.init) ?? raw
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = trimmed.firstIndex(where: \.isUppercase) {
            let prefix = String(trimmed[..<idx])
            if prefix.contains(where: { $0 == "-" || $0 == "." }) {
                return prefix
            }
        }
        return trimmed
    }
}

struct InteractiveTaskLaunch: Sendable {
    var workspaceID: String
    var backend: String
    var model: String?
    var effort: String?
    var prompt: String
    var title: String
}

struct TodoDelegate: Codable, Sendable, Hashable {
    var runId: String
    var status: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case runId, status, startedAtMs, endedAtMs, error
    }

    var isRunning: Bool { ["starting", "queued", "running", "stopping"].contains(status) }
    var label: String {
        switch status {
        case "starting": return L10n.text("apple.models.starting.aeed4d26")
        case "queued": return L10n.text("common.queued")
        case "running": return L10n.text("common.running")
        case "stopping": return L10n.text("apple.models.stopping.a71ee1d4")
        case "ok": return L10n.text("common.done")
        case "stopped": return L10n.text("apple.models.stopped.1a4f630a")
        case "error": return L10n.text("common.failed")
        default: return status
        }
    }
}

enum TaskRunPlacement: String, Codable, Sendable, Hashable {
    case background
    case foreground
}

struct TaskRunOutcome: Codable, Sendable {
    var operationID: String
    var cardID: String
    var runID: String
    var createdAtMs: Int64
    var placement: TaskRunPlacement
    var card: TodoCard?
    var run: RunRecord?

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case cardID = "cardId"
        case runID = "runId"
        case createdAtMs, placement, card, run
    }
}


struct PtyProgramStatus: Codable, Sendable, Hashable {
    var state: String
    var kind: String?
    var progress: Int?
    var app: String?
    var id: String?
    var revision: UInt64

    var attentionLabel: String? {
        guard state == "blocked" else { return nil }
        switch kind {
        case "permission": return L10n.text("common.needs_approval")
        case "question": return L10n.text("common.needs_answer")
        case "auth": return L10n.text("common.sign_in_required")
        default: return nil
        }
    }
}

struct PtySessionInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var command: String
    var cwd: String
    var workspaceID: String?
    var hidden: Bool?
    var rows: Int
    var cols: Int
    var alive: Bool
    var exitCode: Int?
    var totalBytes: UInt64
    var lastActivityAtMs: Int64?
    var startedAtMs: UInt64? = nil
    var activity: String?
    var cpuPercent: Double?
    var memoryMb: Double?
    var attention: String?
    var programStatus: PtyProgramStatus? = nil
    var tokens: UInt64?
    var costMicros: Int64?
    var costEstimated: Bool?
    var costComplete: Bool?
    var model: String?
    var contextUsed: UInt64?
    var contextWindow: UInt64?
    var contextEstimated: Bool?
    var billing: String?
    var sessionIdentities: SessionIdentities? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case cwd
        // The host spells it `workspaceId`, serde's camelCase for
        // `workspace_id`. Swift's own camelCase writes `workspaceID`.
        case workspaceID = "workspaceId"
        case hidden
        case rows
        case cols
        case alive
        case exitCode
        case totalBytes
        case lastActivityAtMs
        case startedAtMs
        case activity
        case cpuPercent
        case memoryMb
        case attention
        case programStatus
        case tokens
        case costMicros
        case costEstimated
        case costComplete
        case model
        case contextUsed
        case contextWindow
        case contextEstimated
        case billing
        case sessionIdentities
    }
}

struct PtyChunk: Decodable, Sendable {
    var bytes: Data
    var nextOffset: UInt64
    var dropped: UInt64
    var paused: Bool
    var exitCode: Int?
    var reportsExitStatus: Bool
    var outputEndOffset: UInt64?
    var reportsOutputEnd: Bool

    private enum CodingKeys: String, CodingKey {
        case data
        case nextOffset
        case dropped
        case paused
        case exitCode
        case outputEndOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .data)
        bytes = Data(base64Encoded: encoded) ?? Data()
        nextOffset = try container.decode(UInt64.self, forKey: .nextOffset)
        dropped = try container.decode(UInt64.self, forKey: .dropped)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        reportsExitStatus = container.contains(.exitCode)
        outputEndOffset = try container.decodeIfPresent(UInt64.self, forKey: .outputEndOffset)
        reportsOutputEnd = container.contains(.outputEndOffset)
    }
}


struct MachineIdentity: Codable, Sendable {
    let key: String
    let fingerprint: String
    let words: String?
    let label: String
    var labelIsChosen: Bool?
}

struct Peer: Codable, Sendable, Identifiable, Hashable {
    enum Trust: String, Codable, Sendable {
        case pending
        case approved
        case revoked
    }

    let key: String
    let fingerprint: String
    let words: String?
    let label: String
    let trust: Trust
    let address: String?
    let firstSeen: String
    let lastSeen: String

    var id: String { key }
}

struct RemoteStatus: Codable, Sendable {
    let tunnel: Bool
    let relayFallback: Bool?
    let tunnelOnline: Bool?
    let tunnelRegistered: Bool?
    let tunnelError: String?
    let key: String
    let fingerprint: String
    let words: String?
    let label: String
    let directCandidates: [RemoteDirectCandidate]?
    let traffic: RemoteTraffic?
}

struct RemoteTraffic: Codable, Sendable, Hashable {
    var directBytes: UInt64
    var relayBytes: UInt64
    var peers: [RemoteTrafficPeer]
}

struct RemoteTrafficPeer: Codable, Sendable, Hashable, Identifiable {
    var peer: String
    var label: String
    var route: String?
    var live: Int
    var idle: Int
    var id: String { peer }

    var routeLabel: String { Self.knownLabel(route) ?? L10n.text("common.unknown") }

    var knownRouteLabel: String? { Self.knownLabel(route) }

    static func knownLabel(_ route: String?) -> String? {
        switch route {
        case "direct": return L10n.text("apple.models.direct_connection.28d0ad54")
        case "relay": return L10n.text("apple.models.encrypted_relay.153d7b1c")
        default: return nil
        }
    }
}

struct RemoteDirectCandidate: Codable, Sendable {
    let kind: String
    let address: String
    let priority: Int
}

struct TunnelOutcome: Codable, Sendable {
    let tunnel: Bool
}

struct HostPolicy: Codable, Sendable {
    var alwaysOn: Bool
    var defaultAlwaysOn: Bool
    var hasInternalBattery: Bool
    var hostingActive: Bool
}

struct ProjectWorktree: Codable, Sendable, Identifiable {
    var path: String
    var head: String
    var branch: String?
    var locked: Bool
    var prunable: Bool
    var bare: Bool
    var id: String { path }
}

extension SSHHost {
    private enum LegacyKeys: String, CodingKey { case credentialID, jumpHostID, folderID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        initialDirectory = try c.decodeIfPresent(String.self, forKey: .initialDirectory)
        credentialID = try c.decodeIfPresent(String.self, forKey: .credentialID)
            ?? legacy.decodeIfPresent(String.self, forKey: .credentialID)
        jumpHostID = try c.decodeIfPresent(String.self, forKey: .jumpHostID)
            ?? legacy.decodeIfPresent(String.self, forKey: .jumpHostID)
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID)
            ?? legacy.decodeIfPresent(String.self, forKey: .folderID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        provider = try c.decodeIfPresent(SSHProviderReference.self, forKey: .provider)
        hostKeys = try c.decodeIfPresent([String].self, forKey: .hostKeys) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
        keepaliveSeconds = try c.decodeIfPresent(Int.self, forKey: .keepaliveSeconds) ?? 0
        env = try c.decodeIfPresent([SSHEnvPair].self, forKey: .env) ?? []
        agentForwarding = try c.decodeIfPresent(Bool.self, forKey: .agentForwarding) ?? false
        lastConnectedMs = try c.decodeIfPresent(Int64.self, forKey: .lastConnectedMs)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        sort = try c.decodeIfPresent(Int.self, forKey: .sort) ?? 0
        updatedMs = try c.decodeIfPresent(Int64.self, forKey: .updatedMs) ?? 0
    }
}

extension SSHFolder {
    private enum LegacyKeys: String, CodingKey { case parentID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
            ?? legacy.decodeIfPresent(String.self, forKey: .parentID)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        sort = try c.decodeIfPresent(Int.self, forKey: .sort) ?? 0
        updatedMs = try c.decodeIfPresent(Int64.self, forKey: .updatedMs) ?? 0
    }
}

extension SSHProviderReference {
    private enum LegacyKeys: String, CodingKey { case resourceID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        if c.contains(.resourceID) {
            resourceID = try c.decode(String.self, forKey: .resourceID)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            resourceID = try legacy.decode(String.self, forKey: .resourceID)
        }
    }
}

struct ClaudeLiveFeedState: Decodable, Equatable {
    var enabled: Bool
    var chained: Bool
    var lastReadingAtMs: Int64?
}
