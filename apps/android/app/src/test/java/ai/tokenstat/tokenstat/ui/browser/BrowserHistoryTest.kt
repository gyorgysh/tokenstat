// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class BrowserHistoryTest {
    @Test
    fun `recent ports are unique newest first and bounded`() {
        var history = BrowserHistory.State()
        for (port in 3000..3010) history = BrowserHistory.record(history, BrowserTarget.port(port)!!)
        assertEquals((3010 downTo 3003).toList(), history.recentPorts)
        history = BrowserHistory.record(history, BrowserTarget.port(3005)!!)
        assertEquals(listOf(3005, 3010, 3009, 3008, 3007, 3006, 3004, 3003), history.recentPorts)
        assertEquals("http://127.0.0.1:3005/", history.lastTarget)
    }

    @Test
    fun `legacy port is a field fallback without becoming project history`() {
        val empty = BrowserHistory.State()
        assertEquals(5173, BrowserHistory.initial(empty, 5173).port)
        assertEquals(emptyList<Int>(), empty.recentPorts)
        assertNull(empty.lastTarget)
        assertEquals(3000, BrowserHistory.initial(empty, 0).port)
        val stored = BrowserHistory.record(empty, BrowserTarget.port(8080)!!)
        assertEquals(8080, BrowserHistory.initial(stored, 5173).port)
    }

    @Test
    fun `invalid stored targets and ports cannot become navigation suggestions`() {
        val cleaned = BrowserHistory.clean(BrowserHistory.State("file:///secret", listOf(0, 65536, 5173, 5173, -1, 8080)))
        assertNull(cleaned.lastTarget)
        assertEquals(listOf(5173, 8080), cleaned.recentPorts)
        for (url in listOf("http://example.test:3000/", "http://user@localhost:3000/", "http://localhost:0/", "http://localhost:65536/", "javascript:alert(1)")) {
            assertNull(BrowserTarget.parse(url))
            assertFalse(BrowserPolicy.allows(url))
        }
    }

    @Test
    fun `proxy navigation retains the original host port path query and fragment`() {
        val target = BrowserTarget.parse("HTTP://LOCALHOST:5173/a%20b?q=hello%20world#part")!!
        val bridge = BrowserBridge(target, "http://127.0.0.1:49152/")
        assertEquals("http://localhost:5173/a%20b?q=hello%20world#part", target.url)
        assertEquals("http://127.0.0.1:49152/a%20b?q=hello%20world#part", target.through(bridge.listenerUrl))
        val redirected = bridge.original("http://127.0.0.1:49152/next?mode=edit#tab")!!
        val stored = BrowserHistory.record(BrowserHistory.State(), redirected)
        assertEquals("http://localhost:5173/next?mode=edit#tab", stored.lastTarget)
        assertEquals(listOf(5173), stored.recentPorts)
        assertEquals(redirected, BrowserHistory.forPort(stored, 5173))
        assertEquals("http://127.0.0.1:8080/", BrowserHistory.forPort(stored, 8080)?.url)
        assertNull(bridge.original("http://127.0.0.1:49153/next"))
        assertNull(target.through("http://example.test:49152/"))
    }

    @Test
    fun `secure and implicit ports stay canonical when a new listener is acquired`() {
        val target = BrowserTarget.parse("https://localhost/status")!!
        assertEquals("https://localhost:443/status", target.url)
        assertEquals("https://127.0.0.1:49999/status", target.through("http://127.0.0.1:49999/"))
        val restored = BrowserHistory.initial(BrowserHistory.record(BrowserHistory.State(), target), null)
        assertEquals("https://127.0.0.1:50000/status", restored.through("http://127.0.0.1:50000/"))
    }
}
