// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Each mounted reader releases only its own claim. A fold can mount the
/// successor before the predecessor disappears; separate scenes can also
/// read different conversations at the same time.
struct ChatSurfacePresence {
    private struct Surface {
        let conversation: String
        let active: Bool
    }
    private var surfaces: [UUID: Surface] = [:]
    private var order: [UUID] = []

    mutating func update(owner: UUID, conversation: String?, active: Bool) {
        remove(owner: owner)
        guard let conversation, !conversation.isEmpty else { return }
        surfaces[owner] = Surface(conversation: conversation, active: active)
        order.append(owner)
    }

    mutating func remove(owner: UUID) {
        surfaces.removeValue(forKey: owner)
        order.removeAll { $0 == owner }
    }

    var visibleConversation: String? {
        order.reversed().compactMap { surfaces[$0] }.first(where: \.active)?.conversation
    }

    func isWatching(_ conversation: String) -> Bool {
        surfaces.values.contains { $0.active && $0.conversation == conversation }
    }
}
