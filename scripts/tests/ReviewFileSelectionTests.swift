// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChangePathMatch.swift.
import Foundation

@main struct ReviewFileSelectionTests {
    static func main() {
        let files = ["one/readme.md", "two/readme.md", "src/main.swift"]
        precondition(ChangePathMatch.reviewSelection(nil, focus: "/repo/two/readme.md", paths: files) == files[1])
        precondition(ChangePathMatch.reviewSelection(files[0], focus: files[1], paths: files) == files[0])
        precondition(ChangePathMatch.reviewSelection("removed", focus: nil, paths: files) == files[0])
        precondition(ChangePathMatch.reviewSelection(nil, focus: nil, paths: []) == nil)
        precondition(ChangePathMatch.reviewSelection(nil, focus: "C:\\repo\\src\\main.swift", paths: files) == files[2])
        print("Review file selection: focused paths, duplicate names, removed files and empty lists pass")
    }
}
