// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HostContractsTest {
    @Test
    fun `daemon protocol response accepts quoted and numeric versions`() {
        for (response in listOf(
            """{"protocolVersion":"30","coreVersion":"1.2.0"}""",
            """{"protocolVersion":30}""",
            """{"protocol":"30"}""",
            """{"protocol":30}""",
        )) {
            assertEquals(30L, HostContracts.protocolOf(Json.parseToJsonElement(response).jsonObject))
        }
    }

    @Test
    fun `machine records and malformed protocol fields do not claim capabilities`() {
        assertNull(HostContracts.protocolOf(null))
        for (response in listOf(
            """{"id":"computer-1","label":"Computer","kind":"host"}""",
            """{"protocolVersion":null}""",
            """{"protocolVersion":{}}""",
            """{"protocolVersion":[]}""",
            """{"protocolVersion":true}""",
            """{"protocolVersion":"unknown"}""",
            """{"protocolVersion":30.5}""",
            """{"protocolVersion":0}""",
            """{"protocolVersion":-30}""",
        )) {
            assertNull(response, HostContracts.protocolOf(Json.parseToJsonElement(response).jsonObject))
        }
    }

    @Test
    fun `invalid legacy alias falls back to daemon version`() {
        for (alias in listOf("null", "{}", "[]", "0", "-1", "\"unknown\"")) {
            val response = Json.parseToJsonElement("""{"protocol":$alias,"protocolVersion":"30"}""").jsonObject
            assertEquals(30L, HostContracts.protocolOf(response))
        }
    }
}
