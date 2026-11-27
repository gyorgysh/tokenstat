// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

@MainActor @Observable
final class PinnedWorkStore {
    static let shared = PinnedWorkStore()
    static let capacity = 8

    struct Pin: Codable, Equatable {
        var reference: WorkReference
        var label: String
        var folderName: String
        var pinnedAt: Date

        var key: String? { PinnedWorkStore.pinKey(for: reference) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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
        else { return L10n.text("apple.pinnedwork.pinned_work.23dd8f45") }
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

    nonisolated static func scope(host: String, handle: String?, id: String?) -> WorkReference.Scope? {
        guard !host.isEmpty,
              let identity = WorkReference.Scope.accountIdentity(handle: handle, id: id) else { return nil }
        return WorkReference.Scope.account(origin: host, handle: identity)
    }
}
