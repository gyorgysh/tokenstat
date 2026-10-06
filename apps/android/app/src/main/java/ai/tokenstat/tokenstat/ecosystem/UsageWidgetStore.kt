// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.Context
import android.util.AtomicFile
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

object UsageWidgetStore {
    private val session = UsageSession()
    private val json = Json { ignoreUnknownKeys = true }
    private fun file(context: Context) = AtomicFile(context.noBackupFilesDir.resolve("widget-usage.json"))

    @Synchronized fun epoch(): Long = session.epoch
    @Synchronized fun lease(): UsageLease? = session.lease()
    @Synchronized fun read(context: Context): UsageSnapshot? = runCatching {
        file(context).openRead().use {
            val buffer = ByteArray(32 * 1024 + 1)
            var count = 0
            while (count < buffer.size) {
                val read = it.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            require(count <= 32 * 1024)
            json.decodeFromString<UsageSnapshot>(buffer.copyOf(count).toString(Charsets.UTF_8)).takeIf { snapshot -> snapshot.valid }
        }
    }.getOrNull()

    @Synchronized fun verify(context: Context, account: JsonObject, observed: Long, fromApp: Boolean = false): UsageLease? {
        if (session.epoch != observed) return null
        val owner = UsageSnapshot.owner(account)
        val lease = session.verify(owner, observed, fromApp)
        if (lease == null) {
            if (owner == null) { file(context).delete(); UsageWidgetProvider.updateAll(context) }
            return null
        }
        if (read(context)?.owner != owner) write(context, UsageSnapshot(lease.owner))
        return lease
    }

    @Synchronized fun clear(context: Context, block: Boolean = false) {
        session.clear(block)
        file(context).delete()
        UsageWidgetProvider.updateAll(context)
    }

    @Synchronized fun publish(context: Context, lease: UsageLease, calendar: JsonObject?) {
        if (!session.current(lease)) return
        val snapshot = if (calendar == null) UsageSnapshot(lease.owner, System.currentTimeMillis())
            else UsageSnapshot.calendar(lease.owner, calendar) ?: run { failed(context, lease); return }
        val existing = read(context)
        if (existing?.owner == lease.owner && existing.updatedAt != null && snapshot.updatedAt != null
            && snapshot.updatedAt < existing.updatedAt) return
        write(context, snapshot)
    }
    @Synchronized fun failed(context: Context, lease: UsageLease?, observedEpoch: Long? = null) {
        if (observedEpoch != null && observedEpoch != session.epoch) return
        if (lease != null && !session.current(lease) || lease == null && observedEpoch == null) return
        read(context)?.takeIf { lease == null || it.owner == lease.owner }?.let { write(context, it.copy(refreshFailed = true)) }
    }
    private fun write(context: Context, snapshot: UsageSnapshot) {
        val atomic = file(context)
        val output = runCatching { atomic.startWrite() }.getOrNull() ?: return
        try { output.write(json.encodeToString(snapshot).toByteArray()); atomic.finishWrite(output) }
        catch (error: Exception) { atomic.failWrite(output); return }
        UsageWidgetProvider.updateAll(context)
    }
}
