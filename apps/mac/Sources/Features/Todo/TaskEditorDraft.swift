// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Shared task fields for desktop and mobile. Seconds remain exact when a
/// saved budget is not a whole number of minutes.
struct TaskEditorDraft: Codable, Equatable, Sendable {
    enum Invalid: LocalizedError {
        case fields(String)
        var errorDescription: String? { switch self { case let .fields(message): message } }
    }
    var title: String
    var prompt: String
    var workspaceID: String
    var priority: String
    var backend: String
    var model: String
    var effort: String
    var budgetValue: String
    var budgetUnit: String
    var noTimeLimit: Bool

    init(_ card: TodoCard) {
        title = card.title
        prompt = card.notes
        workspaceID = card.workspaceID
        priority = card.priority
        backend = card.backend
        model = card.model ?? ""
        effort = card.effort ?? ""
        noTimeLimit = card.budgetSeconds == 0
        budgetUnit = card.budgetSeconds % 60 == 0 ? "minutes" : "seconds"
        budgetValue = noTimeLimit ? "180" : String(budgetUnit == "minutes" ? card.budgetSeconds / 60 : card.budgetSeconds)
    }

    init(workspaceID: String, budgetSeconds: UInt64) {
        title = ""; prompt = ""; self.workspaceID = workspaceID
        priority = "normal"; backend = ""; model = ""; effort = ""
        noTimeLimit = budgetSeconds == 0
        budgetUnit = budgetSeconds % 60 == 0 ? "minutes" : "seconds"
        budgetValue = noTimeLimit ? "180" : String(budgetUnit == "minutes" ? budgetSeconds / 60 : budgetSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case title, prompt, priority, backend, model, effort, budgetValue, budgetUnit, noTimeLimit
        case workspaceID = "workspaceId"
    }

    var budgetSeconds: UInt64? {
        if noTimeLimit { return 0 }
        guard let amount = UInt64(budgetValue.trimmingCharacters(in: .whitespacesAndNewlines)), amount > 0 else { return nil }
        let product = amount.multipliedReportingOverflow(by: budgetUnit == "minutes" ? 60 : 1)
        return product.overflow ? nil : product.partialValue
    }

    var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this task a title." }
        if title.utf8.count > 4096 { return "Shorten the title to 4 KiB or less." }
        if prompt.utf8.count > 1024 * 1024 { return "Shorten the prompt to 1 MiB or less." }
        if budgetSeconds == nil { return "Enter a positive time limit, or choose No limit." }
        if !["minutes", "seconds"].contains(budgetUnit) { return "Choose minutes or seconds for the time limit." }
        if !["low", "normal", "high"].contains(priority) { return "Choose a task priority." }
        return nil
    }

    func matches(_ card: TodoCard) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) == card.title
            && prompt == card.notes && workspaceID == card.workspaceID && priority == card.priority
            && backend == card.backend && model.trimmingCharacters(in: .whitespacesAndNewlines) == (card.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            && effort.trimmingCharacters(in: .whitespacesAndNewlines) == (card.effort ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            && budgetSeconds == card.budgetSeconds
    }

    func parameters(id: String, revision: UInt64) throws -> [String: Any] {
        guard validation == nil, let budgetSeconds else { throw Invalid.fields(validation ?? "Check this task's settings.") }
        return ["id": id, "expectedRevision": revision, "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "notes": prompt, "workspaceId": workspaceID, "priority": priority, "backend": backend,
                "model": model, "effort": effort, "budgetSeconds": budgetSeconds]
    }
}
