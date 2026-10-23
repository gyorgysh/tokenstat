// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct TeamChatSelection: Decodable, Identifiable, Sendable {
    let id: String
    let organizationId: String
    let repositoryId: String
    let checkoutId: String
    let items: [Item]
    let complete: Bool
    let discarded: Bool
    let allowsAgentRuns: Bool
    struct Item: Decodable, Identifiable, Sendable {
        let conversation: String
        let title: String?
        let available: Bool
        let shared: Bool
        let skipped: Bool
        var id: String { conversation }
        var pending: Bool { !shared && !skipped }
    }
}
struct TeamChatSelectionReply: Decodable, Sendable {
    let selection: TeamChatSelection?
    let preview: TeamChatPreview?
}
