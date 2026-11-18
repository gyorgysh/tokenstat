// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreFoundation

enum SidebarProjectsDisplay: String, CaseIterable, Sendable {
    /// Folders first, chats nested under each one.
    case byRepository
    /// One list of chats across folders, newest / working first.
    case byChat
}

enum SidebarProjectsSort: String, CaseIterable, Sendable {
    /// The person's drag order (folder mode only).
    case manual
    /// A–Z by folder or chat title.
    case name
    case recent
}

/// Device-local, additive preferences. Each disclosure has its own key, so
/// changing one never rewrites preferences owned by a newer or older release.
/// Keep existing key names and value types stable; add keys for new semantics.
final class SidebarPreferences {
    static let shared = SidebarPreferences()
    static let defaultOrder = ["projects", "servers"]
    private let defaults: UserDefaults
    private let expansionPrefix = "shell.sidebar.expanded."
    private let orderKey = "shell.sidebar.sectionOrder"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isExpanded(_ key: String, default fallback: Bool) -> Bool {
        guard let value = defaults.object(forKey: expansionPrefix + key) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return fallback }
        return value.boolValue
    }

    func expandedIDs(_ prefix: String) -> Set<String> {
        let fullPrefix = expansionPrefix + prefix
        return Set(defaults.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(fullPrefix),
                  isExpanded(String(key.dropFirst(expansionPrefix.count)), default: false) else { return nil }
            return String(key.dropFirst(fullPrefix.count))
        })
    }

    func rememberExpansion(_ key: String, expanded: Bool) {
        defaults.set(expanded, forKey: expansionPrefix + key)
    }

    var sectionOrder: [String] {
        var order: [String] = []
        for case let section as String in defaults.array(forKey: orderKey) ?? [] {
            if Self.defaultOrder.contains(section), !order.contains(section) { order.append(section) }
        }
        return order + Self.defaultOrder.filter { !order.contains($0) }
    }

    /// Retain unknown future sections and values when moving known sections.
    func move(_ section: String, before other: String) {
        guard Self.defaultOrder.contains(section), Self.defaultOrder.contains(other), section != other else { return }
        var raw = defaults.array(forKey: orderKey) ?? Self.defaultOrder
        raw.removeAll { ($0 as? String) == section }
        if !raw.contains(where: { ($0 as? String) == other }) { raw.append(other) }
        let index = raw.firstIndex { ($0 as? String) == other }!
        raw.insert(section, at: index)
        defaults.set(raw, forKey: orderKey)
    }

    private static let displayKey = "shell.sidebar.projectsDisplay"
    private static let sortKey = "shell.sidebar.projectsSort"

    var projectsDisplay: SidebarProjectsDisplay {
        get {
            guard let raw = defaults.string(forKey: Self.displayKey),
                  let value = SidebarProjectsDisplay(rawValue: raw) else {
                return .byRepository
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Self.displayKey) }
    }

    var projectsSort: SidebarProjectsSort {
        get {
            guard let raw = defaults.string(forKey: Self.sortKey),
                  let value = SidebarProjectsSort(rawValue: raw) else {
                return .manual
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Self.sortKey) }
    }
}
