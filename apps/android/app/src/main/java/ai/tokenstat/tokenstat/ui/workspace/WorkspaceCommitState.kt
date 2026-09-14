// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.logic.CommitDraft
import ai.tokenstat.tokenstat.ui.logic.FileSelection
import ai.tokenstat.tokenstat.ui.logic.OperationState
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// P1 operation semantics, ported from `GitCommitSession.swift`.
///
/// Selection stays local until the reviewed content is submitted. A review
/// freezes the selection without staging anything. A lost response never
/// triggers a retry or a new operation id: the outcome is checked first,
/// reconciled second, and only a missing recorded outcome allows retrying
/// the same submission. A success clears the draft.
class CommitUiState(val peer: String, val workspace: String) {
    var branch by mutableStateOf<String?>(null)
    var files by mutableStateOf<List<JsonObject>>(emptyList())
    var ahead by mutableStateOf(0)
    var isRepo by mutableStateOf(true)
    var exists by mutableStateOf(true)
    var selection by mutableStateOf<Set<String>>(emptySet())
    var review by mutableStateOf<JsonObject?>(null)
    var title by mutableStateOf("")
    var details by mutableStateOf("")
    var operationId by mutableStateOf<String?>(null)
    var outcome by mutableStateOf<JsonObject?>(null)
    var canRetry by mutableStateOf(false)
    var working by mutableStateOf(false)
    var loaded by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    val message: String get() = CommitDraft.message(title, details)
    val reviewPaths: Set<String>? get() = review?.paths()
    val outcomeState: String? get() = outcome?.str("state")

    val canCommit: Boolean
        get() = loaded && !working && operationId == null &&
            CommitDraft.canCommit(title, reviewPaths, selection)

    fun select(path: String) {
        if (working || operationId != null) return
        selection = FileSelection.toggle(selection, path)
        review = null
        outcome = null
    }

    fun selectAll() {
        if (working || operationId != null) return
        val all = files.mapNotNull { it.str("path") }.toSet()
        selection = FileSelection.selectAllOrNone(selection, all)
        review = null
        outcome = null
    }

    suspend fun loadStatus(model: AppViewModel, hostLabel: String) {
        runCatching {
            model.workspaceSection(peer, "workspace.status", buildJsonObject { put("id", workspace) })
        }.onSuccess { element ->
            val folder = element as? JsonObject
            val git = folder?.get("git") as? JsonObject
            exists = folder?.bol("exists") ?: true
            isRepo = git?.bol("isRepo") ?: true
            branch = git?.str("branch")
            ahead = git?.get("ahead")?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0
            val fresh = git?.get("files")?.let { asObjects(it) }
                ?: asObjects(element).ifEmpty { asObjects(folder?.get("files")) }
            files = fresh
            if (review == null && operationId == null) {
                selection = FileSelection.reconcile(selection, fresh.mapNotNull { it.str("path") }.toSet())
            }
            error = null
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loaded = true
    }

    suspend fun prepareReview(model: AppViewModel, hostLabel: String, supportsSelectedCommit: Boolean) {
        if (!loaded || working || operationId != null || selection.isEmpty()) return
        working = true
        try {
            if (!supportsSelectedCommit) {
                error = "Update the connected computer to commit selected files."
                return
            }
            val wanted = selection
            runCatching {
                model.workspaceSection(peer, "workspace.commitReview", buildJsonObject {
                    put("id", workspace)
                    put("paths", kotlinx.serialization.json.JsonArray(wanted.sorted().map { kotlinx.serialization.json.JsonPrimitive(it) }))
                })
            }.onSuccess {
                if (selection != wanted) return
                review = it as? JsonObject
                outcome = null
                error = null
            }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        } finally {
            working = false
        }
    }

    suspend fun submit(model: AppViewModel, hostLabel: String, context: Context) {
        val frozen = review ?: return
        if (!canCommit) return
        working = true
        try {
            val opId = java.util.UUID.randomUUID().toString()
            canRetry = false
            operationId = opId
            save(context)
            runCatching {
                model.workspaceSection(peer, "workspace.commitSelected", buildJsonObject {
                    put("id", workspace)
                    put("operationId", opId)
                    put("review", frozen)
                    put("message", message)
                }) as? JsonObject
            }.onSuccess {
                adopt(it, null)
                save(context)
            }.onFailure {
                // No rollback, retry or new id follows a lost response.
                error = "The commit outcome has not been confirmed. Check its outcome before starting another. " +
                    TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            }
        } finally {
            working = false
        }
    }

    suspend fun checkOutcome(model: AppViewModel, hostLabel: String, context: Context) {
        val opId = operationId ?: return
        if (working) return
        working = true
        try {
            val first = runCatching {
                model.workspaceSection(peer, "workspace.commitReceipt", buildJsonObject {
                    put("id", workspace); put("operationId", opId)
                })
            }.getOrNull()
            val receipt = first as? JsonObject
            if (receipt != null) {
                canRetry = false
                val state = receipt.str("state") ?: ""
                if (OperationState.unresolved(state)) {
                    val reconciled = runCatching {
                        model.workspaceSection(peer, "workspace.commitRecover", buildJsonObject {
                            put("id", workspace); put("operationId", opId)
                        }) as? JsonObject
                    }.getOrNull()
                    if (reconciled != null) adopt(reconciled, context)
                } else {
                    adopt(receipt, context)
                }
                save(context)
            } else {
                canRetry = true
                error = "The computer has no recorded outcome yet. You can retry this same submission."
            }
        } catch (e: Exception) {
            error = TunnelCopy.display(e.message ?: "The request failed.", hostLabel)
        } finally {
            working = false
        }
    }

    suspend fun retry(model: AppViewModel, hostLabel: String, context: Context) {
        val opId = operationId ?: return
        val frozen = review ?: return
        if (working || !canRetry) return
        working = true
        try {
            save(context)
            canRetry = false
            runCatching {
                model.workspaceSection(peer, "workspace.commitSelected", buildJsonObject {
                    put("id", workspace)
                    put("operationId", opId)
                    put("review", frozen)
                    put("message", message)
                }) as? JsonObject
            }.onSuccess {
                adopt(it, null)
                save(context)
            }.onFailure {
                error = "Check this commit's outcome before starting another. " +
                    TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            }
        } finally {
            working = false
        }
    }

    private fun adopt(receipt: JsonObject?, context: Context?) {
        if (receipt == null) return
        if (receipt.str("operationId") != operationId) return
        outcome = receipt
        error = null
        val state = receipt.str("state") ?: ""
        if (OperationState.succeeded(state)) {
            selection = emptySet()
            review = null
            operationId = null
            title = ""
            details = ""
            canRetry = false
            context?.let { save(it) }
        } else if (!OperationState.unresolved(state)) {
            operationId = null
            review = null
            context?.let { save(it) }
        }
    }

    fun save(context: Context) {
        val prefs = context.getSharedPreferences("tokenstat.commit.v1", Context.MODE_PRIVATE)
        prefs.edit()
            .putString(key("title"), title)
            .putString(key("details"), details)
            .putStringSet(key("paths"), selection)
            .putString(key("operationId"), operationId)
            .apply()
    }

    fun restore(context: Context) {
        if (loaded) return
        val prefs = context.getSharedPreferences("tokenstat.commit.v1", Context.MODE_PRIVATE)
        title = prefs.getString(key("title"), "") ?: ""
        details = prefs.getString(key("details"), "") ?: ""
        selection = prefs.getStringSet(key("paths"), emptySet()) ?: emptySet()
        operationId = prefs.getString(key("operationId"), null)
    }

    private fun key(field: String): String = "$peer|$workspace|$field"
}

private fun JsonObject.paths(): Set<String> =
    (get("paths") as? kotlinx.serialization.json.JsonArray)
        ?.mapNotNull { it.jsonPrimitive.contentOrNull }
        ?.toSet() ?: emptySet()
