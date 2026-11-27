// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n


object FileSelection {
    fun label(selected: Int, total: Int): String = L10n.text("android.workspacelogic.0_of_1_selected.d06c59a5", "${selected}", "${total}")

    fun toggle(current: Set<String>, path: String): Set<String> =
        if (current.contains(path)) current - path else current + path

    fun selectAllOrNone(current: Set<String>, all: Set<String>): Set<String> =
        if (current == all) emptySet() else all

    fun reconcile(selected: Set<String>, available: Set<String>): Set<String> =
        selected.intersect(available)
}

object CommitDraft {
    fun message(title: String, details: String): String {
        val cleanTitle = title.trim()
        val cleanDetails = details.trim()
        return if (cleanDetails.isEmpty()) cleanTitle else "$cleanTitle\n\n$cleanDetails"
    }

    const val MAX_MESSAGE_BYTES = 128 * 1024

    fun canCommit(title: String, reviewedPaths: Set<String>?, selectedPaths: Set<String>): Boolean {
        if (title.trim().isEmpty()) return false
        if (message(title, "").toByteArray().size > MAX_MESSAGE_BYTES) return false
        if (reviewedPaths == null || reviewedPaths != selectedPaths) return false
        return true
    }

    fun messageTooLong(title: String, details: String): Boolean =
        message(title, details).toByteArray().size > MAX_MESSAGE_BYTES
}

object ReviewClip {
    const val MAX_FILES = 20
    const val LINES_PER_FILE = 60

    data class Clip(val shown: Int, val cut: Int)

    fun clip(totalLines: Int, limit: Int = LINES_PER_FILE): Clip =
        if (totalLines <= limit) Clip(totalLines, 0) else Clip(limit, totalLines - limit)

    fun leftoverLine(total: Int, shown: Int): String =
        L10n.text("android.workspacelogic.showing_0_of_1_lines_here.f2764462", "${shown}", "${total}")

    fun failureLine(failures: Int): String =
        L10n.text("android.workspacelogic.0_file_1_did_not_load_open_2_individually.2acd4427", "${failures}", "${if (failures == 1) "" else "s"}", "${if (failures == 1) "it" else "them"}")

    fun leftoverFilesLine(leftover: Int): String =
        L10n.text("android.workspacelogic.0_more_file_1_changed_open_2_from_changes.206bca3b", "${leftover}", "${if (leftover == 1) "" else "s"}", "${if (leftover == 1) "it" else "them"}")
}

object PushLabel {
    fun label(submitted: Boolean, outgoing: Long): String = when {
        submitted -> L10n.text("android.workspacelogic.check_push.c821c305")
        outgoing > 0 -> L10n.text("android.workspacelogic.push_0.a738ad29", "${outgoing}")
        else -> L10n.text("android.workspacelogic.push.92363252")
    }
}

object OperationState {
    fun succeeded(state: String): Boolean = state == "succeeded"
    fun unresolved(state: String): Boolean = state != "succeeded" && state != "failed"
}

object ChangeKinds {
    fun label(kind: String): String = when (kind.lowercase()) {
        "added" -> L10n.text("android.workspacelogic.added.6b02e0d3")
        "modified" -> L10n.text("android.workspacelogic.modified.e8ce5dca")
        "deleted" -> L10n.text("android.workspacelogic.deleted.b48ff39c")
        "renamed" -> L10n.text("android.workspacelogic.renamed.05487af3")
        "untracked" -> L10n.text("android.workspacelogic.untracked.c7ba5477")
        "conflicted" -> L10n.text("android.workspacelogic.conflicted.916a464e")
        else -> kind.replaceFirstChar { it.uppercase() }
    }
}

object FileIcons {
    fun keyFor(name: String, isDir: Boolean): String {
        if (isDir) return "dir"
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "kt", "kts", "java", "swift", "rs", "go", "py", "js", "ts", "tsx",
            "c", "h", "cpp", "cs", "rb", "php", "sh", "sql", "html", "css",
            "xml", "json", "yml", "yaml", "toml", "gradle", "md", "swiftpm" -> "code"
            "txt", "log" -> "text"
            "png", "jpg", "jpeg", "gif", "webp", "svg", "heic" -> "image"
            "mp3", "wav", "m4a", "ogg", "flac" -> "audio"
            "mp4", "mov", "m4v", "webm" -> "video"
            "pdf" -> "pdf"
            "zip", "tar", "gz", "dmg", "apk", "ipa" -> "archive"
            else -> "file"
        }
    }
}

object NoteList {
    const val ARCHIVE_COLUMN = "archive"

    data class NoteCard(
        val id: String,
        val title: String,
        val body: String,
        val column: String,
        val createdAtMs: Long,
        val revision: Long? = null,
    )

    fun visible(
        cards: List<NoteCard>,
        showingArchive: Boolean,
        search: String,
        alphabetical: Boolean,
    ): List<NoteCard> {
        val query = search.trim()
        return cards
            .filter { (it.column == ARCHIVE_COLUMN) == showingArchive }
            .filter {
                query.isEmpty() ||
                    it.title.contains(query, ignoreCase = true) ||
                    it.body.contains(query, ignoreCase = true)
            }
            .sortedWith(
                if (alphabetical) compareBy { it.title.lowercase() }
                else compareByDescending { it.createdAtMs },
            )
    }

    fun archivedCount(cards: List<NoteCard>): Int =
        cards.count { it.column == ARCHIVE_COLUMN }
}

object UntouchedChats {
    const val DEFAULT_TITLE = "New chat"

    fun isUntouched(
        title: String?,
        lastMessageAtMs: Long?,
        running: Boolean,
        id: String?,
        openId: String? = null,
        hasWriting: Boolean = false,
        hasPending: Boolean = false,
    ): Boolean =
        title == DEFAULT_TITLE && lastMessageAtMs == null && !running && !hasWriting && !hasPending && (openId == null || id != openId)
}
