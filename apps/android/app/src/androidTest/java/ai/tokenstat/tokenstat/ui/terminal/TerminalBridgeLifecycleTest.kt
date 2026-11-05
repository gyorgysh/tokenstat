// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import android.content.Context
import android.webkit.ValueCallback
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlinx.coroutines.channels.Channel

/** Hold the platform queue to reproduce page replacement before posted work runs. */
@RunWith(AndroidJUnit4::class)
class TerminalBridgeLifecycleTest {
    private fun inputs(bridge: TerminalBridge): Channel<String> {
        // This queue feeds both transport pumps; no real shell is opened.
        val field = TerminalBridge::class.java.getDeclaredField("inbound").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        return field.get(bridge) as Channel<String>
    }

    private class Page(context: Context) : WebView(context) {
        val queued = mutableListOf<Runnable>()
        val scripts = mutableListOf<String>()
        val callbacks = mutableListOf<ValueCallback<String>>()
        var hold = false
        override fun post(action: Runnable): Boolean {
            if (!hold) return super.post(action)
            queued.add(action)
            return true
        }
        override fun evaluateJavascript(script: String, callback: ValueCallback<String>?) {
            scripts.add(script)
            callback?.let { callbacks.add(it) }
        }
        fun flush() { queued.toList().also { queued.clear() }.forEach { it.run() } }
    }

    private fun pages(test: (TerminalBridge, Page, Page) -> Unit) {
        val instrument = InstrumentationRegistry.getInstrumentation()
        instrument.runOnMainSync {
            val first = Page(instrument.targetContext)
            val second = Page(instrument.targetContext)
            val bridge = TerminalBridge().also { it.webView = first }
            first.hold = true
            second.hold = true
            try { test(bridge, first, second) }
            finally { bridge.webView = null; bridge.stopJobs(); first.destroy(); second.destroy() }
        }
    }

    @Test fun queuedOutputAndControlsCannotMoveToAnotherPage() = pages { bridge, first, second ->
        bridge.writeBase64("b2xk")
        bridge.pushTheme(true)
        bridge.fit()
        bridge.fitSize(320, 480)
        bridge.followOutput()
        bridge.setScrolls(true)
        bridge.webView = second
        first.flush()
        assertTrue("No old work may reach the replacement page", second.scripts.isEmpty())
        assertTrue("The retired page must not receive it either", first.scripts.isEmpty())
        bridge.writeBase64("bmV3")
        second.flush()
        assertEquals(listOf("termWriteB64(\"bmV3\");"), second.scripts)
    }

    @Test fun stoppingAStreamInvalidatesQueuedWorkEvenWhenTheViewIsReused() = pages { bridge, first, _ ->
        bridge.writeBase64("b2xk")
        bridge.stopJobs()
        first.flush()
        assertTrue("A fresh shell must not receive the previous shell's output", first.scripts.isEmpty())
        bridge.writeBase64("bmV3")
        first.flush()
        assertEquals(listOf("termWriteB64(\"bmV3\");"), first.scripts)
    }

    @Test fun aDelayedFocusResultCannotRaiseTheKeyboardForARetiredPage() = pages { bridge, first, second ->
        val notifications = mutableListOf<Boolean>()
        bridge.onKeyboardChanged = { notifications.add(it) }
        bridge.showKeyboard()
        first.flush()
        assertEquals(1, first.callbacks.size)
        bridge.stopJobs()
        bridge.webView = second
        first.callbacks.single().onReceiveValue("null")
        assertFalse(bridge.keyboardUp)
        assertTrue(notifications.isEmpty())
    }

    @Test fun queuedKeyboardRequestsAreDiscardedAfterRelease() = pages { bridge, first, _ ->
        bridge.showKeyboard()
        bridge.hideKeyboard()
        bridge.webView = null
        bridge.stopJobs()
        first.flush()
        assertTrue(first.scripts.isEmpty())
    }

    @Test fun retiredJavascriptCallbacksCannotChangeTheCurrentScreen() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val copies = mutableListOf<String>()
        val reading = mutableListOf<Boolean>()
        lateinit var bridge: TerminalBridge
        instrument.runOnMainSync {
            bridge = TerminalBridge()
            bridge.onCopy = { copies.add(it) }
            bridge.onReadingChanged = { reading.add(it) }
            val old = bridge.jsApi
            old.onCopy("queued before stopping")
            old.onInput("b2xk")
            old.onResize(20, 80)
            bridge.stopJobs()
            old.onCopy("late old copy")
            old.onReadingChanged(true)
            old.onInput("b2xk")
            old.onResize(10, 40)
            bridge.jsApi.onCopy("current copy")
            bridge.jsApi.onReadingChanged(false)
            bridge.jsApi.onInput("bmV3")
            bridge.jsApi.onResize(30, 100)
        }
        instrument.waitForIdleSync()
        assertEquals(listOf("current copy"), copies)
        assertEquals(listOf(false), reading)
        val input = inputs(bridge)
        assertEquals("bmV3", input.tryReceive().getOrNull())
        assertEquals("__resize__:30:100", input.tryReceive().getOrNull())
        assertTrue(input.tryReceive().isFailure)
    }

    @Test fun anInputBurstUsesTheBoundedTransportQueue() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val bridge = TerminalBridge()
            val api = bridge.jsApi
            repeat(1000) { api.onInput("YWJj") }
            // Admission is bounded even while the UI queue cannot drain.
            // Posting one UI task per key would leave another unbounded queue.
            val input = inputs(bridge)
            var admitted = 0
            while (input.tryReceive().isSuccess) admitted++
            assertEquals(256, admitted)
            bridge.stopJobs()
        }
    }
}
