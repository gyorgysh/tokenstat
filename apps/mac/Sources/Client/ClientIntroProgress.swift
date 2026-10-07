// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Observation

/// Retained by the scene root; responsive presentations only borrow it.
@MainActor @Observable
final class ClientIntroProgress {
    static let pageCount = 3
    var page = 0
    @discardableResult func advance() -> Bool {
        guard page < Self.pageCount - 1 else { return false }
        page += 1
        return true
    }
    func back() { if page > 0 { page -= 1 } }
}
