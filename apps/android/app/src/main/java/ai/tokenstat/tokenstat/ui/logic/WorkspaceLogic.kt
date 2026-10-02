// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

/// Pure workspace rules shared by the files, changes, and notes sections.
/// Ports the UI-thread-free cores of `ClientWorkspaceSections.swift`
/// (selection counting), `GitCommitSession.swift` (draft message, commit
/// gating), `ClientReviewAllView.swift` (review caps), and
/// `ClientWorkspaceNotesView.swift` (note sorting and filtering), so both
/// platforms answer identically. No Android or coroutine APIs here.

/// File selection counting, mirroring the Changes footer
/// ("N of M selected") and the Select all toggle.
object FileSelection {
    fun label(selected: Int, total: Int): String = L10n.text("android.workspacelogic.0_of_1_selected.d06c59a5", "${selected}", "${total}")

    fun toggle(current: Set<String>, path: String): Set<String> =
        if (current.contains(path)) current - path else current + path

    /// Apple `selectAll`: tapping with everything selected clears,
    /// otherwise selects the whole list.
    fun selectAllOrNone(current: Set<String>, all: Set<String>): Set<String> =
        if (current == all) emptySet() else all

    /// Apple `reconcileAvailablePaths`: a fresh status drops selected paths
    /// that no longer changed. Only applies before a review exists and while
    /// nothing is submitted.
    fun reconcile(selected: Set<String>, available: Set<String>): Set<String> =
        selected.intersect(available)
}

/// The commit draft message, mirroring `GitCommitDraft.message`: the title
/// alone, or title, blank line, details.
object CommitDraft {
    fun message(title: String, details: String): String {
        val cleanTitle = title.trim()
        val cleanDetails = details.trim()
        return if (cleanDetails.isEmpty()) cleanTitle else "$cleanTitle\n\n$cleanDetails"
    }

    const val MAX_MESSAGE_BYTES = 128 * 1024

    /// Mirrors `GitCommitSession.canCommit`: a non-blank title, a message
    /// within the host limit, and a review frozen on exactly this selection.
    fun canCommit(title: String, reviewedPaths: Set<String>?, selectedPaths: Set<String>): Boolean {
        if (title.trim().isEmpty()) return false
        if (message(title, "").toByteArray().size > MAX_MESSAGE_BYTES) return false
        if (reviewedPaths == null || reviewedPaths != selectedPaths) return false
        return true
    }

    fun messageTooLong(title: String, details: String): Boolean =
        message(title, details).toByteArray().size > MAX_MESSAGE_BYTES
}

/// Review caps from `ClientReviewAllView`: at most twenty files, sixty
/// lines each, with the cut count said out loud.
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

/// Push button words from `GitPushControl`: a submitted push is checked,
/// otherwise the outgoing count decides.
object PushLabel {
    fun label(submitted: Boolean, outgoing: Long): String = when {
        submitted -> L10n.text("android.workspacelogic.check_push.c821c305")
        outgoing > 0 -> L10n.text("android.workspacelogic.push_0.a738ad29", "${outgoing}")
        else -> L10n.text("android.workspacelogic.push.92363252")
    }
}

/// Commit and push receipt states. The host reports "succeeded", "failed",
/// or an in-between state; anything in between is unresolved and must be
/// reconciled before another operation starts.
object OperationState {
    fun succeeded(state: String): Boolean = state == "succeeded"
    fun unresolved(state: String): Boolean = state != "succeeded" && state != "failed"
}

/// Change kinds, mirroring `ChangeKind.label` word-for-word. The host sends
/// lowercase single words.
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

/// Per-type file icon keys for the tree. Apple draws folders and documents;
/// the phone tree names the kind so text, image, audio, video, PDF, and
/// archive files are recognizable at a glance.
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

/// Notes list rules from `ClientWorkspaceNotesView`: newest first unless
/// alphabetical, archive partitioned behind a toggle, search across title
/// and body. The host column for put-away notes is "archive".
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

/// A chat that was opened and never used: the host's default title, no
/// message either way and nothing running. Lists leave these out so rows of
/// "New chat" do not bury real conversations, except the one that is open.
/// The title test keeps chats from a host too old to send `lastMessageAtMs`,
/// because every host renames a chat from its first prompt. Port of the
/// Mac's `ChatModel.isUntouched`.
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
