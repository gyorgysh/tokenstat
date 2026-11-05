// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import ai.tokenstat.tokenstat.ui.localization.L10n
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Production browser content with real local listeners, no account or paired computer. */
class PortBrowserLifecycleTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private class PageServer(val title: String) : AutoCloseable {
        private val socket = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val url = "http://127.0.0.1:${socket.localPort}/"
        private val worker = Executors.newSingleThreadExecutor()
        init {
            worker.execute {
                while (!socket.isClosed) try {
                    socket.accept().use { client ->
                        client.soTimeout = 5_000
                        val input = client.getInputStream().bufferedReader()
                        while (!input.readLine().isNullOrEmpty()) { }
                        val body = "<!doctype html><title>$title</title><body>$title</body>".toByteArray()
                        client.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray() + body)
                    }
                } catch (_: Exception) { if (socket.isClosed) break }
            }
        }
        override fun close() { socket.close(); worker.shutdownNow() }
    }

    private class Environment : AutoCloseable {
        val pool = BrowserListenerPool()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val servers = CopyOnWriteArrayList<PageServer>()
        val records = CopyOnWriteArrayList<BrowserTarget>()
        val listens = AtomicInteger()
        val retires = AtomicInteger()
        var beforeListen: suspend (BrowserTarget) -> Unit = {}
        suspend fun acquire(target: BrowserTarget, current: () -> Boolean): BrowserListenerPool.Lease? {
            var server: PageServer? = null
            return pool.acquire(
                BrowserListenerPool.Endpoint("fixture", target.host, target.port), "fixture-account", current,
                listen = {
                    beforeListen(target)
                    listens.incrementAndGet()
                    PageServer("Port ${target.port}").also { server = it; servers.add(it) }.url
                }, retire = { server?.close(); retires.incrementAndGet(); Unit })
        }
        fun request(port: Int): BrowserOpenRequest {
            val target = BrowserTarget.port(port)!!
            val lease = runBlocking { acquire(target) { true }!! }
            return BrowserOpenRequest("fixture", "workspace", null, target, lease)
        }
        override fun close() { scope.cancel(); servers.forEach { it.close() } }
    }

    private fun browsers(): List<BrowserWebView> {
        fun collect(view: android.view.View): List<BrowserWebView> = when (view) {
            is BrowserWebView -> listOf(view)
            is android.view.ViewGroup -> (0 until view.childCount).flatMap { collect(view.getChildAt(it)) }
            else -> emptyList()
        }
        var result = emptyList<BrowserWebView>()
        compose.runOnIdle { result = collect(compose.activity.window.decorView) }
        return result
    }

    private fun page(port: Int) {
        compose.waitUntil(15_000) {
            var loaded = false
            val view = browsers().singleOrNull()
            compose.runOnIdle { loaded = view?.title == "Port $port" }
            loaded
        }
    }

    private fun go(url: String) {
        compose.onNode(hasSetTextAction()).performTextReplacement(url)
        compose.onNodeWithText(L10n.text("android.portbrowser.go.6cc8519b")).performClick()
    }

    @Test fun crashRecoveryKeepsTheLastPageAndItsListener() = Environment().use { env ->
        val request = env.request(3000)
        val shown = mutableStateOf(true)
        compose.setContent { MaterialTheme {
            if (shown.value) PortBrowserContent(request, { shown.value = false }, { true }, env::acquire, env.scope, env.records::add, env.pool)
            else Text("Preview closed")
        } }
        page(3000)
        val target = "http://127.0.0.1:3001/details?view=chat#image"
        go(target)
        page(3001)
        val old = browsers().single()
        compose.runOnIdle { old.loadUrl("chrome://crash") }
        compose.waitUntil(10_000) { browsers().isEmpty() }
        compose.onNodeWithText(L10n.text("android.portbrowser.reload.bdc090ec")).performClick()
        page(3001)
        compose.onNode(hasSetTextAction()).assertTextContains(target)
        assertEquals("Recovery reuses the current listener", 2, env.listens.get())
        assertTrue(browsers().single() !== old)
        compose.onNodeWithText(L10n.text("common.done")).performClick()
        compose.waitUntil(10_000) { env.retires.get() == 2 }
    }

    @Test fun aReplacedRequestGetsANewViewAndRejectsOldErrors() = Environment().use { env ->
        val request = mutableStateOf(env.request(3000))
        val next = env.request(3002)
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        env.beforeListen = { target ->
            if (target.port == 3001) { started.complete(Unit); finish.await(); throw java.io.IOException("Retired navigation") }
        }
        compose.setContent { MaterialTheme {
            PortBrowserContent(request.value, {}, { true }, env::acquire, env.scope, env.records::add, env.pool)
        } }
        page(3000)
        val old = browsers().single()
        go(BrowserTarget.port(3001)!!.url)
        compose.waitUntil(5_000) { started.isCompleted }
        compose.runOnIdle { request.value = next }
        page(3002)
        finish.complete(Unit)
        compose.waitUntil(10_000) { env.retires.get() >= 2 }
        compose.onNodeWithText("Retired navigation").assertDoesNotExist()
        assertTrue(browsers().single() !== old)
    }

    @Test fun aPendingNavigationCannotReplaceThePageRecoveredAfterACrash() = Environment().use { env ->
        val request = env.request(3000)
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        env.beforeListen = { target -> if (target.port == 3001) { started.complete(Unit); finish.await() } }
        compose.setContent { MaterialTheme {
            PortBrowserContent(request, {}, { true }, env::acquire, env.scope, env.records::add, env.pool)
        } }
        page(3000)
        go(BrowserTarget.port(3001)!!.url)
        compose.waitUntil(5_000) { started.isCompleted }
        val old = browsers().single()
        compose.runOnIdle { old.loadUrl("chrome://crash") }
        compose.waitUntil(10_000) { browsers().isEmpty() }
        compose.onNodeWithText(L10n.text("android.portbrowser.reload.bdc090ec")).performClick()
        finish.complete(Unit)
        page(3000)
        assertFalse("The retired navigation must not publish or record a page", env.records.any { it.port == 3001 })
    }

    @Test fun ownershipRevocationBlocksTheExistingViewsRequestsAndCallbacks() = Environment().use { env ->
        val request = env.request(3000)
        val current = mutableStateOf(true)
        compose.setContent { MaterialTheme {
            val owned = current.value
            PortBrowserContent(request, {}, { owned }, env::acquire, env.scope, env.records::add, env.pool)
        } }
        page(3000)
        val old = browsers().single()
        val records = env.records.toList()
        compose.runOnIdle { current.value = false }
        compose.waitForIdle()
        compose.runOnIdle { old.loadUrl(BrowserTarget.port(3001)!!.url) }
        compose.waitUntil(10_000) {
            val value = java.util.concurrent.atomic.AtomicReference("")
            val done = java.util.concurrent.CountDownLatch(1)
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().runOnMainSync {
                old.evaluateJavascript("document.body?.innerText") {
                    value.set(org.json.JSONTokener(it).nextValue().toString())
                    done.countDown()
                }
            }
            assertTrue(done.await(5, java.util.concurrent.TimeUnit.SECONDS))
            value.get().contains(L10n.text("android.portbrowser.open_this_preview_s_port_before_loading_th.4a4d565e"))
        }
        assertEquals(1, env.listens.get())
        assertEquals(records, env.records.toList())
    }
}
