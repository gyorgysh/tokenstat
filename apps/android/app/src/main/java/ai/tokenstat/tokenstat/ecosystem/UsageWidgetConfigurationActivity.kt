// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.widget.*
import androidx.core.content.edit
import ai.tokenstat.tokenstat.R

/** Native launcher configuration, separate from app navigation. */
class UsageWidgetConfigurationActivity : Activity() {
    private var saveState: (() -> Bundle)? = null
    override fun onSaveInstanceState(outState: Bundle) {
        saveState?.invoke()?.let { outState.putBundle("configuration", it) }
        super.onSaveInstanceState(outState)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        val manager = runCatching { AppWidgetManager.getInstance(this) }.getOrNull() ?: run { finish(); return }
        fun ownsWidget() = widgetId != AppWidgetManager.INVALID_APPWIDGET_ID &&
            runCatching { manager.getAppWidgetInfo(widgetId)?.provider }.getOrNull() == ComponentName(this, UsageWidgetProvider::class.java)
        if (!ownsWidget()) { finish(); return }
        val owner = UsageWidgetStore.read(this)?.owner
        val restored = savedInstanceState?.getBundle("configuration")?.takeIf { it.getString("owner") == owner }
        val prefs = getSharedPreferences("usage-widget", MODE_PRIVATE)
        val accent = getColor(R.color.ts_widget_accent)
        val ink = getColor(R.color.ts_widget_text)
        val padding = (24 * resources.displayMetrics.density).toInt()
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(padding, padding, padding, padding)
            setBackgroundColor(getColor(R.color.ts_widget_surface))
        }
        layout.addView(TextView(this).apply { setText(R.string.widget_name); textSize = 24f; setTextColor(ink) })
        val periods = RadioGroup(this)
        fun option(label: Int) = RadioButton(this).apply {
            id = android.view.View.generateViewId(); setText(label); setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent)
        }
        val today = option(R.string.widget_today); val week = option(R.string.widget_week)
        periods.addView(today); periods.addView(week)
        periods.check(if (restored?.getBoolean("week") ?: prefs.getBoolean("week.$widgetId", false)) week.id else today.id)
        layout.addView(periods)
        val charts = CheckBox(this).apply {
            setText(R.string.widget_show_charts); setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent)
            isChecked = restored?.getBoolean("charts") ?: prefs.getBoolean("charts.$widgetId", true)
        }
        layout.addView(charts)
        saveState = { Bundle().apply { putString("owner", owner); putBoolean("week", periods.checkedRadioButtonId == week.id); putBoolean("charts", charts.isChecked) } }
        layout.addView(Button(this).apply {
            setText(R.string.widget_save); backgroundTintList = ColorStateList.valueOf(accent); setTextColor(android.graphics.Color.WHITE)
            setOnClickListener {
                if (!ownsWidget() || UsageWidgetStore.read(this@UsageWidgetConfigurationActivity)?.owner != owner) { finish(); return@setOnClickListener }
                prefs.edit { putBoolean("week.$widgetId", periods.checkedRadioButtonId == week.id); putBoolean("charts.$widgetId", charts.isChecked) }
                UsageWidgetProvider.update(this@UsageWidgetConfigurationActivity, widgetId)
                UsageWidgetProvider.schedule(this@UsageWidgetConfigurationActivity)
                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)); finish()
            }
        })
        setContentView(ScrollView(this).apply { addView(layout) })
    }
}
