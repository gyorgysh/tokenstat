// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift and BrowserHistory.swift.
import Foundation

@main struct BrowserHistoryTests {
    @MainActor static func main() {
        let name = "browser-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = BrowserHistory(defaults: defaults)
        let scope = WorkReference.Scope.account(origin: "https://example.test", handle: "account-a")!
        func owner(_ host: String = "host-a", _ folder: String = "project-a", _ account: WorkReference.Scope? = nil) -> WorkReference {
            WorkReference(scope: account ?? scope, hostIdentity: host, workspaceID: folder, kind: .workspace, itemID: nil)
        }
        let a = owner()
        defaults.set("3000", forKey: "browser.lastPort")
        precondition(history.portSuggestion(for: a) == "3000")
        precondition(history.entry(for: a).ports.isEmpty, "Reading a fallback migrated it into a project")
        history.record(BrowserTarget("localhost:5173/editor?q=one#preview")!, for: a)
        precondition(history.entry(for: a).lastTarget == "http://localhost:5173/editor?q=one#preview")
        precondition(history.portSuggestion(for: a) == "5173")
        precondition(history.entry(for: owner("host-b")).ports.isEmpty)
        precondition(history.entry(for: owner("host-a", "project-b")).ports.isEmpty)
        let b = WorkReference.Scope.account(origin: "https://other.test", handle: "account-a")!
        precondition(history.entry(for: owner("host-a", "project-a", b)).ports.isEmpty)
        for port in 3000...3010 { history.record(BrowserTarget(String(port))!, for: a) }
        history.record(BrowserTarget("3008")!, for: a)
        precondition(history.entry(for: a).ports == [3008, 3010, 3009, 3007, 3006, 3005, 3004, 3003])
        precondition(BrowserHistory(defaults: defaults).entry(for: a) == history.entry(for: a))
        for invalid in ["0", "65536", "-1", "https://example.test:3000", "http://127.evil.test:3000", "http://127.999.0.1:3000", "http://user:secret@localhost:3000", "javascript:alert(1)"] {
            precondition(BrowserTarget(invalid) == nil, invalid)
        }
        let target = BrowserTarget("http://localhost:3000/path?q=one#preview")!
        let first = "http://127.0.0.1:45123/"
        let next = "http://127.0.0.1:45234/"
        precondition(target.transportURL(through: first) == "http://127.0.0.1:45123/path?q=one#preview")
        precondition(target.transportURL(through: next) == "http://127.0.0.1:45234/path?q=one#preview")
        precondition(target.originalURL(for: "http://127.0.0.1:45123/other?q=two", through: first) == "http://localhost:3000/other?q=two")
        precondition(target.originalURL(for: "http://127.0.0.1:45678/", through: first) == nil)
        precondition(BrowserTarget("http://[::1]:3000/")?.port == 3000)
        history.record(target, for: nil)
        print("Browser history: ownership, persistence, canonical targets, bounded ports and fresh listeners passed")
    }
}
