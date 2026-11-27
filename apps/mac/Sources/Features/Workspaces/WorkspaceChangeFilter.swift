// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

enum WorkspaceChangeFilter {
    static let noise: Set<String> = [
        "target", "node_modules", ".build", ".next", ".nuxt", ".turbo",
        "__pycache__", ".venv", ".gradle", ".dart_tool", ".pytest_cache",
        ".mypy_cache", ".swiftpm",
    ]

    static let noisePrefixes: [String] = ["DerivedData"]

    static let gitNoise: Set<String> = ["objects", "logs", "lfs"]

    enum Change: Equatable {
        case none
        case roots(Set<String>)
        case unknown
    }

    static func classify(_ paths: [String], among roots: [String]) -> Change {
        let normalized = roots.map { (root: $0, prefix: Self.directoryPrefix($0)) }
        var touched = Set<String>()
        for path in paths {
            let candidate = path.hasSuffix("/") ? path : path + "/"
            var owned = false
            for entry in normalized where candidate.hasPrefix(entry.prefix) {
                owned = true
                let relative = String(candidate.dropFirst(entry.prefix.count))
                if !isNoise(relative: relative) {
                    touched.insert(entry.root)
                }
            }
            if !owned { return .unknown }
        }
        return touched.isEmpty ? .none : .roots(touched)
    }

    static func roots(touchedBy paths: [String], among roots: [String]) -> Set<String> {
        var touched = Set<String>()
        for path in paths {
            if case let .roots(found) = classify([path], among: roots) {
                touched.formUnion(found)
            }
        }
        return touched
    }

    static func isNoise(relative: String) -> Bool {
        let components = relative.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            if noise.contains(component) { return true }
            if noisePrefixes.contains(where: { component.hasPrefix($0) }) { return true }
            if component == ".git", index + 1 < components.count,
               gitNoise.contains(components[index + 1]) {
                return true
            }
        }
        return false
    }

    private static func directoryPrefix(_ root: String) -> String {
        root.hasSuffix("/") ? root : root + "/"
    }
}
