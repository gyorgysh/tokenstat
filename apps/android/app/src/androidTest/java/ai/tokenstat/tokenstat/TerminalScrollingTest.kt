// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.os.SystemClock
import android.view.MotionEvent
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONTokener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Owns an isolated terminal surface, with no PTY, account or host transport. */
@RunWith(AndroidJUnit4::class)
class TerminalScrollingTest {
    @Test fun aReloadedPageUsesTheNewBridgeAndStillRendersOutput() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bridge = ai.tokenstat.tokenstat.ui.terminal.TerminalBridge()
        val copies = java.util.concurrent.CopyOnWriteArrayList<String>()
        val loads = java.util.concurrent.atomic.AtomicInteger()
        bridge.onCopy = { copies.add(it) }
        lateinit var web: WebView
        ActivityScenario.launch(MainActivity::class.java).use { activity ->
            activity.onActivity {
                web = WebView(it).apply {
                    settings.javaScriptEnabled = true
                    settings.blockNetworkLoads = true
                    addJavascriptInterface(bridge.jsApi, "TermBridge")
                    webViewClient = object : android.webkit.WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            if (!bridge.acceptPage(view, url)) return
                            bridge.fit()
                            loads.incrementAndGet()
                        }
                    }
                }
                it.setContentView(web)
                web.loadUrl(bridge.pageUrl())
            }
            fun await(message: String, condition: () -> Boolean) {
                val end = SystemClock.uptimeMillis() + 10_000
                while (!condition() && SystemClock.uptimeMillis() < end) SystemClock.sleep(20)
                assertTrue(message, condition())
            }
            fun js(source: String): String {
                val done = CountDownLatch(1)
                var result = ""
                instrumentation.runOnMainSync {
                    web.evaluateJavascript(source) { result = it; done.countDown() }
                }
                assertTrue(done.await(5, TimeUnit.SECONDS))
                return result
            }
            try {
                await("Initial terminal loaded") { loads.get() == 1 }
                js("TermBridge.onCopy('before reload')")
                await("Initial bridge works") { copies.size == 1 }
                instrumentation.runOnMainSync { bridge.stopJobs(); bridge.reloadPage() }
                await("Terminal reloaded") { loads.get() == 2 }
                js("TermBridge.onCopy('after reload')")
                await("Replacement bridge works") { copies.size == 2 }
                instrumentation.runOnMainSync { bridge.writeBase64("Y3VycmVudA0K") }
                await("Replacement page renders current output") {
                    js("term.buffer.active.getLine(0).translateToString(true)") == "\"current\""
                }
                assertEquals(listOf("before reload", "after reload"), copies)
            } finally {
                instrumentation.runOnMainSync { bridge.webView = null; bridge.stopJobs(); web.destroy() }
            }
        }
    }

    @Test fun terminalClipboardCallbackReachesTheOwnerOnMainThread() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val terminal = ai.tokenstat.tokenstat.ui.terminal.TerminalBridge()
        val done = CountDownLatch(1)
        var copied: String? = null
        var wasMain = false
        terminal.onCopy = {
            copied = it
            wasMain = android.os.Looper.myLooper() == android.os.Looper.getMainLooper()
            done.countDown()
        }
        terminal.jsApi.onCopy("terminal selection")
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals("terminal selection", copied)
        assertTrue(wasMain)
    }

    private class Bridge {
        @Volatile var inputCount = 0
        @Volatile var reading = false
        @JavascriptInterface fun onInput(value: String) { inputCount++ }
        @JavascriptInterface fun onResize(rows: Int, cols: Int) {}
        @JavascriptInterface fun onReadingChanged(value: Boolean) { reading = value }
        @JavascriptInterface fun onCopy(value: String) {}
        @JavascriptInterface fun onWantsKeyboard() {}
    }

    @Test fun touchReadingHoldsWhileMouseEnabledAndOutputStreams() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bridge = Bridge()
        lateinit var web: WebView
        ActivityScenario.launch(MainActivity::class.java).use { activity ->
            activity.onActivity {
                web = WebView(it).apply {
                    settings.javaScriptEnabled = true
                    addJavascriptInterface(bridge, "TermBridge")
                }
                it.setContentView(web)
                web.loadUrl("file:///android_asset/term/term.html")
            }
            fun js(source: String): Any? {
                val done = CountDownLatch(1)
                var result: Any? = null
                instrumentation.runOnMainSync {
                    web.evaluateJavascript(source) { value ->
                        result = JSONTokener(value).nextValue()
                        done.countDown()
                    }
                }
                assertTrue("terminal script returned", done.await(5, TimeUnit.SECONDS))
                return result
            }
            fun await(message: String, condition: () -> Boolean) {
                val end = SystemClock.uptimeMillis() + 5_000
                while (!condition() && SystemClock.uptimeMillis() < end) SystemClock.sleep(20)
                assertTrue(message, condition())
            }
            await("terminal loaded") { js("typeof term !== 'undefined' && term.rows > 2") == true }
            js("termWriteB64(btoa(Array.from({length:150},(_,i)=>'row '+i+'\\r\\n').join('')+'\\x1b[?1000h')); termSetScrolls(true);")
            await("output parsed") { (js("term.buffer.active.baseY") as? Number)?.toInt()?.let { it > 10 } == true }
            bridge.inputCount = 0
            instrumentation.runOnMainSync {
                val time = SystemClock.uptimeMillis()
                fun touch(action: Int, y: Float, delay: Long) {
                    MotionEvent.obtain(time, time + delay, action, 80f, y, 0).also {
                        web.dispatchTouchEvent(it)
                        it.recycle()
                    }
                }
                touch(MotionEvent.ACTION_DOWN, 150f, 0)
                for (step in 1..8) touch(MotionEvent.ACTION_MOVE, 150f + 20f * step, step * 20L)
                touch(MotionEvent.ACTION_UP, 310f, 180)
            }
            await("touch scroll enters reading") { bridge.reading }
            val held = js("term.buffer.active.getLine(term.buffer.active.viewportY).translateToString(true)")
            js("termWriteB64(btoa('live update\\r\\n')); ")
            await("live output parsed") { js("term.buffer.active.getLine(term.buffer.active.baseY + term.buffer.active.cursorY - 1).translateToString(true)") == "live update" }
            assertEquals("live output retains the visible line", held, js("term.buffer.active.getLine(term.buffer.active.viewportY).translateToString(true)"))
            assertEquals("reading drag sends no guest mouse/input bytes", 0, bridge.inputCount)
            for ((width, height) in listOf(320 to 400, 400 to 600, 300 to 500)) {
                js("termViewport($width,$height)")
                assertEquals("viewport resize retains the visible line", held, js("term.buffer.active.getLine(term.buffer.active.viewportY).translateToString(true)"))
                js("window.resizeSettled=false;requestAnimationFrame(()=>requestAnimationFrame(()=>resizeSettled=true))")
                await("resize layout settled") { js("resizeSettled") == true }
                assertEquals("later layout keeps the same line", held, js("term.buffer.active.getLine(term.buffer.active.viewportY).translateToString(true)"))
            }
            js("termSetScrolls(false); termWriteB64(btoa('follow update\\r\\n'))")
            await("scroll off follows output") { js("term.buffer.active.viewportY === term.buffer.active.baseY && !scroll.isReading()") == true }
            instrumentation.runOnMainSync { web.destroy() }
        }
    }
}
