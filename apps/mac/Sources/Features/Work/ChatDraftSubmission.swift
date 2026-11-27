// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct ChatDraftSubmission {
    let conversationID: String
    let peer: String?
    let scope: WorkReference.Scope?
    let reference: WorkReference?
    let generation: UInt64
    let text: String
    let draftText: String
    let attachments: [ChatAttachment]
    let messageID: String?
    var expectedRevision: UInt64? = nil

    func owns(reference: WorkReference?, conversationID: String?, peer: String?,
              scope: WorkReference.Scope?) -> Bool {
        self.reference == reference && self.conversationID == conversationID
            && self.peer == peer && self.scope == scope
    }
}
