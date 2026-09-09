// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Last verified ownership, never an authenticated account snapshot. No tokens,
/// entitlement fields, transcript text or machine addresses live in this record.
struct SavedWorkOwner: Codable, Equatable, Identifiable, Sendable {
    var id: WorkReference.Scope { scope }
    let scope: WorkReference.Scope
    let name: String
    let hosts: [String: String]

    var isValid: Bool {
        scope.kind == .account && !name.isEmpty && name.utf8.count <= 512
            && WorkReference.Scope.account(origin: scope.origin, handle: scope.identity) == scope
            && hosts.count <= 256
            && hosts.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 512 && $0.value.utf8.count <= 512 }
    }
}

@MainActor @Observable
final class SavedWorkAccess {
    static let shared = SavedWorkAccess()
    private(set) var reader: SavedWorkOwner?
    private(set) var generation: UInt64 = 0
    private var accountAnswered = false
    private let defaults: UserDefaults
    private let key = "work.savedOwner.v1"
    private struct Envelope: Codable { let version: Int; let owner: SavedWorkOwner }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var offeredOwner: SavedWorkOwner? {
        guard !accountAnswered, let data = defaults.data(forKey: key), data.count <= 128 * 1024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.owner.isValid else { return nil }
        return envelope.owner
    }

    /// A definitive account answer ends local reading. Signed out erases the
    /// offer; a different account replaces it rather than exposing a chooser.
    func verified(_ owner: SavedWorkOwner?) {
        endReading()
        accountAnswered = true
        guard let owner, owner.isValid,
              let data = try? JSONEncoder().encode(Envelope(version: 1, owner: owner)) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    func accountUnknown() {
        endReading()
        accountAnswered = false
    }

    /// Called only by an explicit user action at the account-retry door.
    @discardableResult
    func beginReading(_ owner: SavedWorkOwner) -> Bool {
        guard offeredOwner == owner else { return false }
        generation &+= 1
        reader = owner
        return true
    }

    func endReading() {
        generation &+= 1
        reader = nil
    }
}
