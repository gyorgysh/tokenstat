// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.ChangeKinds
import ai.tokenstat.tokenstat.ui.logic.CommitDraft
import ai.tokenstat.tokenstat.ui.logic.FileIcons
import ai.tokenstat.tokenstat.ui.logic.FileSelection
import ai.tokenstat.tokenstat.ui.logic.NoteList
import ai.tokenstat.tokenstat.ui.logic.OperationState
import ai.tokenstat.tokenstat.ui.logic.PushLabel
import ai.tokenstat.tokenstat.ui.logic.ReviewClip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the workspace pure logic to the Apple originals in
/// `ClientWorkspaceSections.swift`, `GitCommitSession.swift`,
/// `ClientReviewAllView.swift`, `GitPushView.swift`, and
/// `ClientWorkspaceNotesView.swift`.
class WorkspaceLogicTest {

    @Test
    fun selectionLabelCountsSelectedOfTotal() {
        assertEquals("2 of 5 selected", FileSelection.label(2, 5))
        assertEquals("0 of 0 selected", FileSelection.label(0, 0))
    }

    @Test
    fun selectionToggleAddsAndRemoves() {
        assertEquals(setOf("a"), FileSelection.toggle(emptySet(), "a"))
        assertEquals(emptySet<String>(), FileSelection.toggle(setOf("a"), "a"))
    }

    @Test
    fun selectAllClearsWhenEverythingSelected() {
        val all = setOf("a", "b")
        assertEquals(emptySet<String>(), FileSelection.selectAllOrNone(all, all))
        assertEquals(all, FileSelection.selectAllOrNone(setOf("a"), all))
    }

    @Test
    fun reconcileDropsPathsThatNoLongerChanged() {
        assertEquals(
            setOf("a"),
            FileSelection.reconcile(setOf("a", "gone"), setOf("a", "b")),
        )
    }

    @Test
    fun commitMessageJoinsTitleAndDetails() {
        assertEquals("Fix it", CommitDraft.message("Fix it", ""))
        assertEquals("Fix it\n\nWhy", CommitDraft.message("  Fix it  ", "  Why  "))
    }

    @Test
    fun commitGateNeedsTitleAndFrozenReview() {
        assertTrue(CommitDraft.canCommit("Fix it", setOf("a"), setOf("a")))
        assertFalse(CommitDraft.canCommit("  ", setOf("a"), setOf("a")))
        assertFalse(CommitDraft.canCommit("Fix it", null, setOf("a")))
        assertFalse(CommitDraft.canCommit("Fix it", setOf("a"), setOf("a", "b")))
    }

    @Test
    fun reviewClipCapsFilesAndLines() {
        assertEquals(ReviewClip.Clip(10, 0), ReviewClip.clip(10))
        assertEquals(ReviewClip.Clip(60, 5), ReviewClip.clip(65))
        assertEquals(20, ReviewClip.MAX_FILES)
        assertEquals(60, ReviewClip.LINES_PER_FILE)
    }

    @Test
    fun reviewCopyMatchesAppleWordForWord() {
        assertEquals(
            "2 files did not load. Open them individually for the diff.",
            ReviewClip.failureLine(2),
        )
        assertEquals(
            "1 file did not load. Open it individually for the diff.",
            ReviewClip.failureLine(1),
        )
        assertEquals(
            "3 more files changed. Open them from Changes for the diff.",
            ReviewClip.leftoverFilesLine(3),
        )
    }

    @Test
    fun pushLabelNamesSubmittedAndOutgoing() {
        assertEquals("Check push", PushLabel.label(true, 3))
        assertEquals("Push 3", PushLabel.label(false, 3))
        assertEquals("Push…", PushLabel.label(false, 0))
    }

    @Test
    fun operationStatesResolveLikeApple() {
        assertTrue(OperationState.succeeded("succeeded"))
        assertFalse(OperationState.succeeded("started"))
        assertTrue(OperationState.unresolved("started"))
        assertTrue(OperationState.unresolved("prepared"))
        assertFalse(OperationState.unresolved("succeeded"))
        assertFalse(OperationState.unresolved("failed"))
    }

    @Test
    fun changeKindLabelsMatchApple() {
        assertEquals("Added", ChangeKinds.label("added"))
        assertEquals("Modified", ChangeKinds.label("modified"))
        assertEquals("Deleted", ChangeKinds.label("deleted"))
        assertEquals("Renamed", ChangeKinds.label("renamed"))
        assertEquals("Untracked", ChangeKinds.label("untracked"))
        assertEquals("Conflicted", ChangeKinds.label("conflicted"))
    }

    @Test
    fun fileIconsClassifyByType() {
        assertEquals("dir", FileIcons.keyFor("src", true))
        assertEquals("code", FileIcons.keyFor("Main.kt", false))
        assertEquals("code", FileIcons.keyFor("README.md", false))
        assertEquals("image", FileIcons.keyFor("shot.PNG", false))
        assertEquals("audio", FileIcons.keyFor("take.mp3", false))
        assertEquals("video", FileIcons.keyFor("clip.mov", false))
        assertEquals("pdf", FileIcons.keyFor("doc.pdf", false))
        assertEquals("archive", FileIcons.keyFor("app.zip", false))
        assertEquals("file", FileIcons.keyFor("LICENSE", false))
    }

    private fun note(id: String, title: String, column: String, at: Long) =
        NoteList.NoteCard(id, title, "", column, at)

    @Test
    fun notesSortNewestFirstByDefault() {
        val cards = listOf(note("1", "Old", "backlog", 1), note("2", "New", "backlog", 2))
        val shown = NoteList.visible(cards, false, "", false)
        assertEquals(listOf("2", "1"), shown.map { it.id })
    }

    @Test
    fun notesSortAlphabeticallyOnRequest() {
        val cards = listOf(note("1", "beta", "backlog", 2), note("2", "Alpha", "backlog", 1))
        val shown = NoteList.visible(cards, false, "", true)
        assertEquals(listOf("2", "1"), shown.map { it.id })
    }

    @Test
    fun notesPartitionArchiveAndSearch() {
        val cards = listOf(
            note("1", "Keep", "backlog", 1),
            note("2", "Away", NoteList.ARCHIVE_COLUMN, 2),
            note("3", "Shopping", "backlog", 3),
        )
        assertEquals(1, NoteList.archivedCount(cards))
        assertEquals(listOf("3", "1"), NoteList.visible(cards, false, "", false).map { it.id })
        assertEquals(listOf("2"), NoteList.visible(cards, true, "", false).map { it.id })
        assertEquals(listOf("3"), NoteList.visible(cards, false, "shop", false).map { it.id })
    }
}
