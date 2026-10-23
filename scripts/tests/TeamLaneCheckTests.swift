// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamLaneCheck.swift.
import Foundation

@main struct TeamLaneCheckTests {
    static func main() {
        let command = ["sh", "-c", "cargo test", "", "folder with spaces"]
        precondition(TeamLaneCheck.arguments(command.joined(separator: " "), loaded: command) == command,
                     "Saving another lane setting must preserve the loaded command's argument boundaries")
        precondition(TeamLaneCheck.arguments("cargo test --workspace", loaded: command) == ["cargo", "test", "--workspace"],
                     "An edited command must use the newly entered arguments")
        precondition(TeamLaneCheck.arguments("", loaded: command).isEmpty,
                     "Clearing a loaded command must remove all arguments")
        print("Team lane check argument roundtrip passed")
    }
}
