// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI

// MARK: - SSH connections

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
    /// Nil is the top level. Every record saved before folders existed is
    /// there, and stays there until somebody moves it.
    var folderID: String?
    /// A name from `SSHColor`, never a hex string.
    var color: String?
    var keepaliveSeconds: Int = 0
    var env: [SSHEnvPair] = []
    var agentForwarding: Bool = false
    var lastConnectedMs: Int64?
    var favorite: Bool = false
    var sort: Int = 0
    /// When this record last changed. The vault merges on this: a pulled
    /// record is applied only when it is newer than the one already here.
    var updatedMs: Int64 = 0

    /// The address as somebody would type it into a terminal.
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
    /// When this record last changed. The vault merges on this: a pulled
    /// record is applied only when it is newer than the one already here.
    var updatedMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parentId"
        case color, sort, updatedMs
    }
}

/// The fixed palette both ends agree on.
///
/// Names rather than hex, so the record stays a record and each platform draws
/// its own idea of "amber". Mirrors `ssh_records::COLORS`.
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
    /// SHA256 fingerprint. What a row shows instead of the whole public key.
    var fingerprint: String = ""
    var createdMs: Int64 = 0
    var passphraseProtected: Bool = false
    /// When this record last changed. The vault merges on this: a pulled
    /// record is applied only when it is newer than the one already here.
    var updatedMs: Int64 = 0
}

struct SSHSnippet: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var command: String
    var tags: [String]
    var hostIDs: [String]
    /// Placeholder names in the command, asked for when it runs. Values are
    /// never stored: the useful ones are secrets.
    var variables: [String] = []
    var runOnConnect: Bool = false
    /// When this record last changed. The vault merges on this: a pulled
    /// record is applied only when it is newer than the one already here.
    var updatedMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, command, tags
        case hostIDs = "hostIds"
        case variables, runOnConnect, updatedMs
    }

    /// Spelled out rather than synthesized, to accept `hostIDs` as well.
    ///
    /// The vault carries whatever shape this app encoded, and older builds
    /// encoded the misspelled key. Those records are already in somebody's
    /// vault, and a snippet that decodes into nothing is a snippet that is
    /// gone: `pullVault` drops a record it cannot read and never asks again.
    /// The wrong spelling is only ever read, never written.
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

    /// The spelling older builds wrote into the vault. Read-only.
    private enum LegacyKeys: String, CodingKey {
        case hostIDs
    }

    /// The bytes a shell has to receive for a command to actually run.
    ///
    /// The trailing carriage return is the whole point. These screens used to
    /// type the line at the prompt and stop, on the reasoning that a saved
    /// command should be read before it fires. In practice a snippet is a
    /// command somebody saved in order to run it, and leaving it sitting at
    /// the prompt meant every use of the feature ended with reaching for the
    /// keyboard, which on a phone means dismissing the menu first.
    ///
    /// One function rather than three call sites appending "\r", because
    /// three call sites is how the Mac inspector, the Mac tab strip and the
    /// phone's key bar came to disagree about anything in the first place.
    static func bytesToRun(_ command: String) -> [UInt8] {
        Array((command + "\r").utf8)
    }

    /// `{{name}}` occurrences, in the order they appear. The editor keeps
    /// `variables` in step with this so a client never has to parse it.
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

    /// The command with every placeholder replaced. Missing values are left
    /// alone rather than blanked, so a half-filled form cannot silently run a
    /// different command.
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

/// One session the host is holding, as `ssh.session.list` reports it.
///
/// The sessions live in the host process, not in the app, so this is how a
/// relaunched app finds the shells it left running. The same relationship
/// `pty.list` has always had with the workspace terminals.
struct SSHSessionSummary: Codable, Sendable, Hashable, Identifiable {
    var id: String
    /// The saved record it was opened from, when it was opened from one.
    var hostID: String?
    var label: String
    var openedMs: Int64
    var alive: Bool
    /// Output the host had to drop before anybody read it, in bytes.
    var droppedBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "hostId"
        case label, openedMs, alive, droppedBytes
    }
}
struct SSHHostFingerprint: Codable, Sendable, Hashable { var fingerprint: String }
struct SSHSessionRead: Codable, Sendable, Hashable {
    var data: [UInt8]
    var nextOffset: UInt64
    var dropped: Bool
    var closed: Bool
    var error: String?
}

struct SSHKeyMaterial: Codable, Sendable, Hashable {
    var algorithm: String
    var publicKey: String
    var fingerprint: String
    var privateKey: String
}

struct SSHVaultStatus: Codable, Sendable, Hashable {
    var created: Bool
    var recordCount: Int
    var enrolled: Bool?
    /// The vault exists and this device has no key for it yet, so the password
    /// has to be typed before anything can be read.
    var locked: Bool?
    /// Made before password unlock existed. It cannot be opened by this build,
    /// so the screen offers to recreate it rather than asking for a password
    /// nothing will accept.
    var needsRecreate: Bool?
    /// Why the account could not be asked, when it could not be asked.
    ///
    /// `created: false` means "this account has no vault". It used to mean
    /// that *or* "the question never reached the account", which are opposite
    /// situations: the first invites you to make one, the second means the one
    /// you already have is out of reach and making another would be refused.
    var unreachable: String?
}
struct SSHVaultReset: Codable, Sendable, Hashable { var reset: Bool }
struct SSHVaultRecovery: Codable, Sendable, Hashable { var recovery: String }
/// A password change. Carries a fresh recovery code only when the change was a
/// reset, because a reset retires the code it just spent.
struct SSHVaultPasswordChange: Codable, Sendable, Hashable {
    var changed: Bool
    var recovery: String?
}
struct SSHVaultUnlock: Codable, Sendable, Hashable { var unlocked: Bool }
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
/// What the person watching asked the picture to be worth.
///
/// A closed set with wire names the host knows, never a number: nothing
/// arbitrary crosses that boundary. Auto is the default and means the host
/// decides from the route, which is the answer almost everybody wants.
enum ScreenQualityChoice: String, CaseIterable, Identifiable, Sendable {
    case auto
    case sharp
    case smooth
    case dataSaver

    var id: String { rawValue }

    /// Nil for auto: the absence of a choice, rather than a choice called auto.
    var wire: String? { self == .auto ? nil : rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .sharp: return "Sharp"
        case .smooth: return "Smooth"
        case .dataSaver: return "Data saver"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Best the connection allows"
        case .sharp: return "Every detail, on a fast link"
        case .smooth: return "Steady over the relay"
        case .dataSaver: return "Least data, softest picture"
        }
    }
}

/// What one screen session may spend, and how finely it may spend it.
///
/// These four numbers used to be constants inside the encoder, chosen for the
/// relay because that was the only route there was. A direct connection is the
/// person's own bandwidth, so the same desktop can be several times sharper on
/// it and cost nobody anything.
struct ScreenQualityProfile: Sendable, Hashable {
    /// The widest picture to encode. The capture is scaled down to this, so a
    /// 5K display is not sent at 5K over anything.
    var maxWidth: CGFloat
    var averageBitRate: Int
    /// Pictures per second while watching, and while driving.
    ///
    /// A pointer is the one thing on a remote desktop judged frame by frame,
    /// and at thirty a drag arrives in visible steps however good each step
    /// looks. Watching has no such test.
    var viewingFPS: Int32
    var controlFPS: Int32
    /// Seconds between keyframes. A keyframe is the expensive picture, and on
    /// a desktop nobody is touching it is the only traffic there is.
    var keyframeSeconds: Int32

    /// Today's numbers, unchanged. Everything metered stays here.
    ///
    /// 1.5 Mbps, not 4: four megabits is a number for a screen recording
    /// somebody keeps. This is a desktop being watched live, usually on a
    /// phone, over a relay somebody pays for by the gigabyte, and the
    /// difference on a screen that is mostly text and flat panels is not
    /// something a person notices on a handset.
    static let relay = ScreenQualityProfile(
        maxWidth: 1920,
        averageBitRate: 1_500_000,
        viewingFPS: 30,
        controlFPS: 60,
        keyframeSeconds: 4
    )

    /// A metered link somebody wants to keep cheap, or a poor one.
    static let dataSaver = ScreenQualityProfile(
        maxWidth: 1280,
        averageBitRate: 800_000,
        viewingFPS: 20,
        controlFPS: 30,
        keyframeSeconds: 4
    )

    /// The default on a direct route. Text is legible at native size rather
    /// than nearly legible, which is the whole difference between reading a
    /// terminal on the other machine and squinting at it.
    static let direct = ScreenQualityProfile(
        maxWidth: 2560,
        averageBitRate: 8_000_000,
        viewingFPS: 30,
        controlFPS: 60,
        keyframeSeconds: 2
    )

    /// Asked for by hand, on a link that can take it.
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
    /// How the viewer reached this machine: `direct` or `relay`. Absent from a
    /// host built before routes were carried, which reads as relay, the
    /// answer that spends nothing it should not.
    var route: String?
    /// What the viewer asked the picture to be worth, when it asked. Absent
    /// means it left the choice here.
    var quality: String?

    enum CodingKeys: String, CodingKey {
        case id
        case peerID = "peerId"
        case control, dropped, route, quality
    }

    /// The bandwidth budget this session may spend.
    ///
    /// A relay channel is metered and pueev pays for it by the gigabyte. A
    /// direct channel is the person's own network. The first has to stay
    /// frugal; the second can afford a far better picture for nothing, and
    /// spending the same 1.5 Mbps on it was leaving that on the table.
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
/// Everything queued for the capture helper since it last asked.
///
/// `data` is the head of `batch` and exists only so a helper built before
/// batching still gets its one event. Read `events`: a daemon built before
/// batching answers with `data` alone, and Swift's synthesized decoder honours
/// no default values, so `batch` is optional here and folded back in.
struct ScreenCaptureInput: Codable, Sendable, Hashable {
    var data: String?
    var batch: [String]? = nil

    var events: [String] { batch ?? data.map { [$0] } ?? [] }
}
/// A live viewer session. `id` is this end's handle; `sessionId` is the host's
/// own id for the same session, which is what `screen.control.set` names.
///
/// `sessionId` is optional because a host built before that method answers
/// without one, and the toggle then falls back to reopening the stream.
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

/// What the host said about a request this device just made. `granted` means
/// the permission was already there and there is nothing to wait for.
struct ScreenAccessAsk: Codable, Sendable, Hashable {
    var pending: Bool
    var granted: Bool?
}

/// What a device is asking this machine for.
///
/// Two grants, one shape. Being approved is not being let in: every device on
/// the account is auto-approved on first contact, so each of these is a
/// separate, explicit yes from whoever is at the machine.
enum DeviceAccessKind: String, Sendable, Hashable {
    /// Watch this screen, and possibly drive it.
    case screen
    /// Open the folders, files, terminals and agents on this machine.
    case workspace
}

/// A device waiting for an answer on this machine.
struct DeviceAccessPending: Codable, Sendable, Hashable, Identifiable {
    var peerID: String
    /// The account's name for that device, when it has one. A public key is
    /// not something anybody recognises their own phone by.
    var label: String?
    /// Whether mouse and keyboard were asked for as well as the picture.
    /// Always false for a workspace request: there is no half of that grant.
    var control: Bool
    var askedAt: UInt64
    var expiresAt: UInt64
    /// Set from the method the row came back on rather than read off the wire,
    /// so the two host policies stay unaware of each other.
    var kind: DeviceAccessKind = .screen

    /// One device can have both kinds of request standing at once, so the peer
    /// alone is not an identity here.
    var id: String { "\(kind.rawValue):\(peerID)" }

    enum CodingKeys: String, CodingKey {
        case peerID = "peerId"
        case label, control
        case askedAt, expiresAt
    }

    /// What to call it on screen. Falls back to the head of the key, which is
    /// what the rest of the app shows when the account knows no better.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        return "Device \(peerID.prefix(8))"
    }

    /// The one-line question, for a toast and for a notification title.
    var headline: String {
        switch kind {
        case .screen: return "\(displayName) wants to see this screen"
        case .workspace: return "\(displayName) wants to open your work"
        }
    }

    var detail: String {
        switch kind {
        case .screen:
            return control
                ? "It asked for the picture, and for mouse and keyboard."
                : "It asked for the picture only."
        case .workspace:
            return "Folders, files, terminals and the agents running in them."
        }
    }
}

/// Filters accepted by every reporting method.
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
        case .day: return "Day"
        case .week: return "Week"
        case .model: return "Model"
        case .project: return "Project"
        case .source: return "Harness"
        case .session: return "Session"
        }
    }
}

/// Token counters.
///
/// Every field is optional on purpose. "This tool does not report cache writes"
/// and "this tool reported zero cache writes" are different facts, and the
/// product's one unbreakable reporting rule is that they must not be collapsed.
struct Counters: Codable, Sendable, Hashable {
    var inputFresh: UInt64?
    var cacheRead: UInt64?
    var cacheWrite5m: UInt64?
    var cacheWrite1h: UInt64?
    var output: UInt64?
    var total: UInt64
    var inputTotal: UInt64
    var hasUnknown: Bool

    /// Fresh input plus output: what the work actually was, cache reads left
    /// out. They are the largest number in the archive by a wide margin and
    /// they measure how much context was re-sent, not how much was done.
    var workTokens: UInt64 {
        (inputFresh ?? 0) + (output ?? 0)
    }
}

/// One report row with its list-rate value.
struct Bucket: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var counters: Counters
    var events: UInt64
    var sessions: UInt64
    var valueMicros: Int64
    var estimated: Bool
    var unpricedModels: [String]

    var id: String { key }

    /// Never call this "spend" or "cost" in the UI. Subscription usage is
    /// valued the same way, so this is what the tokens were worth at list
    /// rates, not what anyone was billed.
    var value: Money {
        Money(micros: valueMicros, estimated: estimated, complete: unpricedModels.isEmpty)
    }
}

/// An account-plane breakdown and the moment it was fetched.
///
/// The date travels with the rows because a figure and its age are one fact.
/// The client shows it on any screen built from this, so a remembered answer
/// never poses as a current one.
struct AccountReport: Codable, Sendable, Hashable {
    var rows: [Bucket]
    /// Which dimension these are folded by, echoed back by the host so an
    /// answer that lands after the reader switched tabs can be discarded.
    var group: String
    var fetchedAtMs: Int64
    /// Served from cache because the refresh failed. The numbers are real, they
    /// are just old.
    var stale: Bool

    var fetchedAt: Date { Date(timeIntervalSince1970: Double(fetchedAtMs) / 1000) }
}

/// What one device contributed to the account over a window.
///
/// `sessions` is deliberately absent everywhere in this shape: the account
/// receives no session identifiers, so there is no honest number to show.
struct MachineUsage: Codable, Sendable, Hashable, Identifiable {
    /// The account's machine id, which is what a device row matches on.
    var machine: String
    var valueMicros: Int64
    var events: UInt64
    var activeDays: Int
    /// The window this covers, in days, so the screen labels it rather than
    /// assuming one.
    var days: Int

    var id: String { machine }

    /// List rates, never money charged. Same rule as `Bucket.value`.
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
    var message: String?
}

struct FileText: Codable, Sendable, Hashable {
    var path: String
    var content: String
}

// MARK: - Activity

/// One day of the activity grid.
struct HeatCell: Codable, Sendable, Hashable, Identifiable {
    /// `YYYY-MM-DD`. Kept as the archive's own string, which is also the format
    /// a `Query` filters by, so a click on a day can become a filter with no
    /// reformatting in between.
    var date: String
    /// What the day was worth at list rates, in microdollars. Spend rather than
    /// tokens, so the grid ranks a day by what it cost and not by how many
    /// cheap tokens went through it.
    var value: UInt64
    /// `0...4`. Zero is a day inside the range with no usage, which has to read
    /// as "nothing happened" and not as "no data".
    var level: Int
    /// Older than the plan's unlocked window. Shade may remain. Value is
    /// zero. Missing on an older host, which is not locked.
    var locked: Bool?

    var id: String { date }

    var isLocked: Bool { locked == true }
}

struct MonthLabel: Codable, Sendable, Hashable, Identifiable {
    var column: Int
    var name: String

    var id: Int { column }
}

/// The activity calendar, as the core computed it.
///
/// The rows arrive built. Do not rebuild the grid from a list of days: the
/// archive stores only days that had events, so packing them together draws a
/// plausible calendar with every date in the wrong column.
struct ActivityCalendar: Codable, Sendable, Hashable {
    /// Seven rows, Monday first. `nil` is a day outside the rendered range.
    var rows: [[HeatCell?]]
    var months: [MonthLabel]
    var weeks: Int
    /// Value of the whole grid at list rates, in microdollars, matching the
    /// unit every `HeatCell` carries.
    var total: UInt64
    var activeDays: Int
    /// Consecutive active days up to the most recent one with data. A quiet day
    /// that is not over yet does not break it.
    var streakCurrent: Int
    var streakBest: Int
    var busiest: HeatCell?
    var first: String
    var last: String
    /// Which grid this is: `"local"` or `"account"`. Optional because a peer
    /// running an older host does not send it, and a missing answer is local.
    var scope: String?
    /// Why this is not the grid that was asked for, in words to show.
    var notice: String?
    /// What kind of fallback this is, so the interface can act on it instead
    /// of parsing the sentence: `"auth"` (sign-in would fix it), `"upgrade"`
    /// (the account does not include it), `"other"`. Absent when the grid is
    /// the one asked for.
    var noticeCode: String?
    /// First unlocked day (`YYYY-MM-DD`). Days before this keep the year
    /// shape only. Missing when the whole grid is live.
    var unlockFrom: String?
    /// Free year: last month exact, older days muted. Same treatment as
    /// the public profile. Missing or false on a paid grid and on local.
    var historyLocked: Bool?
    /// How many recent days stay exact. The banner names this number.
    var historyDays: Int?
    /// Offer an upgrade under the grid. The app is the owner, so this is
    /// true whenever the year is locked.
    var historyUpgrade: Bool?
    /// When an account grid's numbers came off the service. Absent on a
    /// local grid, which is read from disk and is never a remembered answer.
    var fetchedAtMs: Int64?

    var isHistoryLocked: Bool { historyLocked == true }

    var fetchedAt: Date? {
        guard let fetchedAtMs, fetchedAtMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(fetchedAtMs) / 1000)
    }

    var isStaleGrid: Bool { noticeCode == "stale" }

    /// How current the account grid is, in the same words the limit cards use.
    var freshness: String? {
        guard let fetchedAt else { return nil }
        let ago = fetchedAt.formatted(.relative(presentation: .named))
        return isStaleGrid ? "stale, last updated \(ago)" : "updated \(ago)"
    }
}

// MARK: - Day detail

/// One day's hover detail, the same shape the profile page draws.
///
/// The heatmap cell carries one number so the grid can be built cheaply; this
/// is what sits behind a hovered day: the totals line plus every
/// `model × harness` slice, so the app and the website tell the same story
/// about the day.
struct DayDetail: Codable, Sendable, Hashable, Identifiable {
    /// `YYYY-MM-DD`, echoed so the popover never has to guess which day it is
    /// describing while a fetch races a hover change.
    var date: String
    var tokens: UInt64
    var events: UInt64
    var valueMicros: Int64
    var estimated: Bool
    var unpricedModels: [String]
    var rows: [DayPart]

    var id: String { date }

    /// List-rate value, with the same "not billed / floor" qualifiers money
    /// everywhere else carries.
    var value: Money {
        Money(micros: valueMicros, estimated: estimated, complete: unpricedModels.isEmpty)
    }
}

/// One `model × harness` slice of a day.
struct DayPart: Codable, Sendable, Hashable, Identifiable {
    var model: String
    /// The harness that recorded the events, e.g. `"codex"`.
    var src: String
    var fresh: UInt64?
    var cacheRead: UInt64?
    var cacheWrite5m: UInt64?
    var cacheWrite1h: UInt64?
    var output: UInt64?
    /// Sum of every known counter field, as the host sent it.
    var tokens: UInt64
    var events: UInt64

    var id: String { "\(src)\u{1}\(model)" }
}

/// Display label for a model id, matching tokenstat.ai.
///
/// Model ids are long and the useful part is at the end: "claude-opus-4-8"
/// reads fine, "claude-haiku-4-5-20251001" does not. Cursor's auto router logs
/// as bare "default"/"auto", which would otherwise render as a mystery.
func shortModel(_ id: String) -> String {
    let raw = id.trimmingCharacters(in: .whitespaces)
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

// MARK: - Syntax highlighting

/// What a run of source text is.
///
/// Mirrors `tokenstat_highlight::Kind`. The Rust side never sends a colour, so
/// the mapping from a kind to a colour lives in `Theme` and switching to light
/// mode is not a round trip through a parser.
enum SyntaxKind: String, Codable, Sendable, Hashable {
    case keyword
    case string
    case number
    case comment
    case type
    case function
    case constant
    case attribute
    case property
    case variable
    case `operator`
    case punctuation
    case markup
    /// A kind this build does not know. Newer core, older app: colour it as
    /// plain text rather than refusing to decode the whole file.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyntaxKind(rawValue: raw) ?? .unknown
    }
}

/// One coloured run.
///
/// `start` and `length` are **UTF-16 code units**, which is what `NSTextStorage`
/// indexes by, so they drop straight into an `NSRange` with no conversion. The
/// Rust side does that conversion in the pass it was already making.
struct SyntaxSpan: Codable, Sendable, Hashable {
    var start: Int
    var len: Int
    var kind: SyntaxKind

    var range: NSRange { NSRange(location: start, length: len) }
}

/// How a language is commented and indented.
///
/// Comes from the core so there is one table of these facts rather than one per
/// front end.
struct SyntaxRules: Codable, Sendable, Hashable {
    var lineComment: String?
    var blockComment: [String]?
    var indent: Int

    /// What pressing Tab inserts.
    var indentUnit: String { String(repeating: " ", count: max(1, indent)) }

    static let fallback = SyntaxRules(lineComment: nil, blockComment: nil, indent: 4)
}

/// The answer to a highlight request.
///
/// A file with no grammar and a file over the size limit both come back as a
/// successful call with an empty `spans` and a `note`. Neither is an error: the
/// file opened, it just is not colourable, and a red banner over a perfectly
/// good file is worse than plain text.
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
    /// Nil on a host that keeps no archive of its own, which is every mobile
    /// build. Not an empty string: "no archive" and "an archive nobody named"
    /// are different facts and must not render the same.
    var dbPath: String?
    /// Whether this host can answer about its own machine's logs. False on a
    /// client, where Insights comes from the account and nowhere else.
    var hasArchive: Bool
    var timezone: String
    var priceBookEffectiveFrom: String
    var hasPrices: Bool
}

/// What `pricing.refresh` fetched and loaded.
struct PricingRefresh: Codable, Sendable, Hashable {
    var effectiveFrom: String
    var models: UInt64
    var hasPrices: Bool
}

/// What `pricing.seed` did with the book this build ships with.
struct PricingSeed: Codable, Sendable, Hashable {
    /// False when the machine already had a book. Not a failure: a fetched
    /// book is newer than anything a bundle can carry.
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
    /// The signed, notarized disk image for this release, when it has one. A
    /// release cut before the app shipped has none, so this stays optional and
    /// the release page is the fallback.
    var dmgURL: String?

    enum CodingKeys: String, CodingKey {
        case current, latest, newer, htmlURL = "htmlUrl", dmgURL = "dmgUrl"
    }

    /// Where to send somebody who wants the update: the image if the release
    /// carries one, the release page otherwise.
    var downloadURL: URL? {
        URL(string: dmgURL ?? htmlURL)
    }

    var isAvailable: Bool { newer && latest != current }
}

/// Something the daemon fetched and checked, waiting on disk.
struct DownloadedFile: Codable, Sendable {
    var path: String
}

/// A list-rate value, carrying the two qualifiers it must never be shown
/// without.
struct Money: Sendable, Hashable {
    var micros: Int64
    /// At least one model was valued from an estimate rather than a published
    /// rate.
    var estimated: Bool
    /// Every model in the bucket could be priced. When false the figure is a
    /// floor, and presenting it as a total would understate silently.
    var complete: Bool

    var dollars: Double { Double(micros) / 1_000_000 }

    /// Rates are published in US dollars, so the figure is formatted as one
    /// regardless of where the user is. A Hungarian locale renders the same
    /// number as `6 786,57 US$`, which reads as a local amount and does not
    /// match the `$6,786.57` the CLI prints for the very same archive.
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
        let amount = Self.currency.string(from: NSNumber(value: dollars))
            ?? String(format: "$%.2f", dollars)
        // A floor reads as "at least this much", an estimate as "about this
        // much". Both must survive truncation, so they are never dropped.
        if !complete { return "\(amount)+" }
        if estimated { return "~\(amount)" }
        return amount
    }

    /// Why the figure carries a qualifier, for a tooltip. Nil when it does not.
    var caveat: String? {
        if !complete {
            return "At least one model here has no published rate, so the real figure is higher."
        }
        if estimated {
            return "Estimated from the model catalog, because the price book has no rate for this model."
        }
        return nil
    }
}

extension Sequence where Element == Bucket {
    /// Fold rows into one value, keeping the qualifiers. A total built from an
    /// incomplete row is itself incomplete.
    var totalValue: Money {
        reduce(Money(micros: 0, estimated: false, complete: true)) { acc, row in
            Money(
                micros: acc.micros + row.valueMicros,
                estimated: acc.estimated || row.estimated,
                complete: acc.complete && row.unpricedModels.isEmpty
            )
        }
    }
}

/// A heat value as money.
///
/// The activity calendar carries microdollars, not tokens: a day's colour is
/// what the day's work was worth at list rates, so a cheap high-volume day does
/// not outshine an expensive one. The qualifiers are dropped here because the
/// grid sends one number per day and the card above it already carries them.
func formatSpend(_ micros: UInt64) -> String {
    Money(micros: Int64(clamping: micros), estimated: false, complete: true).formatted
}

/// Compact token counts. 1.2B rather than 1,214,203,912, because these numbers
/// are read at a glance and compared, not audited.
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

// MARK: - Account

/// A device authorization the user has not confirmed yet.
///
/// No device code here. That secret stays in the Rust bridge, which is why
/// polling takes no arguments.
struct DeviceLogin: Codable, Sendable, Hashable {
    var host: String
    /// The short code the user reads. Shown large, because reading it off a
    /// screen is the one manual step in the whole flow.
    var userCode: String
    /// Where to send them. Usually already carries the code.
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

/// One poll's answer.
struct DevicePoll: Codable, Sendable, Hashable {
    var state: String
    var interval: UInt64?
    var handle: String?
    var host: String?
    var machine: String?

    var isConfirmed: Bool { state == "confirmed" }
}

/// Who is signed in.
struct Account: Codable, Sendable, Hashable {
    var signedIn: Bool
    var host: String
    var handle: String?
    /// The name the user chose to be shown as. The handle is the identifier,
    /// this is the label.
    var displayName: String?
    var tier: String?
    /// Profile picture URL, when the account has one.
    ///
    /// Absolute by the time it arrives. The API sends `/avatar/<name>`,
    /// relative on purpose so it never hands out a third-party URL, and
    /// `tokenstat-host` resolves it against the host the token authenticated
    /// to. Nil means this account has not set one, which is common and is not
    /// an error: draw a monogram.
    ///
    /// This comment used to say the field was always nil because the API did
    /// not send one. It does, and believing otherwise is why the phone drew a
    /// letter for an account with a picture.
    var avatar: String?
    /// When this account last synced, from any machine.
    ///
    /// Derived in the host from the machine list, because `/api/v1/me` carries
    /// a timestamp per machine and none for the account. Reading the top level
    /// gave nil, so the Account screen said "never" for an account that had
    /// synced minutes earlier.
    var lastSyncAt: String?
    /// The machine this app is running on, so the list below can say which row
    /// is the one you are sitting at.
    var thisMachineID: String?
    /// Server-side machine records. The shape belongs to the API, so this
    /// decodes the few fields the UI shows and ignores the rest.
    var machines: [Machine]
    var schemaCurrent: UInt32?
    /// Devices this plan may link. A computer, phone, or tablet each uses one.
    var machineLimit: Int?
    var hostsLinked: Int?
    /// Whether the relay will accept a HELLO from this account.
    var canRemote: Bool?
    var syncInterval: Int?
    /// Who billed the current plan. Present when signed in, even on Free.
    var billing: AccountBilling?

    /// `thisMachineId` on the wire. Spelling the acronym without saying so
    /// left it nil on every decode, so no row in the machine list was ever
    /// the one you are sitting at.
    enum CodingKeys: String, CodingKey {
        case signedIn, host, handle, displayName, tier, avatar, lastSyncAt
        case thisMachineID = "thisMachineId"
        case machines, schemaCurrent
        case machineLimit, hostsLinked, canRemote, syncInterval
        case billing
    }

    var hostMachines: [Machine] { machines.filter(\.isHost) }

    /// What to call this person on screen: their chosen name, or the handle
    /// when they have not set one.
    var title: String? {
        let name = displayName?.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty { return name }
        return handle
    }

    /// A paid rung, whether Apple, Paddle, or a grant such as founder access.
    var isPaidTier: Bool {
        switch tier?.lowercased() {
        case "supporter", "patron", "legend": return true
        default: return false
        }
    }

    /// SSH vault is Supporter and above. Same three rungs as `isPaidTier`.
    var allowsVaultSync: Bool { isPaidTier }

    /// What the SSH vault UI and host methods take as `tier`.
    ///
    /// A signed-in paid account whose `/me` tier is missing still passes
    /// `legend` rather than `free`, so a grant cannot be mapped to unpaid.
    var vaultTierForSsh: String? {
        guard signedIn else { return nil }
        if allowsVaultSync { return tier?.lowercased() ?? "legend" }
        return tier?.lowercased() ?? "free"
    }

    /// Live App Store subscription. StoreKit manage UI is only honest here.
    var isAppleBilled: Bool {
        billing?.isApple == true && billing?.blocksOtherStore == true
    }

    /// Live website subscription.
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

    /// The other store must not sell while this row is still the live one.
    var blocksOtherStore: Bool { hasLiveSub ?? isLive }
}

/// Live power, CPU and memory from a host. Read over the tunnel after a
/// dial. Missing fields were not measured: do not draw them as zero.
struct HostStats: Codable, Sendable, Hashable {
    var power: String?
    var charging: Bool?
    var percent: UInt8?
    var cpu: Double?
    var ramUsedBytes: UInt64?
    var ramTotalBytes: UInt64?
}

/// A machine on the account.
///
/// Field names follow the server (`id`, `label`, `last_sync_at`), not this
/// app's preferences. Every one is optional because the shape belongs to the
/// API: a machine that arrives with only an id still renders instead of
/// failing the whole account decode.
struct Machine: Codable, Sendable, Hashable, Identifiable {
    var machineID: String?
    var label: String?
    var lastSyncAt: String?
    var online: Bool?
    var lastSeenAt: String?
    var publicIdentity: String?
    var trustState: String?
    /// `"host"` uploads usage; `"client"` is a phone that reaches hosts (P5).
    var kind: String?
    /// What the machine says it is: "Ubuntu 24.04 · x86_64". Sent at login, so
    /// a device that only ever ran the CLI still says what kind of computer it
    /// is instead of showing an id.
    var platform: String?
    /// `"user"` when somebody typed the name, so a machine's own registration
    /// does not take a rename back.
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
        case labelSource = "label_source"
    }

    /// Hosts only; clients (phones) are not dialable from Devices.
    var isHost: Bool { kind != "client" }

    /// Phones never upload an archive. lastSyncAt is not a product fact there.
    var reportsArchiveSync: Bool { isHost }

    /// Falls back to the label so two unnamed machines do not collapse into
    /// one row in a ForEach.
    var id: String { machineID ?? label ?? "unidentified" }

    var displayName: String {
        switch (label, machineID) {
        case let (label?, _) where !label.isEmpty:
            return label
        case let (_, id?):
            return id
        default:
            return "unnamed device"
        }
    }

    /// The id, shown alongside a label rather than instead of it.
    var subtitle: String? {
        guard let machineID, label?.isEmpty == false else { return nil }
        return machineID
    }
}

/// Outcome of a sync.
struct SyncOutcome: Codable, Sendable, Hashable {
    var host: String
    var rows: UInt64
    var dryRun: Bool
    var schemaV: UInt32
    var from: String
    var to: String
}

/// A loopback port on this machine that bridges to a service on a peer's own
/// localhost. The browser opens `url` as if the service were local.
struct ProxyListen: Codable, Sendable, Hashable {
    var url: String
}

/// What a machine can launch in a workspace, as its daemon reports it. A
/// remote folder asks the machine that owns it, so the launcher always means
/// the machine the session would actually run on.
///
/// The catalog answers for the whole supported list, not only what is
/// installed: a profile with `installed == false` is something the machine
/// does not have yet, and `installCommand` is how it can get it.
struct RemoteLaunchProfile: Codable, Sendable, Hashable {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var bypassArgs: [String]
    var harnessId: String?
    var symbol: String?
    /// Loopback page the command starts, when the UI is a local web server.
    var openUrl: String?
    /// Whether the command is on this machine's PATH (or in its own install
    /// directory). False when the profile is only offered to be installed.
    var installed: Bool
    /// Taken off this machine's launcher. The binary is still there. Stored
    /// on the owning host so a phone and the Mac see the same grid.
    ///
    /// Optional so a daemon from before this field still decodes. Missing
    /// means not hidden.
    var hidden: Bool?
    /// The tool's official one-shot installer, shown for a profile that is
    /// not installed. Data to display, never a command this app runs: the
    /// host executes it and the app only sends the profile id.
    var installCommand: String?
}

/// What running a profile's installer said. `output` is the captured tail of
/// the installer's stdout and stderr, so an error is something the user can
/// read rather than a bare "it failed".
struct LauncherInstallResult: Codable, Sendable {
    var ok: Bool
    var exitCode: Int?
    var output: String
}

/// Allowlisted settings behind a launch tile's (i) badge.
///
/// The host only ever returns these keys. The rest of the file, including
/// credentials, never crosses the bridge.
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
    /// The band a number sits in, when the tool documents one. Present means
    /// the form draws a slider instead of a text box.
    var min: Int?
    var max: Int?
    var step: Int?
    /// What the tool itself uses when the key is absent, so a slider with no
    /// value starts where the tool already is. `default` is a keyword.
    var fallback: Int?
    var value: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, kind, options, hint, min, max, step
        case fallback = "default"
        case value
    }
}

/// A model server discovered on this machine's loopback.
struct LocalProvider: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var baseURL: String
    var available: Bool
    var models: [LocalModel]
    var error: String?

    /// `baseUrl` on the wire, because the host camel-cases `base_url` like
    /// every other field. Swift spells the acronym, so the two names have to
    /// be joined here: without this the whole response fails to decode, and
    /// the launcher reported it as "no local models discovered".
    enum CodingKeys: String, CodingKey {
        case id, name, baseURL = "baseUrl", available, models, error
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
        return formatter.string(fromByteCount: Int64(sizeBytes))
    }
}

struct SyncScheduleStatus: Codable, Sendable {
    let loggedIn: Bool
    let cliScheduleActive: Bool
    let scheduledNetworkAllowed: Bool
    let due: Bool
}

/// Render an ISO-8601 instant from the server as something readable.
///
/// Returns nil rather than a placeholder when it cannot be parsed, so the
/// caller decides what absence looks like.
/// "3 minutes ago", for a timestamp whose exact minute nobody reads.
///
/// The absolute date stays available as a tooltip. "Last synced 4 Aug 2026 at
/// 18:41" makes you work out whether that was recent. "12 minutes ago" is the
/// answer to the question actually being asked.
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

/// One row of a two-level report.
struct SplitBucket: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var split: String
    var counters: Counters
    var events: UInt64
    var sessions: UInt64

    var id: String { "\(key)\u{1}\(split)" }
}

/// An archive project with the harnesses that ran in it.
///
/// Not a workspace. A workspace is a folder the user registered; this is a
/// label the archive recovered from a slug, and the two are deliberately
/// separate concepts with separate types so they cannot be confused.
struct ProjectHarnesses: Identifiable, Hashable {
    var path: String
    var harnesses: [SplitBucket]
    var tokens: UInt64

    var id: String { path }

    /// Last path component, which is what someone calls the project. The full
    /// path stays available for the row's tooltip, since two checkouts of the
    /// same repository share a leaf name.
    var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let leaf = trimmed.split(separator: "/").last.map(String.init)
        return leaf?.isEmpty == false ? leaf! : (trimmed.isEmpty ? "unknown" : trimmed)
    }
}

/// Archive source id for a launched command, or nil for a plain shell.
///
/// Matched on the basename so `/Users/…/bin/claude` and `claude` are the
/// same harness. Used by session rows on both the Mac and the phone.
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
    case "zed": return "zed"
    case "agy": return "antigravity"
    case "agent", "cursor": return "cursor"
    case "hermes": return "hermes"
    case "kilocode", "kilo": return "kilo"
    default: return nil
    }
}

/// The tool a stored source id belongs to.
///
/// Recovery rows stay on disk as `claude_code_estimate` / `claude_code_rollup`.
/// Surfaces that name a tool fold them into Claude Code.
func harnessToolKey(_ id: String) -> String {
    switch id {
    case "claude_code_estimate", "claude_code_rollup": return "claude_code"
    default: return id
    }
}

/// Display name for a harness, the agent CLI that produced the events.
///
/// The archive stores source ids like `claude_code`. These are shown to
/// people, so they get the same spelling tokenstat.ai uses. Keep the two in
/// step: a user reading their profile on the web and their app should not see
/// two names for one tool.
func harnessName(_ id: String) -> String {
    switch id {
    case "claude_code": return "Claude Code"
    case "claude_code_rollup", "claude_code_estimate": return "Claude Code (recovered)"
    case "codex": return "Codex"
    case "grok": return "Grok Build"
    case "opencode": return "OpenCode"
    case "cline": return "Cline"
    case "openclaw": return "OpenClaw"
    case "muse": return "Muse"
    case "pi": return "Pi"
    case "dsh": return "DeepSeek Harness"
    case "zed": return "Zed"
    case "copilot": return "Copilot CLI"
    case "antigravity": return "Antigravity CLI"
    case "antigravity_ide": return "Antigravity IDE"
    case "cursor": return "Cursor"
    case "gemini": return "Gemini"
    case "hermes": return "Hermes Agent"
    case "kilo": return "Kilo Code"
    case "": return "unknown"
    default: return id
    }
}

/// Asset name for a harness's brand mark, or nil when none is bundled.
///
/// Vendor marks, not ours. See TRADEMARK.md. A missing one falls back to a
/// letter tile rather than borrowing another tool's logo.
func harnessBrandAsset(_ id: String) -> String? {
    // Estimate / rollup rows belong to the same brand as the live source.
    let assetId: String
    switch id {
    case "claude_code_estimate", "claude_code_rollup": assetId = "claude_code"
    case "antigravity_ide": assetId = "antigravity"
    default: assetId = id
    }
    let known: Set<String> = [
        "claude_code", "codex", "grok", "opencode",
        "cline", "openclaw", "muse", "pi", "dsh", "zed", "copilot", "antigravity",
        "cursor", "gemini", "hermes", "kilo",
    ]
    return known.contains(assetId) ? "brand_\(assetId)" : nil
}

// MARK: - Workspaces

/// What happened to one file, as git reports it.
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

    /// The word for it, where there is room for a word rather than a glyph.
    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflicted"
        }
    }
}

/// One changed file.
struct FileChange: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var kind: ChangeKind
    /// Nil when unknown rather than zero: an untracked file has nothing to diff
    /// against, and a changed binary is not an unchanged one.
    var added: UInt64?
    var removed: UInt64?

    var id: String { path }

    /// Directory the file sits in, for grouping. Empty at the repo root.
    var directory: String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    var fileName: String {
        String(path.split(separator: "/").last ?? "")
    }
}

/// Git state of a workspace folder.
struct GitStatus: Codable, Sendable, Hashable {
    var isRepo: Bool
    var branch: String?
    var upstream: String?
    var ahead: UInt32
    var behind: UInt32
    var files: [FileChange]
    var added: UInt64
    var removed: UInt64
    /// True when some file's counts were unknown, so the totals are a floor.
    var partial: Bool
}

/// One branch offered by the workspace branch picker.
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

// MARK: - Pull requests

/// Whether this workspace can use its forge connection.
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

/// Public half of a GitHub device authorization. The device code never leaves
/// the host bridge.
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
        case .all: return "All"
        case .mine: return "Mine"
        case .assigned: return "Assigned"
        case .reviewRequested: return "Review requested"
        }
    }
}

enum PullStateFilter: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case open
    case merged
    case closed
    case draft

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum PullCheckState: String, Codable, Sendable, Hashable {
    case passing
    case failing
    case pending
}

/// One row returned by the forge list query. Bodies and diffs never enter this
/// type: the compact list contains only review metadata.
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

    var id: UInt32 { number }
    var createdDate: Date? { parseServerDate(createdAt) }
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

/// One entry in a workspace's file tree.
struct TreeEntry: Codable, Sendable, Hashable, Identifiable {
    var name: String
    /// Path relative to the workspace root, with `/` separators.
    var path: String
    var isDir: Bool
    /// True when git would ignore this. Shown dimmed rather than hidden:
    /// `target/` and a generated project file are things people look for.
    var ignored: Bool

    var id: String { path }
}

/// What one line of a diff is.
enum DiffLineKind: String, Codable, Sendable {
    case context, added, removed

    var tint: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }
}

/// One line of a diff, with the numbers each side shows in its gutter.
struct DiffLine: Codable, Sendable, Hashable, Identifiable {
    var kind: DiffLineKind
    var oldLine: UInt32?
    var newLine: UInt32?
    /// The line without its leading `+`, `-` or space.
    var text: String

    /// Unique within a hunk: a line is one or the other, never neither.
    var id: String { "\(oldLine.map(String.init) ?? "")-\(newLine.map(String.init) ?? "")" }
}

struct DiffHunk: Codable, Sendable, Hashable, Identifiable {
    var header: String
    var lines: [DiffLine]

    var id: String { header }
}

/// One file's diff against HEAD.
struct FileDiff: Codable, Sendable, Hashable {
    var path: String
    var hunks: [DiffHunk]
    /// True when git refused to diff it as text. Showing nothing without saying
    /// why looks like an empty file.
    var binary: Bool
    /// True when the file is not tracked, so every line reads as added.
    var untracked: Bool

    var fileName: String { String(path.split(separator: "/").last ?? "") }

    /// Build a diff from a chat Edit snippet (`- old` / `+ new` lines).
    ///
    /// Those previews are not unified diffs: they have no hunk header and no
    /// line numbers. DiffBody still needs a FileDiff, so this invents a single
    /// hunk and sequential gutters so the existing renderer can draw it.
    static func fromEditPatch(path: String, patch: String) -> FileDiff {
        var lines: [DiffLine] = []
        var oldLine: UInt32 = 1
        var newLine: UInt32 = 1
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+") {
                lines.append(
                    DiffLine(kind: .added, oldLine: nil, newLine: newLine, text: strip(line, mark: "+"))
                )
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(
                    DiffLine(kind: .removed, oldLine: oldLine, newLine: nil, text: strip(line, mark: "-"))
                )
                oldLine += 1
            } else if !line.isEmpty {
                lines.append(
                    DiffLine(kind: .context, oldLine: oldLine, newLine: newLine, text: line)
                )
                oldLine += 1
                newLine += 1
            }
        }
        return FileDiff(
            path: path,
            hunks: lines.isEmpty ? [] : [DiffHunk(header: "@@ preview @@", lines: lines)],
            binary: false,
            untracked: false
        )
    }

    private static func strip(_ line: String, mark: String) -> String {
        if line.hasPrefix("\(mark) ") { return String(line.dropFirst(2)) }
        if line.hasPrefix(mark) { return String(line.dropFirst()) }
        return line
    }
}

/// What a git command that changed something reported.
struct GitOutcome: Codable, Sendable, Hashable {
    var ok: Bool
    /// Git's own words. Shown verbatim on failure: they name the file, the
    /// hook, or the conflict, and rewording loses that.
    var message: String
}

/// One commit in a workspace's history.
struct Commit: Codable, Sendable, Hashable, Identifiable {
    /// Full hash. Abbreviating is the view's job.
    var id: String
    var subject: String
    var author: String
    /// Author email. Optional because the running daemon can be older than the
    /// app: a launchd agent is updated on its own schedule, and a field it does
    /// not send must not fail the whole decode.
    var email: String?
    /// Author time in unix seconds: when the work was done, not when a rebase
    /// last touched it.
    var timestamp: Int64
    /// True while the commit is not on the upstream branch yet. False when
    /// there is no upstream at all, because then nothing is known either way.
    var unpushed: Bool
    /// Authored by the identity this repository is configured with. The host
    /// decides it, because `user.email` is git's answer to "who am I here" and
    /// can differ per repository. Optional for the same reason as `email`.
    var mine: Bool?

    /// The seven characters everyone actually reads.
    var shortID: String { String(id.prefix(7)) }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

/// How close to a limit a window is.
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

/// One quota window a vendor reports.
struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    /// `5-hour`, `weekly`, `monthly`.
    var label: String
    /// Percent of the allowance used, 0 to 100.
    var percent: Double
    var resetsAtMs: Int64?
    var severity: LimitSeverity

    var id: String { label }

    var resetsAt: Date? {
        resetsAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Clamped for drawing. A vendor reporting 104% is telling you it is over,
    /// not asking for a bar that runs off the edge.
    var fraction: Double { min(1, max(0, percent / 100)) }
}

/// Opt-in plan-limit posting, plus the last readings this Mac has.
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

/// What one provider says about its own limits.
struct ProviderLimits: Codable, Sendable, Hashable, Identifiable {
    /// Archive source id, so the brand mark is the same one used elsewhere.
    var source: String
    var plan: String?
    var windows: [UsageWindow]
    var observedAtMs: Int64
    /// Why the vendor could not be read. With windows present it explains why
    /// they are old rather than why they are missing.
    var note: String?
    /// These windows were remembered from an earlier read, because this one
    /// failed. Real numbers, just not current ones.
    var stale: Bool?

    var id: String { source }

    var observedAt: Date? {
        observedAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000) : nil
    }

    var isStale: Bool { stale == true }

    /// Something to draw, as opposed to only a reason there is nothing.
    var hasWindows: Bool { !windows.isEmpty }

    /// When the soonest window rolls over, which is the next moment these
    /// numbers can change on their own.
    var nextReset: Date? {
        windows.compactMap(\.resetsAt).min()
    }
}

/// One commit in full: what it says, and what it changed.
struct CommitDetail: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var subject: String
    /// Everything after the subject. Empty when there is none.
    var body: String
    var author: String
    var email: String
    var timestamp: Int64
    /// Two or more parents means a merge, which is why its diff can be empty
    /// for a commit that plainly changed things.
    var parents: [String]
    var files: [FileChange]
    var added: UInt64
    var removed: UInt64
    var diffs: [FileDiff]

    var shortID: String { String(id.prefix(7)) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var isMerge: Bool { parents.count > 1 }
}

/// What a folder is holding, as counts and nothing else.
///
/// Answered by `workspace.summary` in one call. It exists to save round trips:
/// a phone drawing one folder's badges was reading five full lists over the
/// tunnel and counting them itself.
struct WorkspaceSummary: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var sessions: Int
    /// Nil when the folder is missing, so "we did not look" is not drawn as
    /// "nothing changed".
    var changed: Int?
    /// Open pull requests only when an All/Open list is already cached.
    var pulls: Int?
    var tasks: Int
    /// Notes kept here, archived ones excluded. Optional because a host older
    /// than this field answers without it, and a row that says nothing is
    /// honest where a zero would not be.
    var notes: Int?
    var workflows: Int
    var workflowsRunning: Int
    var automations: Int
}

/// A folder the user registered.
struct WorkspaceFolder: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var path: String
    var name: String
    var addedAtMs: Int64
    /// False when the folder is gone. Kept and marked rather than dropped.
    var exists: Bool
    /// Absent when the folder is missing, so "we did not look" cannot be
    /// mistaken for "no changes".
    var git: GitStatus?
    /// Public key of the machine that owns this workspace. Local folders have
    /// no machine id. The id is optional for compatibility with older daemons.
    var machineID: String?
    var machineLabel: String?

    var changeCount: Int { git?.files.count ?? 0 }

    /// `+120 −8`, or nil when there is nothing to say.
    var diffStat: String? {
        guard let git, git.isRepo, !git.files.isEmpty else { return nil }
        let plus = "+\(git.added)"
        let minus = git.removed > 0 ? " −\(git.removed)" : ""
        return git.partial ? "\(plus)\(minus)+" : "\(plus)\(minus)"
    }

    /// One-line git summary for the sidebar: branch, ahead/behind, diff stat.
    ///
    /// Nil when there is nothing worth saying, so a plain folder does not
    /// pretend to be a repository.
    var subtitle: String? {
        guard exists else { return "Folder missing" }
        guard let git, git.isRepo else { return "Not a git repo" }
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
}

// MARK: - Automations

// MARK: - Chat

struct ChatConversation: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var workspaceID: String
    var title: String
    var backend: String
    var personaID: String?
    var model: String?
    var effort: String?
    var systemPrompt: String
    var mode: String
    var autonomy: String
    var resumeToken: String?
    var allowedTools: [String]
    var allowedShellPrefixes: [String]
    var budgetSeconds: UInt64
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var running: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case title, backend
        case personaID = "personaId"
        case model, effort, systemPrompt, mode, autonomy, resumeToken
        case allowedTools, allowedShellPrefixes, budgetSeconds
        case createdAtMs, updatedAtMs, running
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        title = try c.decode(String.self, forKey: .title)
        backend = try c.decode(String.self, forKey: .backend)
        personaID = try c.decodeIfPresent(String.self, forKey: .personaID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "plan"
        autonomy = try c.decodeIfPresent(String.self, forKey: .autonomy) ?? "standard"
        resumeToken = try c.decodeIfPresent(String.self, forKey: .resumeToken)
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        allowedShellPrefixes = try c.decodeIfPresent([String].self, forKey: .allowedShellPrefixes) ?? []
        budgetSeconds = try c.decodeIfPresent(UInt64.self, forKey: .budgetSeconds) ?? 0
        createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        updatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(title, forKey: .title)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(personaID, forKey: .personaID)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(mode, forKey: .mode)
        try c.encode(autonomy, forKey: .autonomy)
        try c.encodeIfPresent(resumeToken, forKey: .resumeToken)
        try c.encode(allowedTools, forKey: .allowedTools)
        try c.encode(allowedShellPrefixes, forKey: .allowedShellPrefixes)
        try c.encode(budgetSeconds, forKey: .budgetSeconds)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encode(running, forKey: .running)
    }
}

/// Chat-only backend metadata. `gateTier` is deliberately host-owned: clients
/// must not imply an interactive approval channel where a CLI only has rules.
struct ChatBackend: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var label: String
    var command: String
    var models: [String]
    var efforts: [String]
    var gateTier: String

    enum CodingKeys: String, CodingKey {
        case id, label, name, command, models, efforts, gateTier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? id
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        gateTier = try c.decodeIfPresent(String.self, forKey: .gateTier) ?? "full"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(command, forKey: .command)
        try c.encode(models, forKey: .models)
        try c.encode(efforts, forKey: .efforts)
        try c.encode(gateTier, forKey: .gateTier)
    }
}

struct ChatPersona: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var mark: String
    var backend: String
    var model: String?
    var effort: String?
    var systemPrompt: String
    var defaultMode: String
    var defaultAutonomy: String

    static func blank(backend: String = "claude") -> ChatPersona {
        ChatPersona(
            id: "",
            name: "",
            mark: "",
            backend: backend,
            model: nil,
            effort: nil,
            systemPrompt: "",
            defaultMode: "plan",
            defaultAutonomy: "standard"
        )
    }
}

struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var mediaType: String?
}

struct ChatEventChunk: Codable, Sendable {
    var events: [ChatTimelineEvent]
    var nextOffset: UInt64
}

struct ChatTimelineEvent: Codable, Sendable, Identifiable {
    var kind: String
    var text: String?
    var atMs: Int64?
    var event: ChatAgentEvent?
    var approval: ChatApproval?
    var id: String {
        "\(kind)-\(atMs ?? 0)-\(text ?? event?.delta ?? event?.verb ?? event?.status ?? approval?.id ?? "event")"
    }
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

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversationId"
        case verb, preview, shellPrefix, createdAtMs, expiresAtMs, decision
    }
}

struct ChatAgentEvent: Codable, Sendable {
    var kind: String
    var delta: String?
    var verb: String?
    var target: String?
    var path: String?
    var added: UInt32?
    var removed: UInt32?
    var patch: String?
    var status: String?
    var text: String?
    var input: UInt64?
    var output: UInt64?
    var costUsd: Double?
    var callId: String?
    var ok: Bool?
    var detail: String?
    var cacheRead: UInt64?
    var cacheWrite: UInt64?
    var exitCode: Int32?
}

/// An agent CLI the daemon can run: a backend, a prompt, a workspace, and a
/// schedule with a budget the run stops at.
struct Automation: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    /// One of the ids `automation.backends` reports. The daemon owns the argv
    /// for each backend, so a client never builds a command line.
    var backend: String
    /// Model alias passed to the CLI, when the backend advertises models.
    var model: String?
    /// Reasoning effort passed to the CLI, when the backend advertises levels.
    var effort: String?
    var workspaceID: String
    var prompt: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
    var enabled: Bool
    var lastRunAtMs: Int64?
    var nextRunAtMs: Int64?
    var lastRunID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, backend, model, effort, workspaceID = "workspaceId", prompt, schedule
        case budgetSeconds, enabled, lastRunAtMs, nextRunAtMs, lastRunID = "lastRunId"
    }

    var lastRun: Date? { lastRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var nextRun: Date? { nextRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

/// When a job fires, as a plain struct so the form edits one field at a time.
struct AutomationSchedule: Codable, Sendable, Hashable {
    var kind: ScheduleKind
    /// Interval only, seconds.
    var everySeconds: UInt64
    /// Wall-clock kinds only, local hour and minute.
    var hour: Int
    var minute: Int
    /// Weekly single-day, 0 = Monday to 6 = Sunday.
    var weekday: Int
    /// Multi-day bitset, Monday = bit 0 … Sunday = bit 6. Used by custom and
    /// weekdays; weekly with a single day keeps using `weekday` (this stays 0).
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
    /// Monday through Friday bits, matching the host.
    static let weekdaysMask = 0b0001_1111

    /// One phrasing for Mac, iPhone and iPad, so a job cannot say two things.
    var summary: String {
        let time = String(format: "%d:%02d", hour, minute)
        switch kind {
        case .once: return "once, when you run it"
        case .interval:
            let minutes = Int(everySeconds) / 60
            if minutes >= 60, minutes % 60 == 0 {
                let hours = minutes / 60
                return "every \(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "every \(minutes) minute\(minutes == 1 ? "" : "s")"
        case .daily: return "daily at \(time)"
        case .weekdays: return "weekdays at \(time)"
        case .weekly:
            if weekdays & 0b0111_1111 != 0 {
                return "\(Self.dayList(weekdays)) at \(time)"
            }
            let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let day = weekday >= 0 && weekday < 7 ? names[weekday] : "?"
            return "\(day) at \(time)"
        case .custom:
            let days = Self.dayList(weekdays)
            if days.isEmpty { return "custom at \(time)" }
            return "\(days) at \(time)"
        }
    }

    /// A repeating schedule can be paused. Once is only ever a button.
    var repeats: Bool { kind != .once }

    private static func dayList(_ mask: Int) -> String {
        let short = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
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
        case .once: return "Once"
        case .interval: return "Interval"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .custom: return "Custom"
        }
    }
}

/// One completed or still-running agent run.
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
    /// The workflow run this is a step of, when it is one. Absent for a run
    /// somebody scheduled or started, which is the only kind worth a
    /// notification: see `RunNotifications`.
    var parentRunID: String?

    enum CodingKeys: String, CodingKey {
        case id, jobId, name, backend, workspaceID = "workspaceId"
        case startedAtMs, endedAtMs, exitCode, status, transcriptPath
        case parentRunID = "parentRunId"
    }

    var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    var isRunning: Bool { status == "running" || status == "queued" }
    var endedLabel: String {
        switch status {
        case "queued": return "Queued"
        case "running": return "Running"
        case "ok": return "Done"
        case "stopped": return "Stopped"
        case "error": return "Failed"
        case "interrupted": return "Interrupted by restart"
        default: return status
        }
    }
}

/// Shared run queue: default time limit and how many jobs may run at once.
struct AutomationQueue: Codable, Sendable {
    var defaultBudgetSeconds: UInt64
    var maxConcurrent: UInt32
}

// MARK: - Workflows

/// Host-owned graph. The Mac canvas is a view of this, not the source of truth.
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

    enum CodingKeys: String, CodingKey {
        case id, name, scope, workspaceID = "workspaceId"
        case budgetSeconds, schedule, enabled, nodes, edges
        case lastRunAtMs, nextRunAtMs, lastRunID = "lastRunId"
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
        lastRunID: String? = nil
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
    }

    var lastRun: Date? { lastRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var nextRun: Date? { nextRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// Empty graph with a start node. The person still has to save it.
    static func blank(name: String = "Untitled", scope: WorkflowScope = .global, workspaceID: String? = nil) -> WorkflowGraph {
        WorkflowGraph(
            name: name,
            scope: scope,
            workspaceID: workspaceID,
            nodes: [WorkflowNode(id: "in", kind: .input, x: 80, y: 120, title: "Start")]
        )
    }

    /// Place nodes top to bottom when every position is still the origin.
    ///
    /// Design-from-prompt often omits `x`/`y`. The runner ignores them. The
    /// canvas needs something it can show. Layers go down. Siblings share a row.
    mutating func layoutIfNeeded() {
        guard !nodes.isEmpty else { return }
        if nodes.contains(where: { $0.x != 0 || $0.y != 0 }) { return }

        var incomingCount: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        for node in nodes {
            incomingCount[node.id] = 0
        }
        for edge in edges {
            incomingCount[edge.to, default: 0] += 1
            outgoing[edge.from, default: []].append(edge.to)
        }

        var layer: [String: Int] = [:]
        var queue = nodes.filter { (incomingCount[$0.id] ?? 0) == 0 }.map(\.id)
        if queue.isEmpty {
            queue = nodes.map(\.id)
        }
        for id in queue {
            layer[id] = 0
        }

        var i = 0
        var seen = Set(queue)
        while i < queue.count {
            let id = queue[i]
            i += 1
            let current = layer[id] ?? 0
            for next in outgoing[id] ?? [] {
                layer[next] = max(layer[next] ?? 0, current + 1)
                if !seen.contains(next) {
                    seen.insert(next)
                    queue.append(next)
                }
            }
        }

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
        case .global: return "Global"
        case .workspace: return "This workspace"
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
        case .input: return "Input"
        case .agent: return "Agent"
        case .automation: return "Automation"
        case .http: return "HTTP"
        case .command: return "Command"
        case .gate: return "Gate"
        case .condition: return "If"
        case .loop: return "Loop"
        case .mcp: return "MCP"
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
        case .ok: return "on success"
        case .error: return "on error"
        case .always: return "always"
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

    enum CodingKeys: String, CodingKey {
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
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind.label
    }

    /// One-line caption for the outline. Never invents a dollar figure.
    var subtitle: String {
        switch kind {
        case .input:
            return "Starting prompt"
        case .agent:
            return [backend, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .automation:
            return automationID ?? "Run automation"
        case .http:
            let verb = (method?.isEmpty == false ? method! : "GET")
            return [verb, url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case .command:
            return command ?? prompt ?? "Command"
        case .gate:
            return "Waits for you"
        case .condition:
            return pattern?.isEmpty == false ? (pattern ?? "If") : "Then or else"
        case .loop:
            if let until, !until.isEmpty { return "until \(until)" }
            let n = times ?? 3
            return "\(n)×"
        case .mcp:
            return "Reserved"
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
        case "queued": return "Queued"
        case "running": return "Working"
        case "waiting": return "Needs attention"
        case "ok": return "Done"
        case "stopped": return "Stopped"
        case "error": return "Failed"
        case "interrupted": return "Interrupted by restart"
        default: return status
        }
    }
}

struct WorkflowDesignResult: Codable, Sendable {
    var workflow: WorkflowGraph
    var transcript: String
}

/// A slice of a run's transcript, asked for by byte offset.
struct TranscriptChunk: Codable, Sendable {
    var text: String
    var nextOffset: UInt64
}

/// Argv from `automation.interactiveCommand`.
struct InteractiveCommandArgv: Codable, Sendable {
    var argv: [String]
}

/// One agent CLI a job can run on, as the daemon advertises it.
struct AgentBackend: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var command: String
    /// Model aliases the CLI accepts on its `--model` flag. Empty means the
    /// client offers no model picker for this backend.
    var models: [String]
    /// Effort levels the CLI accepts. Empty means no effort picker.
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
        // An older daemon does not advertise the lists yet; both default to
        // empty so the pickers simply do not appear.
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
    }
}

// MARK: - Todo

enum TodoKind: String, Codable, Sendable, Hashable {
    case task
    case note
}

/// A card on the kanban board.
struct TodoCard: Codable, Sendable, Identifiable, Hashable {
    var id: String
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
        case id, title, notes, column, order, priority, backend, model, effort
        case kind
        case workspaceID = "workspaceId", budgetSeconds, createdAtMs, updatedAtMs, delegate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decodeIfPresent(TodoKind.self, forKey: .kind) ?? .task
        notes = try values.decode(String.self, forKey: .notes)
        column = try values.decode(String.self, forKey: .column)
        order = try values.decode(Int64.self, forKey: .order)
        priority = try values.decode(String.self, forKey: .priority)
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
        case "doing": return "Doing"
        case "done": return "Done"
        case "archive": return "Archive"
        default: return "To Do"
        }
    }

    var isArchived: Bool { column == "archive" }

    var isNote: Bool { kind == .note }

    /// A note drawn before the host has confirmed it.
    ///
    /// The phone's notes screen shows what you wrote at once and swaps this
    /// for the host's card when it answers. Written as its own initializer
    /// because the decoding one above takes the memberwise initializer away,
    /// and the id is deliberately not a plausible one: nothing may act on this
    /// row except the code that made it, and a temporary that looks real is a
    /// delete aimed at nothing.
    init(pendingNote text: String, workspaceID: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        id = "pending:\(UUID().uuidString)"
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

    /// The token a CLI `--model` flag accepts. Drops a tab-separated label
    /// or a mashed `idLabel` leftover from an older picker.
    var cleanedModel: String {
        Self.cleanModelID(model ?? "")
    }

    /// What an agent should do. Notes first, title if the notes are empty.
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

/// Start this card as an interactive terminal, not as an automation.
struct InteractiveTaskLaunch: Sendable {
    var workspaceID: String
    var backend: String
    var model: String?
    var effort: String?
    var prompt: String
    var title: String
}

/// The live state of a card handed to an agent.
struct TodoDelegate: Codable, Sendable, Hashable {
    var runId: String
    var status: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case runId, status, startedAtMs, endedAtMs, error
    }

    var isRunning: Bool { status == "running" || status == "queued" }
    var label: String {
        switch status {
        case "queued": return "Queued"
        case "running": return "Running"
        case "ok": return "Done"
        case "stopped": return "Stopped"
        case "error": return "Failed"
        default: return status
        }
    }
}

// MARK: - Terminals

/// A pty session as the host reports it.
///
/// The process is owned by the host, not by the app: a session survives the
/// window closing, and a client that reconnects resumes by offset. Field names
/// follow the Rust `SessionInfo`, which is the single definition of the shape.
struct PtySessionInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    /// The command as launched, for a tab label.
    var command: String
    var cwd: String
    /// Workspace this belongs to, so sessions can be grouped by folder.
    var workspaceID: String?
    /// Daemon-owned jobs (automations) set this so the workspace must not
    /// adopt the session as a tab.
    var hidden: Bool?
    var rows: Int
    var cols: Int
    var alive: Bool
    /// Set once the process has exited. `nil` while it still runs, which is
    /// not the same as having exited with status 0.
    var exitCode: Int?
    /// Total bytes ever produced. A client's read offset is against this.
    var totalBytes: UInt64
    /// When the process last produced output, epoch milliseconds. Absent
    /// when the host predates the field or nothing has been read yet.
    var lastActivityAtMs: Int64?
    /// What the host's detector says this session is doing: `working` or
    /// `idle`. Absent when the sampler has not reached it yet, which is not
    /// the same as idle and must not be shown as idle.
    var activity: String?
    /// Smoothed CPU of the process subtree, percent of one core. The number
    /// behind the verdict, so a row can show its working.
    var cpuPercent: Double?
    /// Resident memory of the process subtree, in megabytes.
    var memoryMb: Double?
    /// Why the person should look: `permission`, `gate`, or `error`.
    /// Absent when nothing needs them. Not the same as idle.
    var attention: String?
    /// Lifetime tokens this session has used, from the live meter.
    /// Absent when the harness has no usable log yet. Never a fake zero.
    var tokens: UInt64?
    /// List-rate equivalent of those tokens, in microdollars. Zero once
    /// something priced, so the row counts up from `$0.00`. Absent only when
    /// nothing could be priced at all.
    var costMicros: Int64?
    /// True when at least one priced event used a catalog estimate.
    var costEstimated: Bool?
    /// False when at least one event could not be priced. The figure is then
    /// a floor.
    var costComplete: Bool?
    /// Model id of the last priced turn, for the context-bar denominator.
    var model: String?
    /// Prompt-side tokens of the last turn. The context bar numerator.
    var contextUsed: UInt64?
    /// Catalog context window for `model`. Absent for a model no snapshot
    /// lists, in which case the row shows the used figure without a bar.
    var contextWindow: UInt64?
    /// True when the window came from sibling models rather than a published
    /// figure. The percentage is then marked as approximate.
    var contextEstimated: Bool?
    /// `metered`, `plan`, or `unknown`. A plan session's money is an
    /// equivalent, never a charge.
    var billing: String?

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
        case activity
        case cpuPercent
        case memoryMb
        case attention
        case tokens
        case costMicros
        case costEstimated
        case costComplete
        case model
        case contextUsed
        case contextWindow
        case contextEstimated
        case billing
    }
}

/// One poll's worth of terminal output.
///
/// The wire carries base64, because the bytes are not valid UTF-8 in general:
/// an escape sequence can be cut in half at a read boundary. The decode happens
/// here, in `init(from:)`, which runs on the bridge's own queue. That placement
/// is the point: a burst of build output is up to half a megabyte per poll, and
/// decoding it in the session actor put that work on the thread that draws.
struct PtyChunk: Decodable, Sendable {
    /// The output itself, already decoded.
    var bytes: Data
    /// Offset to ask for next time.
    var nextOffset: UInt64
    /// Bytes dropped before this chunk because this reader fell behind the
    /// host's bounded buffer. Zero in normal use, and never silently ignored.
    var dropped: UInt64
    /// The host paused its PTY reader because the lossless handoff window is full.
    var paused: Bool

    private enum CodingKeys: String, CodingKey {
        case data
        case nextOffset
        case dropped
        case paused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .data)
        // An unreadable chunk is empty output rather than a failed poll. The
        // offset still advances, so the session carries on instead of asking
        // for the same bytes forever.
        bytes = Data(base64Encoded: encoded) ?? Data()
        nextOffset = try container.decode(UInt64.self, forKey: .nextOffset)
        dropped = try container.decode(UInt64.self, forKey: .dropped)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

// MARK: - Machines

/// Who this machine is to another one.
struct MachineIdentity: Codable, Sendable {
    /// The public key as hex. Long, and the thing that is actually pinned.
    let key: String
    /// The short form somebody reads aloud to check two ends match.
    let fingerprint: String
    /// The same key as three words. What the screen leads with, because it is
    /// the comparison a person performs rather than skims.
    let words: String?
    let label: String
    /// Whether somebody named this machine, as opposed to it carrying the name
    /// the operating system gave it. Decides whether there is anything to undo.
    var labelIsChosen: Bool?
}

/// A machine this one knows about.
struct Peer: Codable, Sendable, Identifiable, Hashable {
    enum Trust: String, Codable, Sendable {
        /// It made contact and nobody has decided yet. The only state a new
        /// peer can arrive in.
        case pending
        case approved
        /// Somebody withdrew access. Remembered rather than deleted, so the
        /// same machine coming back is known as one that was turned away.
        case revoked
    }

    let key: String
    let fingerprint: String
    let words: String?
    let label: String
    let trust: Trust
    /// Where it was reached or seen from. A hint for dialling, never a
    /// credential: an address proves nothing about who is at it.
    let address: String?
    let firstSeen: String
    let lastSeen: String

    var id: String { key }
}

/// Whether this machine is reachable by others.
struct RemoteStatus: Codable, Sendable {
    /// Whether this machine keeps an outbound connection to the blind tunnel.
    let tunnel: Bool
    /// What the tunnel is actually doing. The toggle can be on while the
    /// daemon is being refused (plan gate, revoked token, endpoint down), so
    /// the screen has to read these rather than trust the setting.
    let tunnelOnline: Bool?
    /// Whether the account directory carries this machine's key and name.
    let tunnelRegistered: Bool?
    /// Why the tunnel is not connected, when it is not.
    let tunnelError: String?
    let key: String
    let fingerprint: String
    let words: String?
    let label: String
    /// Addresses held by the live direct listener. Optional across rollout.
    let directCandidates: [RemoteDirectCandidate]?
}

struct RemoteDirectCandidate: Codable, Sendable {
    let kind: String
    let address: String
    let priority: Int
}

struct TunnelOutcome: Codable, Sendable {
    let tunnel: Bool
}

/// Whether this Mac's host helper outlives the app.
struct HostPolicy: Codable, Sendable {
    var alwaysOn: Bool
    var defaultAlwaysOn: Bool
    var hasInternalBattery: Bool
    var hostingActive: Bool
}
