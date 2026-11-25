// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class TrustedServersTest {
    @Test fun readsTheHostsAnswerAndSkipsWhatItCannotName() {
        val rows = trustedServers(
            Json.parseToJsonElement(
                """[{"hostId":"a","label":"","hostname":"example.test","port":2222,"fingerprints":["SHA256:x"]},
                    {"label":"no id"}, 3]""",
            ),
        )
        assertEquals(listOf(TrustedServer("a", "example.test", "example.test:2222", listOf("SHA256:x"))), rows)
        assertEquals(emptyList<TrustedServer>(), trustedServers(null))
    }
}
