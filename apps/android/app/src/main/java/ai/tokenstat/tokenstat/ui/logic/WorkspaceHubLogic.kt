// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/// Pure rules for the workspace hub: the folder's section menu, the launcher,
/// the file editor's find and conflict math, and pull review verbs.
///
/// Ports the UI-thread-free cores of `ClientWorkspaceDetailView` (section
/// order and `workspace.summary` badge math), `ClientChatView` (composer
/// hint), `ClientWorkspaceSessionsView` (catalog partitioning), the phone
/// `ClientFileEditor` (save gating and conflict summary), `EditorFindBar`
/// (match counting), and `PullDetailView` (review and merge verbs), so both
/// platforms answer identically. No Android or coroutine APIs here.

/// One folder section, in the Mac sidebar order iOS lists them in. The key is
/// the Android section name the content renderer already knows; the label is
/// the iOS row word.
enum class HubSection(val key: String, val label: String) {
    SESSIONS("Sessions", "Sessions"),
    CHAT("Chat", "Chat"),
    CHANGES("Changes", "Changes"),
    HISTORY("History", "History"),
    PULLS("Pulls", "Pull requests"),
    TASKS("Tasks", "Tasks"),
    NOTES("Notes", "Notes"),
    WORKFLOWS("Workflows", "Workflows"),
    AUTOMATIONS("Automations", "Automations"),
    FILES("Files", "Files"),
    BROWSER("Browser", "Browser"),
}

/// What the hub badges say. One value each, filled by one pass over
/// `workspace.summary`, mirroring `WorkspaceSectionCounts`.
data class HubCounts(
    val sessions: Int = 0,
    val chats: Int = 0,
    val changes: Int = 0,
    val pulls: Int = 0,
    val todo: Int = 0,
    val notes: Int = 0,
    val automations: Int = 0,
    val workflows: Int = 0,
) {
    fun forSection(section: HubSection): Int? = when (section) {
        HubSection.SESSIONS -> sessions
        HubSection.CHAT -> chats
        HubSection.CHANGES -> changes
        HubSection.HISTORY -> null
        HubSection.PULLS -> pulls
        HubSection.TASKS -> todo
        HubSection.NOTES -> notes
        HubSection.WORKFLOWS -> workflows
        HubSection.AUTOMATIONS -> automations
        HubSection.FILES -> null
        HubSection.BROWSER -> null
    }
}

object HubCountsParser {
    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull
            ?: (this[key] as? JsonPrimitive)?.longOrNull?.toInt()

    /// Mirrors the iOS `reload()`: optional host fields fall back to what the
    /// phone already knows (the git file count for changes, the cached pull
    /// count), never to a zero that would read as news.
    fun parse(summary: JsonObject, gitChangedFallback: Int?, cachedPulls: Int?): HubCounts {
        val running = summary.int("workflowsRunning") ?: 0
        val workflows = summary.int("workflows") ?: 0
        return HubCounts(
            sessions = summary.int("sessions") ?: 0,
            chats = summary.int("chats") ?: 0,
            changes = summary.int("changed") ?: gitChangedFallback ?: 0,
            pulls = summary.int("pulls") ?: cachedPulls ?: 0,
            todo = summary.int("tasks") ?: 0,
            notes = summary.int("notes") ?: 0,
            automations = summary.int("automations") ?: 0,
            workflows = if (running > 0) running else workflows,
        )
    }

    fun findSummary(summaries: List<JsonObject>, workspaceId: String): JsonObject? =
        summaries.firstOrNull { (it["id"] as? JsonPrimitive)?.contentOrNull == workspaceId }
}

/// The chat composer hint. A busy composer says what happens next; otherwise
/// the folder is named, quoted, so the question reads as about that place.
object ChatHint {
    fun hint(folderName: String, busy: Boolean): String {
        if (busy) return "Send after this turn"
        val name = folderName.trim()
        return if (name.isEmpty()) "Ask about this folder" else "Ask about '$name'"
    }
}

/// One launcher profile from `launcher.catalog`, mirroring
/// `RemoteLaunchProfile`'s phone-read fields.
data class LaunchProfile(
    val id: String,
    val name: String,
    val command: String,
    val args: List<String>,
    val bypassArgs: List<String>,
    val harnessId: String?,
    val installed: Boolean,
    val hostHidden: Boolean,
    val installCommand: String?,
) {
    fun launchArgs(bypassOn: Boolean): List<String> =
        if (bypassOn) args + bypassArgs else args
}

object LaunchCatalog {
    fun parse(obj: JsonObject): LaunchProfile? {
        val id = (obj["id"] as? JsonPrimitive)?.contentOrNull ?: return null
        val name = (obj["name"] as? JsonPrimitive)?.contentOrNull ?: id
        val command = (obj["command"] as? JsonPrimitive)?.contentOrNull ?: return null
        fun strings(key: String): List<String> =
            (obj[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()
        return LaunchProfile(
            id = id,
            name = name,
            command = command,
            args = strings("args"),
            bypassArgs = strings("bypassArgs"),
            harnessId = (obj["harnessId"] as? JsonPrimitive)?.contentOrNull,
            installed = (obj["installed"] as? JsonPrimitive)?.contentOrNull == "true",
            hostHidden = (obj["hidden"] as? JsonPrimitive)?.contentOrNull == "true",
            installCommand = (obj["installCommand"] as? JsonPrimitive)?.contentOrNull,
        )
    }

    /// The built-in shell tile, for a host that answered with no catalog.
    fun shellFallback(): LaunchProfile = LaunchProfile(
        id = "shell",
        name = "Shell",
        command = "/bin/zsh",
        args = listOf("-l"),
        bypassArgs = emptyList(),
        harnessId = null,
        installed = true,
        hostHidden = false,
        installCommand = null,
    )

    fun isOffGrid(profile: LaunchProfile, locallyHidden: Set<String>): Boolean =
        profile.hostHidden || locallyHidden.contains(profile.id)

    fun visible(catalog: List<LaunchProfile>, locallyHidden: Set<String>): List<LaunchProfile> =
        catalog.filter { it.installed && !isOffGrid(it, locallyHidden) }

    fun extra(catalog: List<LaunchProfile>, locallyHidden: Set<String>): List<LaunchProfile> =
        catalog.filter { !it.installed || isOffGrid(it, locallyHidden) }
}

/// Editor save gating, mirroring the phone `ClientFileEditor.save()`: the
/// host is re-read first, and a host text that differs from both the draft
/// and the last save is a conflict, never an overwrite.
object EditorSave {
    enum class Outcome { SAVE, CONFLICT, ALREADY_SAVED }

    fun decide(host: String, draft: String, savedText: String): Outcome = when {
        host != draft && host != savedText -> Outcome.CONFLICT
        host == draft -> Outcome.ALREADY_SAVED
        else -> Outcome.SAVE
    }
}

/// Conflict card math from `EditorConflictCard`: line counts for both sides
/// and the first line that differs.
object EditorConflict {
    fun lineCount(text: String): Int = text.split('\n').size

    fun firstDifferenceLine(mine: String, host: String): Int? {
        val a = mine.split('\n')
        val b = host.split('\n')
        val common = minOf(a.size, b.size)
        for (i in 0 until common) {
            if (a[i] != b[i]) return i + 1
        }
        return if (a.size != b.size) common + 1 else null
    }

    fun summary(mine: String, host: String): String {
        var parts = "Yours has ${lineCount(mine)} lines, that computer has ${lineCount(host)}. " +
            "Saving is off until you choose."
        val first = firstDifferenceLine(mine, host)
        if (first != null) parts += " First difference: line $first."
        return parts
    }
}

/// Find and replace over the editor buffer, mirroring `EditorFindSession`'s
/// counting and navigation.
object EditorFind {
    fun matches(text: String, query: String): List<IntRange> {
        if (query.isEmpty() || text.isEmpty()) return emptyList()
        val out = mutableListOf<IntRange>()
        var from = 0
        while (true) {
            val at = text.indexOf(query, from, ignoreCase = true)
            if (at < 0) break
            out.add(at until at + query.length)
            from = at + query.length
        }
        return out
    }

    fun countLabel(index: Int, total: Int): String? {
        if (total == 0) return null
        return "${(index.coerceIn(0, total - 1)) + 1} of $total"
    }

    fun nextIndex(current: Int, total: Int): Int {
        if (total == 0) return 0
        return (current + 1) % total
    }

    fun prevIndex(current: Int, total: Int): Int {
        if (total == 0) return 0
        return (current - 1 + total) % total
    }

    data class Replacement(val text: String, val count: Int)

    fun replaceFirst(text: String, query: String, replacement: String): Replacement {
        if (query.isEmpty()) return Replacement(text, 0)
        val at = text.indexOf(query, ignoreCase = true)
        if (at < 0) return Replacement(text, 0)
        return Replacement(
            text.substring(0, at) + replacement + text.substring(at + query.length),
            1,
        )
    }

    fun replaceAll(text: String, query: String, replacement: String): Replacement {
        if (query.isEmpty()) return Replacement(text, 0)
        var count = 0
        var from = 0
        val out = StringBuilder()
        while (true) {
            val at = text.indexOf(query, from, ignoreCase = true)
            if (at < 0) {
                out.append(text.substring(from))
                break
            }
            out.append(text.substring(from, at))
            out.append(replacement)
            from = at + query.length
            count += 1
        }
        return Replacement(out.toString(), count)
    }
}

/// Pull review verbs and merge methods, word-for-word with
/// `PullReviewVerdict` and `PullMergeMethod` raw values.
object PullReview {
    val VERDICTS = listOf("approve", "requestChanges", "comment")

    fun verdictLabel(verdict: String): String = when (verdict) {
        "approve" -> "Approve"
        "requestChanges" -> "Request changes"
        "comment" -> "Comment review"
        else -> verdict
    }

    fun reviewPlaceholder(verdict: String): String = when (verdict) {
        "requestChanges" -> "Explain what needs to change…"
        else -> "Add a review note…"
    }

    val MERGE_METHODS = listOf("merge", "squash", "rebase")

    fun mergeTitle(method: String): String =
        method.replaceFirstChar { it.uppercase() }
}
