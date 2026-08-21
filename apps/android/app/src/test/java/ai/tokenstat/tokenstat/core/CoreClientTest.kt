// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class CoreClientTest {
    @Test fun decodesSuccessfulEnvelope() {
        val result = CoreClient.decodeResponse(
            """{"ok":true,"result":{"signedIn":true,"futureField":42}}"""
        )
        assertEquals("true", result.jsonObject["signedIn"]?.jsonPrimitive?.content)
    }

    @Test fun preservesCoreFailureCode() {
        val error = runCatching {
            CoreClient.decodeResponse(
                """{"ok":false,"error":{"code":"offline","message":"This device is offline."}}"""
            )
        }.exceptionOrNull() as CoreFailure
        assertEquals("offline", error.code)
        assertEquals("This device is offline.", error.message)
    }
}
