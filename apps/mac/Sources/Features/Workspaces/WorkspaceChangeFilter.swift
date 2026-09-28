// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Which watched folders a batch of file events is actually about.
///
/// Every change under a project used to re-read git in every project. Most of
/// those changes are not changes anybody can see in `git status`: a build
/// writing thousands of files into `target/`, a package manager filling
/// `node_modules/`, git itself packing objects. So a batch is first cut down
/// to the paths that can matter, then mapped to the folder that owns each one,
/// and only those folders are read again.
///
/// The noise list is directory names that are build output or caches in
/// practically every repository, matched only below the watched folder, so a
/// project that itself lives under a directory called `target` is not
/// silenced. `build` and `dist` are deliberately absent: some repositories
/// track files there, and a missed refresh is worse than a spare one.
enum WorkspaceChangeFilter {
    /// Directory names whose contents never change what a person sees.
    static let noise: Set<String> = [
        "target", "node_modules", ".build", ".next", ".nuxt", ".turbo",
        "__pycache__", ".venv", ".gradle", ".dart_tool", ".pytest_cache",
        ".mypy_cache", ".swiftpm",
    ]

    /// Directory-name prefixes treated the same way, for Xcode's per-run
    /// derived data folders.
    static let noisePrefixes: [String] = ["DerivedData"]

    /// Inside `.git`, the parts that change on their own: the object store,
    /// the reflogs and LFS. The index, `HEAD` and refs stay relevant, because
    /// that is where a commit or a branch switch shows up.
    static let gitNoise: Set<String> = ["objects", "logs", "lfs"]

    /// What a batch of events means for the watched folders.
    enum Change: Equatable {
        /// Only noise. Nothing to read.
        case none
        /// These roots changed, and only these.
        case roots(Set<String>)
        /// A path under none of the roots, which should not happen and means
        /// the paths are spelled differently (a symlink, a renamed volume).
        /// The safe answer is to read everything.
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

    /// The watched roots touched by `paths`, ignoring the noise. A path under
    /// no watched root is dropped. Nested roots both count: the inner one owns
    /// the file and the outer one's status includes it.
    static func roots(touchedBy paths: [String], among roots: [String]) -> Set<String> {
        var touched = Set<String>()
        for path in paths {
            if case let .roots(found) = classify([path], among: roots) {
                touched.formUnion(found)
            }
        }
        return touched
    }

    /// Whether a path, relative to its watched root, is build output, a
    /// cache, or git's own housekeeping.
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
