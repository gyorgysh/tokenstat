// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import ai.tokenstat.tokenstat.MainActivity
import android.os.SystemClock
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BrowserNavigationHistoryTest {
    private class PageServer(val label: String) : AutoCloseable {
        private val socket = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val url = "http://127.0.0.1:${socket.localPort}/"
        private val worker = Executors.newSingleThreadExecutor()
        init {
            worker.execute {
                while (!socket.isClosed) {
                    try {
                        socket.accept().use { client ->
                            client.soTimeout = 5_000
                            val reader = client.getInputStream().bufferedReader()
                            while (!reader.readLine().isNullOrEmpty()) { /* Request headers. */ }
                            val body = "<!doctype html><title>$label</title><body>$label</body>".toByteArray()
                            client.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" +
                                "Content-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray() + body)
                        }
                    } catch (_: Exception) { if (socket.isClosed) break }
                }
            }
        }
        override fun close() { socket.close(); worker.shutdownNow() }
    }

    @Test fun backToRetiredProxyReplacesTheEntryInsteadOfAddingAnotherPage() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName,
                android.Manifest.permission.POST_NOTIFICATIONS)
        }
        val pool = BrowserListenerPool()
        val servers = mutableListOf<PageServer>()
        val first = BrowserTarget.port(3000)!!
        fun endpoint(target: BrowserTarget) = BrowserListenerPool.Endpoint("peer", target.host, target.port)
        suspend fun acquire(target: BrowserTarget, current: () -> Boolean): BrowserListenerPool.Lease? {
            val server = PageServer(if (target.port == 3000) "A" else "B").also { servers.add(it) }
            return pool.acquire(endpoint(target), "account", current, { server.url }, { server.close() })
        }
        val initial = runBlocking { acquire(first) { true }!! }
        val session = BrowserListenerSession(first, initial, { true }, ::acquire, pool)
        lateinit var web: WebView
        val initialLoad = CountDownLatch(1)
        try {
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                activity.onActivity {
                    web = WebView(it).apply {
                        settings.javaScriptEnabled = true
                        webViewClient = object : WebViewClient() {
                            override fun onPageFinished(view: WebView?, url: String?) { initialLoad.countDown() }
                            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean =
                                session.route(request?.url?.toString(), request?.isForMainFrame == true, request?.method) == BrowserListenerSession.Route.Block
                            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                                val url = request?.url?.toString()
                                return if (session.route(url, request?.isForMainFrame == true, request?.method) == BrowserListenerSession.Route.Open)
                                    session.replayResponse(session.original(url)!!) else null
                            }
                        }
                    }
                    it.setContentView(web)
                    web.loadUrl(first.through(initial.listenerUrl)!!)
                }
                assertTrue("First page loaded", initialLoad.await(15, TimeUnit.SECONDS))
                fun awaitPage(label: String) {
                    val until = SystemClock.uptimeMillis() + 10_000
                    var loaded = false
                    do {
                        instrumentation.runOnMainSync { loaded = web.title == label && session.isCurrentProxy(web.url) }
                        if (loaded) break
                        SystemClock.sleep(25)
                    } while (SystemClock.uptimeMillis() < until)
                    assertTrue("Page $label uses its live listener", loaded)
                }
                awaitPage("A")
                instrumentation.runOnMainSync { web.loadUrl(BrowserTarget.port(3001)!!.url) }
                awaitPage("B")
                instrumentation.runOnMainSync { assertTrue(web.canGoBack()); web.goBack() }
                awaitPage("A")
                instrumentation.runOnMainSync {
                    assertEquals(0, web.copyBackForwardList().currentIndex)
                    assertFalse("Back must now leave the first page", web.canGoBack())
                    assertTrue("Back must reacquire the first listener", session.isCurrentProxy(web.url))
                    web.destroy()
                }
            }
        } finally {
            runBlocking { session.close() }
            servers.forEach { it.close() }
        }
    }
}
