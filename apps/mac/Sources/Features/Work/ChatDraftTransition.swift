// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// What happens to the words in the composer when the screen points at
/// another conversation, or at the same one under an identity that has only
/// just become known.
///
/// The awkward case is the second one. The account and the machine identity
/// that key a draft are read a moment after launch, so words typed in that
/// moment have no owner yet. Treating that as a change of conversation would
/// clear the composer while somebody was writing in it.
enum ChatDraftTransition: Equatable {
    /// The same conversation, now with an owner. Keep the words and key them.
    case adopt(WorkReference)
    /// Another conversation. Its own words go on screen, and nothing else.
    case swap(WorkReference?)
    /// Nothing the composer needs to act on.
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
