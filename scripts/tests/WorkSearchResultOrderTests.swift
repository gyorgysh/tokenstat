// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkSearchResultOrder.swift WorkReference.swift.
import Foundation
@main struct WorkSearchResultOrderTests {
    static func main() {
        let scope = WorkReference.Scope.local(installationID: "test")
        func ref(_ id: String, anchor: String = "user-s1") -> WorkReference {
            .init(scope: scope, hostIdentity: "host", workspaceID: "folder", kind: .conversation, itemID: id, anchor: anchor)
        }
        let a = ref("a"), b = ref("b"), c = ref("c"), d = ref("d")
        assert(WorkSearchResultOrder.retained(previous: [a,b,c], incoming: [d,c,b,a]) == [a,b,c])
        assert(WorkSearchResultOrder.retained(previous: [a,b,c], incoming: [d,c,a]) == [a,c])
        let changed = ref("b", anchor: "text-s8")
        assert(WorkSearchResultOrder.retained(previous: [a,b,c], incoming: [changed,c]) == [changed,c])
        assert(WorkSearchResultOrder.retained(previous: [a,b], incoming: []) == [])
        print("Search result order: stable survivors, immediate removal, deferred arrivals and current anchors passed")
    }
}
