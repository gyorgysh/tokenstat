// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChatSendContext {
    /// A setup change acknowledged for the context the person is viewing is
    /// their own edit. A larger jump includes other work and needs review.
    static func afterOwnEdit(_ context: UInt64?, previous: UInt64?, updated: UInt64?) -> UInt64? {
        guard let previous, let updated, context == previous,
              previous < UInt64.max, updated == previous + 1 else { return context }
        return updated
    }
}
