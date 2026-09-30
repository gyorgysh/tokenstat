// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// A note belongs to the conversation visible when its action was pressed.
/// Capture this before scheduling work, and check it after every suspension.
struct ChatSteerContext: Equatable {
    private let operationID = UUID()
    let reference: WorkReference
    let generation: UInt64
    let peer: String?

    func matches(reference: WorkReference?, generation: UInt64, peer: String?,
                 scope: WorkReference.Scope?) -> Bool {
        self.reference == reference && self.generation == generation
            && self.peer == peer && self.reference.scope == scope
    }
}
