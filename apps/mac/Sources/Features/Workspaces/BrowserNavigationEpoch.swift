// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A completion belongs to the navigation that started it, even after a new Go.
struct BrowserNavigationEpoch {
    struct Completion: Equatable {
        let generation: Int
        let registered: Bool
    }
    var current = 0
    private var owners: [ObjectIdentifier: Completion] = [:]
    mutating func register(_ navigation: AnyObject?, generation: Int) {
        guard let navigation else { return }
        owners[ObjectIdentifier(navigation)] = Completion(generation: generation, registered: true)
    }
    mutating func started(_ navigation: AnyObject?) -> Bool {
        guard let navigation else { return false }
        let id = ObjectIdentifier(navigation)
        if owners[id] == nil { owners[id] = Completion(generation: current, registered: false) }
        return owners[id]?.generation == current
    }
    mutating func finish(_ navigation: AnyObject?) -> Completion? {
        guard let navigation, let owner = owners.removeValue(forKey: ObjectIdentifier(navigation)),
              owner.generation == current else { return nil }
        return owner
    }
}
