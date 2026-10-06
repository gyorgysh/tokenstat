// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.LinearGradient
import android.graphics.Shader
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import androidx.work.*
import androidx.core.content.edit
import androidx.core.graphics.createBitmap
import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.core.CoreClient
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

class UsageWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, it) }
        schedule(context)
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        update(context, id)
    }
    override fun onDisabled(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(PERIODIC)
    }
    override fun onDeleted(context: Context, ids: IntArray) {
        prefs(context).edit { ids.forEach { remove("week.$it") } }
    }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action !in setOf(REFRESH, PERIOD)) return
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id !in AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, UsageWidgetProvider::class.java))) return
        if (intent.action == PERIOD) {
            prefs(context).edit { putBoolean("week.$id", !prefs(context).getBoolean("week.$id", false)) }
            update(context, id)
        } else {
            queuedRefresh = true
            updateAll(context)
            WorkManager.getInstance(context).enqueueUniqueWork(REFRESH, ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<UsageWidgetWorker>().build())
        }
    }

    companion object {
        @Volatile private var queuedRefresh = false
        private val activeWorkers = AtomicInteger()
        private val refreshing: Boolean get() = queuedRefresh || activeWorkers.get() > 0
        private const val REFRESH = "ai.tokenstat.tokenstat.WIDGET_REFRESH"
        private const val PERIOD = "ai.tokenstat.tokenstat.WIDGET_PERIOD"
        private const val PERIODIC = "usage-widget-periodic"
        private fun prefs(context: Context) = context.getSharedPreferences("usage-widget", Context.MODE_PRIVATE)
        fun updateAll(context: Context) {
            val ids = AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, UsageWidgetProvider::class.java))
            ids.forEach { update(context, it) }
        }
        private fun schedule(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<UsageWidgetWorker>(1, TimeUnit.HOURS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())
        }
        fun update(context: Context, id: Int) {
            val manager = AppWidgetManager.getInstance(context)
            val week = prefs(context).getBoolean("week.$id", false)
            val snapshot = UsageWidgetStore.read(context)
            val views = if (android.os.Build.VERSION.SDK_INT >= 31) {
                RemoteViews(mapOf(
                    SizeF(160f, 170f) to render(context, id, week, snapshot, false),
                    SizeF(280f, 170f) to render(context, id, week, snapshot, true),
                    SizeF(160f, 280f) to render(context, id, week, snapshot, false, true),
                    SizeF(280f, 280f) to render(context, id, week, snapshot, true, true),
                ))
            } else {
                val options = manager.getAppWidgetOptions(id)
                render(context, id, week, snapshot, options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) >= 280,
                    options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) >= 280)
            }
            manager.updateAppWidget(id, views)
        }

        /** Also used by layout verification: no credentials or network needed. */
        fun render(context: Context, id: Int, week: Boolean, snapshot: UsageSnapshot?, wide: Boolean, tall: Boolean = false): RemoteViews {
            val views = RemoteViews(context.packageName, if (tall) R.layout.usage_widget_tall else R.layout.usage_widget)
            val today = LocalDate.now()
            val value = snapshot?.value(week, today)
            val amount = if (value == null) "—" else money(value)
            views.setTextViewText(R.id.widget_value, amount)
            views.setContentDescription(R.id.widget_value, if (value == null) context.getString(R.string.widget_usage_unavailable)
                else NumberFormat.getNumberInstance().apply { maximumFractionDigits = 2; minimumFractionDigits = 2 }
                    .format(value / 1_000_000.0) + " USD")
            val dateLabel = today.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
            // A launcher may defer its update past midnight. An explicit date
            // keeps the cached number honest until Android refreshes the view.
            views.setTextViewText(R.id.widget_period, if (value == null) context.getString(if (week) R.string.widget_week else R.string.widget_today)
                else if (week) context.getString(R.string.widget_week_short) + " · " + dateLabel else dateLabel)
            views.setTextViewText(R.id.widget_caption, context.getString(if (snapshot == null) R.string.widget_sign_in else R.string.widget_list_rates))
            val age = snapshot?.updatedAt?.let { android.text.format.DateUtils.getRelativeTimeSpanString(it, System.currentTimeMillis(),
                android.text.format.DateUtils.MINUTE_IN_MILLIS).toString() }
            val status = when {
                refreshing -> context.getString(R.string.widget_updating)
                snapshot == null -> context.getString(R.string.widget_open_to_sync)
                snapshot.refreshFailed -> context.getString(R.string.widget_update_failed) + (age?.let { " · $it" } ?: "")
                snapshot.updatedAt == null -> context.getString(R.string.widget_open_to_sync)
                else -> android.text.format.DateUtils.formatDateTime(context, snapshot.updatedAt,
                    android.text.format.DateUtils.FORMAT_SHOW_DATE or android.text.format.DateUtils.FORMAT_SHOW_TIME or android.text.format.DateUtils.FORMAT_ABBREV_MONTH)
            }
            views.setTextViewText(R.id.widget_status, status)
            views.setContentDescription(R.id.widget_status, status)
            views.setViewVisibility(R.id.widget_chart, if ((wide || tall) && snapshot?.updatedAt != null) View.VISIBLE else View.GONE)
            val weekAmount = snapshot?.value(true, today)?.let(::money) ?: "—"
            views.setTextViewText(R.id.widget_week_total, weekAmount.removeSuffix(" USD"))
            views.setContentDescription(R.id.widget_week_total, weekAmount)
            val values = (6 downTo 0).map { offset -> snapshot?.days?.singleOrNull {
                it.date == today.minusDays(offset.toLong()).toString() && !it.locked
            }?.value ?: 0L }
            val max = values.maxOrNull()?.coerceAtLeast(1) ?: 1
            val scale = context.resources.displayMetrics.density
            val chart = createBitmap((280 * scale).toInt().coerceAtLeast(1), (112 * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
            val canvas = Canvas(chart)
            canvas.scale(scale, scale)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val accent = context.getColor(R.color.ts_widget_accent)
            values.forEachIndexed { index, value ->
                val height = (value.toDouble() / max * 104).toFloat().coerceAtLeast(5f)
                paint.color = accent
                paint.alpha = if (index == 6) 255 else 100
                paint.shader = if (index == 6) LinearGradient(0f, 8f, 0f, 112f, context.getColor(R.color.ts_widget_secondary), accent, Shader.TileMode.CLAMP) else null
                canvas.drawRoundRect(index * 40f, 112f - height, index * 40f + 28f, 112f, 4f, 4f, paint)
            }
            views.setImageViewBitmap(R.id.widget_bars, chart)
            views.setBoolean(R.id.widget_refresh, "setEnabled", !refreshing)
            views.setOnClickPendingIntent(R.id.widget_root, QuickAccess.pendingIntent(context, "home"))
            views.setOnClickPendingIntent(R.id.widget_period, broadcast(context, id, PERIOD))
            views.setOnClickPendingIntent(R.id.widget_refresh, broadcast(context, id, REFRESH))
            return views
        }
        fun setRefreshing(context: Context, value: Boolean) {
            if (value) activeWorkers.incrementAndGet() else activeWorkers.decrementAndGet()
            queuedRefresh = false
            updateAll(context)
        }
        private fun broadcast(context: Context, id: Int, action: String): PendingIntent = PendingIntent.getBroadcast(
            context, id, Intent(context, UsageWidgetProvider::class.java).apply {
                this.action = action; putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        private fun money(micros: Long): String {
            val dollars = micros / 1_000_000.0
            val (value, suffix) = when {
                dollars >= 1_000_000_000 -> dollars / 1_000_000_000 to "B"
                dollars >= 1_000_000 -> dollars / 1_000_000 to "M"
                dollars >= 10_000 -> dollars / 1_000 to "K"
                else -> dollars to ""
            }
            return NumberFormat.getNumberInstance().apply { minimumFractionDigits = 2; maximumFractionDigits = 2 }.format(value) + suffix + " USD"
        }
    }
}

class UsageWidgetWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        var lease: UsageLease? = null
        val epoch = UsageWidgetStore.epoch()
        UsageWidgetProvider.setRefreshing(context, true)
        return try {
            val account = CoreClient.call("account.status") as? JsonObject
            if (account == null) {
                UsageWidgetStore.failed(context, null, epoch)
                return Result.failure()
            }
            lease = UsageWidgetStore.verify(context, account, epoch) ?: return Result.success()
            val calendar = CoreClient.call("activity.calendar", buildJsonObject {
                put("weeks", 6); put("scope", "account"); put("force", true)
            })
            if (calendar !is JsonObject && calendar !is JsonNull) {
                UsageWidgetStore.failed(context, lease, epoch)
                return Result.failure()
            }
            UsageWidgetStore.publish(context, lease, calendar as? JsonObject)
            Result.success()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            UsageWidgetStore.failed(context, lease, epoch)
            // A manual refresh reports its failure instead of silently retrying
            // for hours. The periodic task and next tap can try again.
            Result.failure()
        } finally { UsageWidgetProvider.setRefreshing(context, false) }
    }
}
