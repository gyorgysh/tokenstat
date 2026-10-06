// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.Context
import android.util.AtomicFile
import androidx.core.content.edit
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

object UsageWidgetStore {
    private val session = UsageSession()
    private val json = Json { ignoreUnknownKeys = true }
    private fun file(context: Context) = AtomicFile(context.noBackupFilesDir.resolve("widget-usage.json"))
    private fun privacy(context: Context) = context.getSharedPreferences("widget-account-privacy", Context.MODE_PRIVATE)
    private fun blocked(context: Context) = privacy(context).getBoolean("blocked", false)

    @Synchronized fun epoch(): Long = session.epoch
    @Synchronized fun lease(): UsageLease? = session.lease()
    @Synchronized fun read(context: Context): UsageSnapshot? = runCatching {
        file(context).openRead().use {
            val buffer = ByteArray(128 * 1024 + 1)
            var count = 0
            while (count < buffer.size) {
                val read = it.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            require(count <= 128 * 1024)
            json.decodeFromString<UsageSnapshot>(buffer.copyOf(count).toString(Charsets.UTF_8)).takeIf { snapshot ->
                snapshot.valid && !blocked(context) && session.acceptsCachedOwner(snapshot.owner)
            }
        }
    }.getOrNull()

    @Synchronized fun verify(context: Context, account: JsonObject, observed: Long, fromApp: Boolean = false): UsageLease? {
        if (session.epoch != observed || blocked(context) && !fromApp) return null
        val owner = UsageSnapshot.owner(account)
        val lease = session.verify(owner, observed, fromApp)
        if (lease == null) {
            if (owner == null) { file(context).delete(); UsageWidgetProvider.updateAll(context) }
            return null
        }
        if (fromApp) privacy(context).edit(commit = true) { putBoolean("blocked", false) }
        if (read(context)?.owner != owner) {
            // Delete before replacing: a full disk or interrupted write must
            // never restore another account's aggregates from AtomicFile.
            file(context).delete()
            if (!write(context, UsageSnapshot(lease.owner))) UsageWidgetProvider.updateAll(context)
        }
        return lease
    }

    /** A verified signed-out response is an account answer, even though it has no usage lease. */
    @Synchronized fun verifyForeground(context: Context, account: JsonObject, observed: Long): Boolean {
        if (session.epoch != observed) return false
        val lease = verify(context, account, observed, fromApp = true)
        return lease != null || (account["signedIn"] as? JsonPrimitive)?.booleanOrNull == false
    }

    @Synchronized fun clear(context: Context, block: Boolean = false) {
        session.clear(block)
        // A background worker can start in a new process while logout is
        // still pending. Keep sign-out's privacy boundary across that restart.
        privacy(context).edit(commit = true) { putBoolean("blocked", block) }
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
        write(context, snapshot.copy(limits = existing?.limits.orEmpty()))
    }
    @Synchronized fun publishLimits(context: Context, lease: UsageLease, readings: kotlinx.serialization.json.JsonElement) {
        if (!session.current(lease)) return
        val providers = QuotaProvider.parse(readings) ?: run { failedLimits(context, lease); return }
        val snapshot = read(context)?.takeIf { it.owner == lease.owner } ?: return
        val previous = snapshot.limits.associateBy { it.source }
        write(context, snapshot.copy(limits = providers.map { provider ->
            previous[provider.source]?.takeIf { it.observedAt > provider.observedAt } ?: provider
        }))
    }
    @Synchronized fun failedLimits(context: Context, lease: UsageLease) {
        if (!session.current(lease)) return
        read(context)?.takeIf { it.owner == lease.owner }?.let { snapshot ->
            write(context, snapshot.copy(limits = snapshot.limits.map { it.copy(stale = true) }))
        }
    }
    @Synchronized fun failed(context: Context, lease: UsageLease?, observedEpoch: Long? = null) {
        if (observedEpoch != null && observedEpoch != session.epoch) return
        if (lease != null && !session.current(lease) || lease == null && observedEpoch == null) return
        read(context)?.takeIf { lease == null || it.owner == lease.owner }?.let { write(context, it.copy(refreshFailed = true)) }
    }
    private fun write(context: Context, snapshot: UsageSnapshot): Boolean {
        val encoded = json.encodeToString(snapshot).toByteArray()
        if (!snapshot.valid || encoded.size > 128 * 1024) return false
        val atomic = file(context)
        val output = runCatching { atomic.startWrite() }.getOrNull() ?: return false
        try { output.write(encoded); atomic.finishWrite(output) }
        catch (error: Exception) { atomic.failWrite(output); return false }
        UsageWidgetProvider.updateAll(context)
        return true
    }
}
