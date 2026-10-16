// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native, opt-in component benchmark. See benchmark-android-chat-images.sh.
package ai.tokenstat.tokenstat.ui.workspace

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Test

class AndroidChatImages {
    @Test fun measureRepeatedScrollbackDecoding() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val directory = InstrumentationRegistry.getArguments().getString("chatImageBenchmark")
            ?: return@runBlocking
        val files = File(context.filesDir, directory).listFiles()!!.filter { it.isFile }.sortedBy { it.name }.take(4)
        check(files.isNotEmpty())
        val budget = minOf(24L * 1024 * 1024,
            (Runtime.getRuntime().maxMemory() / 16).coerceAtLeast(4L * 1024 * 1024)).toInt()
        var decodes = 0
        var checksum = 0L
        val cache = ChatImageDecodeCache(budget) { file, edge -> decodes++; decodeChatImage(file, edge) }
        fun time(action: () -> Unit): Double {
            val start = SystemClock.elapsedRealtimeNanos()
            action()
            return (SystemClock.elapsedRealtimeNanos() - start) / 1_000_000.0
        }
        val uncached = List(21) {
            time {
                for (file in files) {
                    val bitmap = decodeChatImage(file, CHAT_IMAGE_GALLERY_EDGE)
                    checksum += bitmap.width + bitmap.height
                    bitmap.recycle()
                }
            }
        }.sorted()
        val coldStart = SystemClock.elapsedRealtimeNanos()
        for (file in files) checksum += cache.image(file, CHAT_IMAGE_GALLERY_EDGE)!!.width
        val coldMs = (SystemClock.elapsedRealtimeNanos() - coldStart) / 1_000_000.0
        val reused = List(21) {
            val start = SystemClock.elapsedRealtimeNanos()
            for (file in files) checksum += cache.image(file, CHAT_IMAGE_GALLERY_EDGE)!!.width
            (SystemClock.elapsedRealtimeNanos() - start) / 1_000_000.0
        }.sorted()
        val toolOutput = buildString { repeat(8192) { append("A shell output row with enough text to exercise a retained tool.\n") } }
        val snippet = List(21) {
            time { checksum += ChatToolState.makeSnippet("Shell", toolOutput).sumOf { it.length }.toLong() }
        }.sorted()
        val report = JSONObject().put("measurement", "Native decode throughput; not Compose frame latency")
            .put("images", files.size).put("originalBytes", files.sumOf { it.length() })
            .put("samples", 21).put("edge", CHAT_IMAGE_GALLERY_EDGE).put("budgetBytes", budget)
            .put("uncachedMedianMs", uncached[10]).put("uncachedP95Ms", uncached[19])
            .put("cachedColdMs", coldMs).put("cachedMedianMs", reused[10]).put("cachedP95Ms", reused[19])
            .put("decodeCalls", decodes).put("retainedBytes", cache.retainedBytes).put("checksum", checksum)
            .put("toolOutputBytes", toolOutput.length).put("snippetMedianMs", snippet[10]).put("snippetP95Ms", snippet[19])
        File(context.filesDir, directory).resolve("benchmark.json").writeText(report.toString(2))
        check(cache.retainedBytes <= budget)
        cache.clear()
    }
}
