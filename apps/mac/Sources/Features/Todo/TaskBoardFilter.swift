// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum TaskBoardFolder: Hashable, Sendable {
    case all, uncategorized, folder(String)
    func contains(_ card: TodoCard) -> Bool {
        switch self {
        case .all: true
        case .uncategorized: card.workspaceID.isEmpty
        case let .folder(id): card.workspaceID == id
        }
    }
}

enum TaskBoardAttention: String, CaseIterable, Sendable {
    case all, running, needsAttention, highPriority
    var label: String {
        switch self {
        case .all: "All tasks"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .highPriority: "High priority"
        }
    }
    func contains(_ card: TodoCard) -> Bool {
        switch self {
        case .all: true
        case .running: card.delegate?.isRunning == true
        case .needsAttention: card.delegate?.status == "error"
        case .highPriority: card.priority == "high"
        }
    }
}

struct TaskBoardFilter: Equatable, Sendable {
    var folder: TaskBoardFolder = .all
    var query = ""
    var backend = ""
    var attention: TaskBoardAttention = .all
    var archived = false
    var newestFirst = false

    func cards(from cards: [TodoCard]) -> [TodoCard] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return cards.enumerated().filter { entry in
            let card = entry.element
            return !card.isNote && folder.contains(card) && (card.column == "archive") == archived
                && (backend.isEmpty || card.backend == backend) && attention.contains(card)
                && words.allSatisfy { word in card.title.localizedCaseInsensitiveContains(word) || card.notes.localizedCaseInsensitiveContains(word) }
        }.sorted { first, second in
            let left = first.element, right = second.element
            if newestFirst && left.createdAtMs != right.createdAtMs { return left.createdAtMs > right.createdAtMs }
            if left.order != right.order { return left.order < right.order }
            return first.offset < second.offset
        }.map(\.element)
    }
}
