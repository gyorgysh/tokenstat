// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.tasks

import ai.tokenstat.tokenstat.ui.localization.L10n

import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/// Task board models and pure rules. Ports the Apple `TodoCard`,
/// `TaskEditorDraft`, `TaskBoardFilter`, `TaskResultRoute` and the run
/// receipt rules in `TaskEditorSession` and `TaskCreationSession`, so both
/// platforms answer the same questions the same way.
internal fun JsonObject.optStr(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

internal fun JsonObject.optLong(key: String): Long? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.longOrNull

internal fun JsonObject.optBool(key: String): Boolean? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.booleanOrNull

/// The token a CLI `--model` flag accepts. Drops a tab-separated label or a
/// mashed id-plus-label leftover from an older picker. Port of
/// `TodoCard.cleanModelID`.
fun cleanModelID(raw: String): String {
    val first = raw.split('\t', '\n').firstOrNull() ?: raw
    val trimmed = first.trim()
    val idx = trimmed.indexOfFirst { it.isUpperCase() }
    if (idx >= 0) {
        val prefix = trimmed.substring(0, idx)
        if (prefix.contains('-') || prefix.contains('.')) return prefix
    }
    return trimmed
}

/// The live state of a card handed to an agent. Port of `TodoDelegate`.
data class TaskDelegate(
    val runId: String = "",
    val status: String = "",
    val startedAtMs: Long = 0,
    val endedAtMs: Long? = null,
    val error: String? = null,
) {
    val isRunning: Boolean get() = status in setOf("starting", "queued", "running", "stopping")

    val label: String get() = when (status) {
        "starting" -> L10n.text("android.taskmodels.starting.aeed4d26")
        "queued" -> L10n.text("common.queued")
        "running" -> L10n.text("common.running")
        "stopping" -> L10n.text("android.taskmodels.stopping.a71ee1d4")
        "ok" -> L10n.text("common.done")
        "stopped" -> L10n.text("android.taskmodels.stopped.1a4f630a")
        "error" -> L10n.text("common.failed")
        else -> status
    }

    companion object {
        fun parse(obj: JsonObject?): TaskDelegate? {
            if (obj == null) return null
            return TaskDelegate(
                runId = obj.optStr("runId") ?: "",
                status = obj.optStr("status") ?: "",
                startedAtMs = obj.optLong("startedAtMs") ?: 0,
                endedAtMs = obj.optLong("endedAtMs"),
                error = obj.optStr("error"),
            )
        }
    }
}

/// A card on the kanban board. Port of `TodoCard`.
data class TaskCard(
    val id: String = "",
    val revision: Long? = null,
    val title: String = "",
    val kind: String = "task",
    val notes: String = "",
    val column: String = "backlog",
    val order: Long = 0,
    val priority: String = "normal",
    val backend: String = "",
    val model: String? = null,
    val effort: String? = null,
    val workspaceID: String = "",
    val budgetSeconds: Long = 0,
    val createdAtMs: Long = 0,
    val updatedAtMs: Long = 0,
    val delegate: TaskDelegate? = null,
) {
    val isNote: Boolean get() = kind == "note"
    val isArchived: Boolean get() = column == "archive"

    val columnLabel: String get() = when (column) {
        "doing" -> L10n.text("android.taskmodels.doing.cd742c53")
        "done" -> L10n.text("common.done")
        "archive" -> L10n.text("common.archive")
        else -> L10n.text("android.taskmodels.to_do.150d92c4")
    }

    /// What an agent should do. Notes first, title if the notes are empty.
    val promptForRun: String get() {
        val body = notes.trim()
        if (body.isNotEmpty()) return body
        return title.trim()
    }

    val cleanedModel: String get() = cleanModelID(model ?: "")

    companion object {
        fun parse(obj: JsonObject): TaskCard = TaskCard(
            id = obj.optStr("id") ?: "",
            revision = obj.optLong("revision"),
            title = obj.optStr("title") ?: "",
            kind = obj.optStr("kind") ?: "task",
            notes = obj.optStr("notes") ?: "",
            column = obj.optStr("column") ?: "backlog",
            order = obj.optLong("order") ?: 0,
            priority = obj.optStr("priority") ?: "normal",
            backend = obj.optStr("backend") ?: "",
            model = obj.optStr("model"),
            effort = obj.optStr("effort"),
            workspaceID = obj.optStr("workspaceId") ?: "",
            budgetSeconds = obj.optLong("budgetSeconds") ?: 0,
            createdAtMs = obj.optLong("createdAtMs") ?: 0,
            updatedAtMs = obj.optLong("updatedAtMs") ?: 0,
            delegate = TaskDelegate.parse(obj["delegate"] as? JsonObject),
        )

        fun parseList(element: kotlinx.serialization.json.JsonElement?): List<TaskCard> =
            ((element as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(::parse)
    }
}

enum class TaskRunPlacement(val raw: String) { BACKGROUND("background"), FOREGROUND("foreground") }

/// The durable answer to one task launch operation. Port of `TaskRunOutcome`.
data class TaskRunOutcome(
    val operationID: String = "",
    val cardID: String = "",
    val runID: String = "",
    val createdAtMs: Long = 0,
    val placement: TaskRunPlacement = TaskRunPlacement.BACKGROUND,
    val card: TaskCard? = null,
    val hasRun: Boolean = false,
    val runWorkspaceID: String? = null,
    val ptyID: String? = null,
) {
    companion object {
        fun parse(obj: JsonObject): TaskRunOutcome {
            val run = obj["run"] as? JsonObject
            return TaskRunOutcome(
                operationID = obj.optStr("operationId") ?: "",
                cardID = obj.optStr("cardId") ?: "",
                runID = obj.optStr("runId") ?: "",
                createdAtMs = obj.optLong("createdAtMs") ?: 0,
                placement = if (obj.optStr("placement") == "foreground") TaskRunPlacement.FOREGROUND else TaskRunPlacement.BACKGROUND,
                card = (obj["card"] as? JsonObject)?.let(TaskCard::parse),
                hasRun = run != null,
                runWorkspaceID = run?.optStr("workspaceId"),
                ptyID = run?.optStr("ptyId"),
            )
        }
    }
}

/// A confirmed creation. Port of `TaskCreationOutcome`.
data class TaskCreationOutcome(
    val operationID: String = "",
    val cardID: String = "",
    val createdAtMs: Long = 0,
    val card: TaskCard? = null,
) {
    companion object {
        fun parse(obj: JsonObject): TaskCreationOutcome = TaskCreationOutcome(
            operationID = obj.optStr("operationId") ?: "",
            cardID = obj.optStr("cardId") ?: "",
            createdAtMs = obj.optLong("createdAtMs") ?: 0,
            card = (obj["card"] as? JsonObject)?.let(TaskCard::parse),
        )
    }
}

/// Shared task fields for creation and editing. Seconds remain exact when a
/// saved budget is not a whole number of minutes. Port of `TaskEditorDraft`.
data class TaskEditorDraft(
    val title: String = "",
    val prompt: String = "",
    val workspaceID: String = "",
    val priority: String = "normal",
    val backend: String = "",
    val model: String = "",
    val effort: String = "",
    val budgetValue: String = "180",
    val budgetUnit: String = "minutes",
    val noTimeLimit: Boolean = false,
) {
    companion object {
        fun fromCard(card: TaskCard): TaskEditorDraft {
            val noLimit = card.budgetSeconds == 0L
            val unit = if (card.budgetSeconds % 60 == 0L) "minutes" else "seconds"
            return TaskEditorDraft(
                title = card.title,
                prompt = card.notes,
                workspaceID = card.workspaceID,
                priority = card.priority,
                backend = card.backend,
                model = card.model ?: "",
                effort = card.effort ?: "",
                noTimeLimit = noLimit,
                budgetUnit = unit,
                budgetValue = if (noLimit) "180" else if (unit == "minutes") (card.budgetSeconds / 60).toString() else card.budgetSeconds.toString(),
            )
        }

        fun blank(workspaceID: String, budgetSeconds: Long = 10_800): TaskEditorDraft {
            val noLimit = budgetSeconds == 0L
            val unit = if (budgetSeconds % 60 == 0L) "minutes" else "seconds"
            return TaskEditorDraft(
                workspaceID = workspaceID,
                noTimeLimit = noLimit,
                budgetUnit = unit,
                budgetValue = if (noLimit) "180" else if (unit == "minutes") (budgetSeconds / 60).toString() else budgetSeconds.toString(),
            )
        }
    }

    val budgetSeconds: Long? get() {
        if (noTimeLimit) return 0
        val amount = budgetValue.trim().toLongOrNull() ?: return null
        if (amount <= 0) return null
        val product = if (budgetUnit == "minutes") amount * 60 else amount
        if (budgetUnit == "minutes" && product / 60 != amount) return null
        return product
    }

    val validation: String? get() {
        if (title.trim().isEmpty()) return L10n.text("android.taskmodels.give_this_task_a_title.30531d14")
        if (title.toByteArray().size > 4096) return L10n.text("android.taskmodels.shorten_the_title_to_4_kib_or_less.f40e37a7")
        if (prompt.toByteArray().size > 1024 * 1024) return L10n.text("android.taskmodels.shorten_the_prompt_to_1_mib_or_less.dba63070")
        if (budgetSeconds == null) return L10n.text("android.taskmodels.enter_a_positive_time_limit_or_choose_no_l.3b7996e8")
        if (budgetUnit != "minutes" && budgetUnit != "seconds") return L10n.text("android.taskmodels.choose_minutes_or_seconds_for_the_time_lim.18aaf5a6")
        if (priority != "low" && priority != "normal" && priority != "high") return L10n.text("android.taskmodels.choose_a_task_priority.d4cee784")
        return null
    }

    fun matches(card: TaskCard): Boolean =
        title.trim() == card.title &&
            prompt == card.notes &&
            workspaceID == card.workspaceID &&
            priority == card.priority &&
            backend == card.backend &&
            model.trim() == (card.model ?: "").trim() &&
            effort.trim() == (card.effort ?: "").trim() &&
            budgetSeconds == card.budgetSeconds
}

sealed class TaskBoardFolder {
    data object All : TaskBoardFolder()
    data object Uncategorized : TaskBoardFolder()
    data class Folder(val id: String) : TaskBoardFolder()

    fun contains(card: TaskCard): Boolean = when (this) {
        All -> true
        Uncategorized -> card.workspaceID.isEmpty()
        is Folder -> card.workspaceID == id
    }
}

enum class TaskBoardAttention(val label: String) {
    ALL(L10n.text("android.taskmodels.all_tasks.cb664823")),
    RUNNING(L10n.text("common.running")),
    NEEDS_ATTENTION(L10n.text("android.taskmodels.needs_attention.c1ebc781")),
    HIGH_PRIORITY(L10n.text("android.taskmodels.high_priority.b699a8c8")),
    ;

    fun contains(card: TaskCard): Boolean = when (this) {
        ALL -> true
        RUNNING -> card.delegate?.isRunning == true
        NEEDS_ATTENTION -> card.delegate?.status == "error"
        HIGH_PRIORITY -> card.priority == "high"
    }
}

/// Which cards the board shows. Port of `TaskBoardFilter`.
data class TaskBoardFilter(
    val folder: TaskBoardFolder = TaskBoardFolder.All,
    val query: String = "",
    val backend: String = "",
    val attention: TaskBoardAttention = TaskBoardAttention.ALL,
    val archived: Boolean = false,
    val newestFirst: Boolean = false,
) {
    fun visible(cards: List<TaskCard>): List<TaskCard> {
        val words = query.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return cards.mapIndexed { index, card -> index to card }
            .filter { (_, card) ->
                !card.isNote && folder.contains(card) && (card.column == "archive") == archived &&
                    (backend.isEmpty() || card.backend == backend) && attention.contains(card) &&
                    words.all { word ->
                        card.title.contains(word, ignoreCase = true) ||
                            card.notes.contains(word, ignoreCase = true)
                    }
            }
            .sortedWith { first, second ->
                val left = first.second
                val right = second.second
                when {
                    newestFirst && left.createdAtMs != right.createdAtMs ->
                        right.createdAtMs.compareTo(left.createdAtMs)
                    left.order != right.order -> left.order.compareTo(right.order)
                    else -> first.first.compareTo(second.first)
                }
            }
            .map { it.second }
    }
}

/// Run readiness: why the saved card cannot start, or null when the checks
/// this client can see are satisfied. Port of `TaskEditorSession.runReadiness`.
fun taskRunReadiness(card: TaskCard, folders: List<FolderRef>): String? {
    if (card.workspaceID.trim().isEmpty()) return L10n.text("android.taskmodels.assign_a_folder_before_running_this_task.6d7e591f")
    val folder = folders.firstOrNull { it.id == card.workspaceID }
    if (folder != null && !folder.exists) return L10n.text("android.taskmodels.this_folder_is_no_longer_available_on_the.9a90a747")
    if (folders.isNotEmpty() && folder == null) return L10n.text("android.taskmodels.this_folder_is_no_longer_available_on_the.9a90a747")
    if (card.backend.trim().isEmpty()) return L10n.text("android.taskmodels.choose_an_agent_before_running_this_task.8c283f81")
    if (card.promptForRun.isEmpty()) return L10n.text("android.taskmodels.write_a_prompt_before_running_this_task.756d3037")
    return null
}

data class FolderRef(val id: String = "", val name: String = "", val exists: Boolean = true) {
    companion object {
        fun parse(obj: JsonObject): FolderRef = FolderRef(
            id = obj.optStr("id") ?: "",
            name = obj.optStr("name") ?: "",
            exists = (obj["exists"] as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull ?: true,
        )
    }
}

data class BackendRef(val id: String = "", val label: String = "", val models: List<String> = emptyList(), val efforts: List<String> = emptyList()) {
    companion object {
        fun parse(obj: JsonObject): BackendRef = BackendRef(
            id = obj.optStr("id") ?: "",
            label = obj.optStr("label") ?: "",
            models = (obj["models"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList(),
            efforts = (obj["efforts"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList(),
        )
    }
}

/// Accepts a run outcome against the submission that asked for it. A retry
/// repeats the same durable operation and can never create a second run.
/// Port of `TaskEditorSession.acceptRun` plus `reconcileRun` outcomes.
sealed class RunAcceptance {
    data class Accepted(val outcome: TaskRunOutcome) : RunAcceptance()
    data class Rejected(val message: String) : RunAcceptance()
    data class Pending(val message: String) : RunAcceptance()
}

fun acceptTaskRun(outcome: TaskRunOutcome, operationID: String, cardID: String): RunAcceptance {
    if (outcome.operationID != operationID || outcome.cardID != cardID) {
        return RunAcceptance.Rejected(L10n.text("android.taskmodels.the_computer_returned_a_different_task_run.0580d53a"))
    }
    if (!outcome.hasRun && outcome.card == null) {
        return RunAcceptance.Rejected(L10n.text("android.taskmodels.this_task_was_deleted_before_the_request_c.291a0c1e"))
    }
    if (!outcome.hasRun) {
        return RunAcceptance.Pending(L10n.text("android.taskmodels.the_computer_accepted_this_request_but_has.582c4fe2"))
    }
    return RunAcceptance.Accepted(outcome)
}

/// Fresh operation ids. Creation, run and launch each carry their own prefix
/// so a receipt can never confirm the wrong kind of request.
object TaskOperations {
    fun creationID(): String = "task-create-${UUID.randomUUID()}"
    fun runID(): String = "task-run-${UUID.randomUUID()}"
    fun automationCreationID(): String = "automation-create-${UUID.randomUUID()}"
    fun automationRunID(): String = "automation-run-${UUID.randomUUID()}"
}

/// One task result: the exact run, and whether its folder can be reviewed.
/// Port of `TaskResultRoute`.
data class TaskResultRoute(
    val runID: String = "",
    val workspaceID: String = "",
    val folderName: String = "",
    val hostName: String = "",
    val folderMissing: Boolean = false,
    val changeCount: Int? = null,
) {
    val reviewState: ReviewState get() = when {
        workspaceID.isEmpty() -> ReviewState.UNCATEGORIZED
        folderMissing -> ReviewState.FOLDER_MISSING
        else -> ReviewState.READY
    }

    enum class ReviewState { READY, UNCATEGORIZED, FOLDER_MISSING }

    fun reviewMessage(): String? = when (reviewState) {
        ReviewState.READY -> null
        ReviewState.UNCATEGORIZED -> L10n.text("android.taskmodels.this_task_has_no_folder_assign_one_to_revi.ec78820b")
        ReviewState.FOLDER_MISSING -> {
            val host = hostName.trim()
            if (host.isEmpty()) L10n.text("android.taskmodels.this_folder_is_no_longer_available_on_the.be3071ed")
            else L10n.text("android.taskmodels.this_folder_is_no_longer_available_on_0.70d7366a", "${host}")
        }
    }

    val canReviewWorkspace: Boolean get() = reviewState == ReviewState.READY

    val folderLabel: String get() {
        val name = folderName.trim()
        if (name.isNotEmpty()) return name
        if (workspaceID.isEmpty()) return L10n.text("android.taskmodels.uncategorized.8d40d123")
        return L10n.text("android.taskmodels.folder.74ccd433")
    }

    fun preservesRun(selectedRunID: String?): Boolean = runID.isNotEmpty() && selectedRunID == runID

    fun changesCaption(): String {
        if (reviewState != ReviewState.READY) return reviewMessage() ?: L10n.text("android.taskmodels.changes.bbd4b6a8")
        val count = changeCount
        if (count != null) {
            if (count == 0) return L10n.text("android.taskmodels.working_tree_matches_the_last_commit.419b69e6")
            return if (count == 1) L10n.text("android.taskmodels.1_file_to_review.0d600164") else L10n.text("android.taskmodels.0_files_to_review.b2f93852", "${count}")
        }
        return L10n.text("android.taskmodels.uncommitted_files_in_this_folder.9b817339")
    }
}

/// Live-first run ordering shared by automation, task and workflow history.
/// Port of `AutomationRunHistory`: live runs stay first so Stop is never
/// behind Earlier runs, completed runs are newest first.
data class RunRef(val id: String, val startedAtMs: Long, val live: Boolean)

object RunHistory {
    const val PREVIEW_COUNT = 5
    const val PAGE_SIZE = 20

    fun ordered(runs: List<RunRef>): List<RunRef> =
        runs.sortedWith { lhs, rhs ->
            when {
                lhs.live != rhs.live -> if (lhs.live) -1 else 1
                lhs.startedAtMs != rhs.startedAtMs -> rhs.startedAtMs.compareTo(lhs.startedAtMs)
                else -> rhs.id.compareTo(lhs.id)
            }
        }

    fun page(runs: List<RunRef>, shown: Int): List<RunRef> = ordered(runs).take(maxOf(0, shown))

    fun preview(runs: List<RunRef>): List<RunRef> = ordered(runs).take(PREVIEW_COUNT)

    fun remaining(total: Int, shown: Int): Int = maxOf(0, total - maxOf(0, shown))

    fun showsAllRuns(total: Int): Boolean = total > PREVIEW_COUNT

    fun latest(runs: List<RunRef>): RunRef? = ordered(runs).firstOrNull()
}

/// The row that opens the complete run history from a short preview.
/// Port of `ClientAllRunsRow`.
fun allRunsLabel(count: Int): String = if (count == 1) L10n.text("android.taskmodels.all_runs.33866ac3") else L10n.text("android.taskmodels.all_0_runs.8e631c72", "${count}")
