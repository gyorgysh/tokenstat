// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Hold setup replies while the production page owner is replaced or released. */
@RunWith(AndroidJUnit4::class)
class TerminalSetupOwnershipTest {
    private fun pages(check: suspend (TerminalBridge, WebView, WebView) -> Unit) {
        val instrument = InstrumentationRegistry.getInstrumentation()
        lateinit var first: WebView
        lateinit var second: WebView
        val bridge = TerminalBridge()
        instrument.runOnMainSync {
            first = WebView(instrument.targetContext)
            second = WebView(instrument.targetContext)
            bridge.webView = first
        }
        try { runBlocking { withTimeout(10_000) { check(bridge, first, second) } } }
        finally {
            instrument.runOnMainSync { bridge.webView = null; bridge.stopJobs(); first.destroy(); second.destroy() }
        }
    }

    @Test fun pendingRepliesCannotPublishToAReplacedOrReloadedPage() = pages { bridge, first, second ->
        for (replace in listOf(false, true)) for (fail in listOf(false, true)) {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { bridge.webView = first }
            val owner = bridge.pageOwner()!!
            val reply = CompletableDeferred<Unit>()
            var published = 0
            coroutineScope {
                val job = launch(start = CoroutineStart.UNDISPATCHED) {
                    bridge.runForPage(owner, request = {
                        reply.await()
                        if (fail) throw java.io.IOException("Connection lost")
                        "session"
                    }) { published++ }
                }
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    if (replace) bridge.webView = second else bridge.stopJobs()
                }
                reply.complete(Unit)
                job.join()
            }
            assertEquals("A retired reply cannot start pumps or show an error", 0, published)
        }
        for (fail in listOf(false, true)) {
            var response: Result<String>? = null
            bridge.runForPage(bridge.pageOwner()!!, request = {
                if (fail) throw java.io.IOException("Connection lost")
                "current session"
            }) { response = it }
            assertEquals(!fail, response!!.isSuccess)
        }
    }

    @Test fun setupThatStartsAfterReleaseDoesNotMakeARequest() = pages { bridge, _, _ ->
        val owner = bridge.pageOwner()!!
        InstrumentationRegistry.getInstrumentation().runOnMainSync { bridge.stopJobs(); bridge.webView = null }
        var requests = 0
        var completed = 0
        bridge.runForPage(owner, request = { requests++ }) { completed++ }
        assertEquals(0, requests)
        assertEquals(0, completed)
    }

    @Test fun cancellationIsNotPublishedAsASetupError() = pages { bridge, _, _ ->
        var completed = 0
        coroutineScope {
            val job = launch {
                bridge.runForPage(bridge.pageOwner()!!, request = { throw CancellationException("Leaving") }) { completed++ }
            }
            job.join()
            assertTrue(job.isCancelled)
        }
        assertEquals(0, completed)
    }

    @Test fun aRequestThatIgnoresCancellationStillCannotPublish() = pages { bridge, _, _ ->
        val reply = CompletableDeferred<Unit>()
        var completed = 0
        coroutineScope {
            val job = launch(start = CoroutineStart.UNDISPATCHED) {
                bridge.runForPage(bridge.pageOwner()!!, request = {
                    withContext(NonCancellable) { reply.await() }
                    "session"
                }) { completed++ }
            }
            job.cancel()
            reply.complete(Unit)
            job.join()
        }
        assertEquals(0, completed)
    }

    @Test fun oldPageCompletionCannotBindAFreshOrReleasedStream() = pages { bridge, first, _ ->
        val previous = bridge.pageUrl()
        bridge.stopJobs()
        assertFalse("A finished old navigation cannot attach the new stream", bridge.acceptPage(first, previous))
        assertTrue(bridge.acceptPage(first, bridge.pageUrl()))
        bridge.alive = false
        bridge.webView = null
        assertFalse("A late page callback cannot resurrect a released view", bridge.acceptPage(first, bridge.pageUrl()))
        assertNull(bridge.webView)
    }
}
