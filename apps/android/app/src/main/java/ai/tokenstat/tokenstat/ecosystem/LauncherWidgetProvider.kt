// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.util.SizeF
import android.widget.RemoteViews
import ai.tokenstat.tokenstat.R

class LauncherWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { update(context, manager, it) } }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { update(context, manager, id) }
    private fun update(context: Context, manager: AppWidgetManager, id: Int) {
        runCatching {
            val views = if (android.os.Build.VERSION.SDK_INT >= 31) RemoteViews(mapOf(
                SizeF(48f, 48f) to render(context, 0), SizeF(110f, 48f) to render(context, 1), SizeF(220f, 130f) to render(context, 2)))
            else {
                val options = manager.getAppWidgetOptions(id)
                render(context, if (options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) >= 130 && options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) >= 220) 2
                    else if (options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) >= 110) 1 else 0)
            }
            manager.updateAppWidget(id, views)
        }.onFailure { Log.w("ts-widget", "Launcher widget unavailable") }
    }
    companion object {
        fun render(context: Context, size: Int): RemoteViews {
            val views = RemoteViews(context.packageName, when (size) { 0 -> R.layout.launcher_widget_icon; 1 -> R.layout.launcher_widget; else -> R.layout.launcher_widget_grid })
            views.setOnClickPendingIntent(R.id.launcher_root, QuickAccess.pendingIntent(context, "workspaces"))
            if (size == 2) {
                views.setOnClickPendingIntent(R.id.launcher_home, QuickAccess.pendingIntent(context, "home"))
                views.setOnClickPendingIntent(R.id.launcher_workspaces, QuickAccess.pendingIntent(context, "workspaces"))
                views.setOnClickPendingIntent(R.id.launcher_insights, QuickAccess.pendingIntent(context, "insights"))
                views.setOnClickPendingIntent(R.id.launcher_devices, QuickAccess.pendingIntent(context, "machines"))
            }
            return views
        }
    }
}
