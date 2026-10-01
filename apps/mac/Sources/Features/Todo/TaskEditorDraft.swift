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
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("apple.taskeditordraft.give_this_task_a_title.30531d14") }
        if title.utf8.count > 4096 { return L10n.text("apple.taskeditordraft.shorten_the_title_to_4_kib_or_less.f40e37a7") }
        if prompt.utf8.count > 1024 * 1024 { return L10n.text("apple.taskeditordraft.shorten_the_prompt_to_1_mib_or_less.dba63070") }
        if budgetSeconds == nil { return L10n.text("apple.taskeditordraft.enter_a_positive_time_limit_or_choose_no_l.3b7996e8") }
        if !["minutes", "seconds"].contains(budgetUnit) { return L10n.text("apple.taskeditordraft.choose_minutes_or_seconds_for_the_time_lim.18aaf5a6") }
        if !["low", "normal", "high"].contains(priority) { return L10n.text("apple.taskeditordraft.choose_a_task_priority.d4cee784") }
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
        guard validation == nil, let budgetSeconds else { throw Invalid.fields(validation ?? L10n.text("apple.taskeditordraft.check_this_task_s_settings.087e8f02")) }
        return ["id": id, "expectedRevision": revision, "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "notes": prompt, "workspaceId": workspaceID, "priority": priority, "backend": backend,
                "model": model, "effort": effort, "budgetSeconds": budgetSeconds]
    }
}
