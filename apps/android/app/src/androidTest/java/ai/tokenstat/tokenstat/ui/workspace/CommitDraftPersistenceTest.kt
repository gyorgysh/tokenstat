// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class CommitDraftPersistenceTest {
    @Test fun interruptedSubmissionRestoresTheExactFrozenReview() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val testName = "commit-review-test-" + UUID.randomUUID()
        val context = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                base.getSharedPreferences(testName, Context.MODE_PRIVATE)
        }
        try {
            val original = CommitUiState("test-peer", "test-workspace")
            original.title = "Reviewed change"
            original.details = "Keep this exact submission"
            original.selection = setOf("file.txt")
            original.operationId = "test-operation"
            original.review = Json.parseToJsonElement(
                """{"branch":"main","head":"before","tree":"reviewed","paths":["file.txt"]}"""
            ).jsonObject
            original.save(context)
            val restored = CommitUiState("test-peer", "test-workspace")
            restored.restore(context)
            assertEquals(original.operationId, restored.operationId)
            assertEquals(original.review, restored.review)
            assertEquals(original.message, restored.message)
            assertEquals(original.selection, restored.selection)
        } finally {
            base.deleteSharedPreferences(testName)
        }
    }
}
