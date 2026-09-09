// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// The work worth keeping: pinned folders and conversations.
///
/// Account-scoped identifiers and a short label only. Transcript text never
/// lands here; the sealed conversation copies live in the work cache, and a
/// pin is what keeps a copy past age eviction. At most eight per scope: Home
/// is a shelf, not a second folder list, and the limit is refused with words
/// rather than by silently dropping somebody's oldest pin.
///
/// A duplicate conversation id on two machines never shares a pin: the key
/// carries the verified machine identity and the raw workspace id, so the
/// same id in two folders is two pins.
@MainActor @Observable
final class PinnedWorkStore {
    static let shared = PinnedWorkStore()
    static let capacity = 8

    struct Pin: Codable, Equatable {
        var reference: WorkReference
        /// A folder name or conversation title, for the row. Never a prompt,
        /// path or command: labels come from the same safe surfaces as
        /// recent places.
        var label: String
        /// The workspace the work belongs to, for the subtitle and for
        /// opening the row. A folder pin repeats its own name here.
        var folderName: String
        var pinnedAt: Date

        /// Stable within a scope. Nil when the reference cannot name work.
        var key: String? { PinnedWorkStore.pinKey(for: reference) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Newest first. Reads tolerate corruption and invalid rows by dropping
    /// them, the same way recent places do: a pin the store cannot name is
    /// not work worth keeping.
    func pins(in scope: WorkReference.Scope?) -> [Pin] {
        _ = revision
        guard let scope, let data = defaults.data(forKey: Self.storageKey(for: scope)),
              let stored = try? JSONDecoder().decode([Pin].self, from: data)
        else { return [] }
        var seen: Set<String> = []
        return stored.compactMap { pin in
            guard let key = pin.key, seen.insert(key).inserted,
                  pin.reference.scope == scope
            else { return nil }
            return Pin(reference: pin.reference, label: Self.safeLabel(pin.label),
                       folderName: Self.safeLabel(pin.folderName), pinnedAt: pin.pinnedAt)
        }.sorted { $0.pinnedAt > $1.pinnedAt }
    }

    func isPinned(_ reference: WorkReference) -> Bool {
        _ = revision
        guard let key = Self.pinKey(for: reference) else { return false }
        return pins(in: reference.scope).contains { $0.key == key }
    }

    /// False when the shelf is full and this is new: the caller says so
    /// rather than the store choosing what goes. Re-pinning updates the
    /// labels and moves the pin to the top.
    @discardableResult
    func pin(_ reference: WorkReference, label: String, folderName: String, at date: Date = Date()) -> Bool {
        guard let scope = Self.validScope(reference.scope), let key = Self.pinKey(for: reference) else { return false }
        var current = pins(in: scope)
        if let index = current.firstIndex(where: { $0.key == key }) {
            current[index].label = Self.safeLabel(label)
            current[index].folderName = Self.safeLabel(folderName)
            current[index].pinnedAt = date
        } else {
            guard current.count < Self.capacity else { return false }
            current.append(Pin(reference: reference, label: Self.safeLabel(label),
                               folderName: Self.safeLabel(folderName), pinnedAt: date))
        }
        save(current, in: scope)
        return true
    }

    func unpin(_ reference: WorkReference) {
        guard let scope = Self.validScope(reference.scope),
              let key = Self.pinKey(for: reference) else { return }
        save(pins(in: scope).filter { $0.key != key }, in: scope)
    }

    /// Stable identity for one piece of work. Workspace pins name the
    /// folder; everything else names the item inside it.
    nonisolated static func pinKey(for reference: WorkReference) -> String? {
        guard validScope(reference.scope) != nil,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty,
              validIdentifier(reference.hostIdentity), validIdentifier(reference.workspaceID)
        else { return nil }
        switch reference.kind {
        case .workspace:
            guard reference.itemID == nil else { return nil }
            return "workspace|\(WorkReferenceKey.encode(reference.hostIdentity))"
                + "|\(WorkReferenceKey.encode(reference.workspaceID))"
        case .conversation, .terminal, .commit, .savedDiff:
            guard let item = reference.itemID, validIdentifier(item) else { return nil }
            return "\(reference.kind.rawValue)|\(WorkReferenceKey.encode(reference.hostIdentity))"
                + "|\(WorkReferenceKey.encode(reference.workspaceID))|\(WorkReferenceKey.encode(item))"
        }
    }

    private nonisolated static func storageKey(for scope: WorkReference.Scope) -> String {
        "pinned.work.v1.\(WorkCache.scope(for: scope))"
    }

    private nonisolated static func validScope(_ scope: WorkReference.Scope) -> WorkReference.Scope? {
        switch scope.kind {
        case .account:
            return WorkReference.Scope.account(origin: scope.origin, handle: scope.identity).flatMap {
                $0 == scope ? $0 : nil
            }
        case .local:
            return scope.identity.isEmpty ? nil : scope
        }
    }

    private nonisolated static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private nonisolated static func safeLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else { return "Pinned work" }
        return String(trimmed.prefix(80))
    }

    private func save(_ pins: [Pin], in scope: WorkReference.Scope) {
        let ordered = pins.sorted { $0.pinnedAt > $1.pinnedAt }
        guard let data = try? JSONEncoder().encode(ordered) else {
            defaults.removeObject(forKey: Self.storageKey(for: scope))
            revision += 1
            return
        }
        defaults.set(data, forKey: Self.storageKey(for: scope))
        revision += 1
    }

    /// The account scope pins file under, from the same host and handle the
    /// recent places use. Handle-less accounts cannot pin yet: a pin filed
    /// under a handle would surface under whoever claims it next.
    nonisolated static func scope(host: String, handle: String?) -> WorkReference.Scope? {
        guard let handle, !handle.isEmpty, !host.isEmpty else { return nil }
        return WorkReference.Scope.account(origin: host, handle: handle)
    }
}
