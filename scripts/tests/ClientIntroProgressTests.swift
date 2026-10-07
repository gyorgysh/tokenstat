// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientIntroProgress.swift.
import Foundation
@main struct ClientIntroProgressTests {
    @MainActor static func main() {
        let progress = ClientIntroProgress()
        progress.back(); precondition(progress.page == 0)
        precondition(progress.advance() && progress.page == 1)
        for _ in 0..<30 {
            let borrowed = progress
            precondition(borrowed === progress && borrowed.page == 1)
        }
        precondition(progress.advance() && progress.page == 2)
        for expected in 3..<6 { precondition(progress.advance() && progress.page == expected) }
        precondition(!progress.advance() && progress.page == 5)
        progress.back(); precondition(progress.page == 4)
        precondition(ClientIntroProgress.pageCount == 6)
        print("Intro: six pages, retained progress and bounded Back/Continue passed")
    }
}
