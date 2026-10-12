// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class AutoCommitRunTest {
    @Test fun confirmationReadsTheNestedRunAndChecksItsIdentity() {
        val answer = Json.parseToJsonElement(
            """{"operationId":"op","jobId":"job","runId":"run","run":{"id":"run","jobId":"job","status":"running"}}"""
        ).jsonObject
        assertTrue(confirmedAutoCommitRun(answer, "op", "job")!!.isRunning)
        assertNull(confirmedAutoCommitRun(answer, "other", "job"))
        assertNull(confirmedAutoCommitRun(answer, "op", "other"))
        assertNull(confirmedAutoCommitRun(Json.parseToJsonElement(
            """{"operationId":"op","jobId":"job","runId":"run","run":null}"""
        ).jsonObject, "op", "job"))
    }
}
