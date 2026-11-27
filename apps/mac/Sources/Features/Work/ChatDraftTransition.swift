// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum ChatDraftTransition: Equatable {
    case adopt(WorkReference)
    case swap(WorkReference?)
    case keep

    static func resolve(
        incoming: String?, reference: WorkReference?,
        current: String?, currentReference: WorkReference?
    ) -> Self {
        guard incoming == current else { return .swap(reference) }
        if incoming != nil, currentReference == nil, let reference { return .adopt(reference) }
        guard reference == currentReference else { return .swap(reference) }
        return .keep
    }
}
