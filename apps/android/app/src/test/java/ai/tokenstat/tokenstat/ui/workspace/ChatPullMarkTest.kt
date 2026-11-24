// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatPullMarkTest {
    private fun json(value: String) = Json.parseToJsonElement(value).jsonObject

    @Test fun severalWinOverTheBranchAndAnOldHostStillShowsOne() {
        val pull = """{"number":1,"state":"open","url":"https://github.com/o/r/pull/1"}"""
        assertEquals(1, chatPulls(json("""{"pull":$pull}""")).size)
        assertEquals(2, chatPulls(json("""{"pull":$pull,"pulls":[$pull,{"number":2,"state":"merged"}]}""")).size)
        assertEquals(0, chatPulls(json("{}")).size)
    }

    @Test fun openWorkLeadsThenMerged() {
        val rows = chatPulls(json("""{"pulls":[{"number":1,"state":"closed"},{"number":2,"state":"merged"},{"number":3,"state":"open","draft":true},{"number":4,"state":"open"}]}"""))
        assertEquals("4", leadPull(rows)?.str("number"))
        assertEquals("3", leadPull(rows.dropLast(1))?.str("number"))
        assertEquals("2", leadPull(rows.take(2))?.str("number"))
        assertEquals("1", leadPull(rows.take(1))?.str("number"))
    }

    @Test fun theNameComesFromTheAddressWhenTheHostDidNotSay() {
        assertEquals("o/r #7", pullName(json("""{"number":7,"url":"https://github.com/o/r/pull/7"}""")))
        assertEquals("x/y #7", pullName(json("""{"number":7,"repo":"x/y"}""")))
        assertEquals("#7", pullName(json("""{"number":7}""")))
    }

    @Test fun anUnknownChoiceAsksAgain() {
        assertEquals(PullOpenChoice.Ask, PullOpenChoice.of(null))
        assertEquals(PullOpenChoice.Ask, PullOpenChoice.of("window"))
        assertEquals(PullOpenChoice.Here, PullOpenChoice.of("here"))
    }
}
