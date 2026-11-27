// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

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
