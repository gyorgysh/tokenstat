// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChangePathMatch.swift.
import Foundation

@main enum ChangePathMatchTests {
    static func main() {
        let paths = ["file.swift", "src/file.swift", "src/other.swift"]
        precondition(ChangePathMatch.path("/repo/src/file.swift", in: paths) == "src/file.swift")
        precondition(ChangePathMatch.path("C:\\repo\\src\\file.swift", in: paths) == "src/file.swift")
        precondition(ChangePathMatch.path("src/other.swift", in: paths) == "src/other.swift")
        precondition(ChangePathMatch.path("/repo/not-file.swift", in: paths) == nil)
        precondition(ChangePathMatch.path("", in: paths) == nil)
        print("Change focus: specific suffixes, Windows separators, relative paths and absent files passed")
    }
}
