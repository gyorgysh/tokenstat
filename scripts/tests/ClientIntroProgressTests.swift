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
        precondition(!progress.advance() && progress.page == 2)
        progress.back(); precondition(progress.page == 1)
        precondition(ClientIntroProgress.pageCount == 3)
        print("Intro: three pages, retained progress and bounded Back/Continue passed")
    }
}
