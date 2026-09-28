// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkspaceChangeFilter.swift.
import Foundation

@main enum WorkspaceChangeFilterTests {
    static func main() {
        let roots = ["/w/app", "/w/lib", "/w/target/proj"]
        // A source edit touches only its own project.
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/app/src/"], among: roots) == ["/w/app"])
        // Build output and caches touch nothing.
        precondition(WorkspaceChangeFilter.roots(touchedBy: [
            "/w/app/target/debug/deps/", "/w/lib/node_modules/x/", "/w/app/.build/",
            "/w/app/apps/mac/DerivedDataReview/Build/",
        ], among: roots).isEmpty)
        // Git's object store and logs are housekeeping; the index is not.
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/app/.git/objects/ab/"], among: roots).isEmpty)
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/app/.git/logs/refs/"], among: roots).isEmpty)
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/app/.git/"], among: roots) == ["/w/app"])
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/app/.git/refs/heads/"], among: roots) == ["/w/app"])
        // A project that lives under a directory called target still counts:
        // only components below the watched root are judged.
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/target/proj/src/"], among: roots) == ["/w/target/proj"])
        // The root itself, with or without a trailing slash.
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/lib"], among: roots) == ["/w/lib"])
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/lib/"], among: roots) == ["/w/lib"])
        // A sibling whose name starts with a root's name is not inside it.
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/application/src/"], among: roots).isEmpty)
        // A mixed batch keeps the real change.
        precondition(WorkspaceChangeFilter.roots(touchedBy: [
            "/w/app/target/", "/w/lib/Sources/",
        ], among: roots) == ["/w/lib"])
        // build and dist are left alone on purpose.
        precondition(WorkspaceChangeFilter.roots(touchedBy: ["/w/app/build/"], among: roots) == ["/w/app"])
        // Classification: noise alone is nothing, a stranger path is unknown.
        precondition(WorkspaceChangeFilter.classify(["/w/app/target/x/"], among: roots) == .none)
        precondition(WorkspaceChangeFilter.classify(["/w/app/src/", "/w/app/target/"], among: roots) == .roots(["/w/app"]))
        precondition(WorkspaceChangeFilter.classify(["/private/w/app/src/"], among: roots) == .unknown)
        precondition(WorkspaceChangeFilter.classify([], among: roots) == .none)
        print("Workspace change filter: noise dropped, owners found, nested and sibling roots kept apart")
    }
}
