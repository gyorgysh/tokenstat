// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.view.ViewGroup
import android.widget.*
import androidx.core.content.edit
import ai.tokenstat.tokenstat.R

/** System widget setup only; does not add another screen to the app navigation. */
class LimitsWidgetConfigurationActivity : Activity() {
    private var saveConfigurationState: (() -> Bundle)? = null
    override fun onSaveInstanceState(outState: Bundle) {
        saveConfigurationState?.invoke()?.let { outState.putBundle("configuration", it) }
        super.onSaveInstanceState(outState)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        setResult(RESULT_CANCELED)
        val manager = runCatching { AppWidgetManager.getInstance(this) }.getOrNull() ?: run { finish(); return }
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID || runCatching { manager.getAppWidgetInfo(id)?.provider }.getOrNull() != ComponentName(this, LimitsWidgetProvider::class.java)) { finish(); return }
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val accent = getColor(R.color.ts_widget_accent)
        val ink = getColor(R.color.ts_widget_text)
        val preferences = LimitsWidgetProvider.preferences(this)
        val snapshot = UsageWidgetStore.read(this)
        val restored = savedInstanceState?.getBundle("configuration")?.takeIf { it.getString("owner") == snapshot?.owner }
        val chosen = restored?.getStringArrayList("providers")?.toSet() ?: preferences.getStringSet("provider.$id", null)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(24), dp(24), dp(24)); setBackgroundColor(getColor(R.color.ts_widget_surface))
        }
        fun label(resource: Int, size: Float = 16f) = TextView(this).apply {
            setText(resource); setTextColor(ink); textSize = size; setPadding(0, dp(12), 0, dp(12))
        }
        val mark = ImageView(this).apply { setImageResource(R.drawable.ic_notification); imageTintList = ColorStateList.valueOf(accent) }
        layout.addView(mark, LinearLayout.LayoutParams(dp(32), dp(32)))
        layout.addView(label(R.string.widget_limits_name, 24f))
        layout.addView(label(R.string.widget_provider_selection))
        val all = CheckBox(this).apply {
            setText(R.string.widget_all_providers); setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent)
            isChecked = restored?.getBoolean("all") ?: (chosen == null)
        }
        layout.addView(all)
        val boxes = snapshot?.limits.orEmpty().sortedBy { it.source }.map { provider ->
            val key = "${snapshot?.owner}\n${provider.source}"
            val box = CheckBox(this).apply {
                text = provider.name; setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent)
                isChecked = chosen?.contains(key) == true; isEnabled = !all.isChecked
            }
            layout.addView(box)
            key to box
        }
        all.setOnCheckedChangeListener { _, checked -> boxes.forEach { it.second.isEnabled = !checked } }
        if (boxes.isEmpty()) layout.addView(label(R.string.widget_limits_empty))
        layout.addView(label(R.string.widget_display))
        val modes = RadioGroup(this)
        val rings = RadioButton(this).apply { this.id = android.view.View.generateViewId(); setText(R.string.widget_circles); setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent) }
        val bars = RadioButton(this).apply { this.id = android.view.View.generateViewId(); setText(R.string.widget_bars_label); setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent) }
        modes.addView(rings); modes.addView(bars)
        modes.check(if ((restored?.getString("style") ?: preferences.getString("style.$id", "rings")) == "bars") bars.id else rings.id)
        layout.addView(modes)
        layout.addView(label(R.string.widget_limit_window))
        val windows = RadioGroup(this)
        val choices = listOf(QuotaWindowSelection.HIGHEST to R.string.widget_window_highest,
            QuotaWindowSelection.FIVE_HOUR to R.string.widget_window_five_hour, QuotaWindowSelection.WEEKLY to R.string.widget_window_weekly,
            QuotaWindowSelection.BOTH to R.string.widget_window_both, QuotaWindowSelection.ALL to R.string.widget_window_all).map { (selection, resource) ->
            val button = RadioButton(this).apply { this.id = android.view.View.generateViewId(); setText(resource); setTextColor(ink); buttonTintList = ColorStateList.valueOf(accent) }
            windows.addView(button); selection to button
        }
        val selection = QuotaWindowSelection.fromKey(restored?.getString("window") ?: preferences.getString("window.$id", "highest"))
        windows.check(choices.first { it.first == selection }.second.id)
        layout.addView(windows)
        saveConfigurationState = { Bundle().apply {
            putString("owner", snapshot?.owner); putBoolean("all", all.isChecked)
            putStringArrayList("providers", ArrayList(boxes.filter { it.second.isChecked }.map { it.first }))
            putString("style", if (modes.checkedRadioButtonId == bars.id) "bars" else "rings")
            putString("window", choices.first { it.second.id == windows.checkedRadioButtonId }.first.key)
        } }
        val save = Button(this).apply {
            setText(R.string.widget_save); backgroundTintList = ColorStateList.valueOf(accent); setTextColor(android.graphics.Color.WHITE)
        }
        layout.addView(save)
        save.setOnClickListener {
            val selected = boxes.filter { it.second.isChecked }.map { it.first }.toSet()
            if (!all.isChecked && selected.isEmpty()) { Toast.makeText(this, R.string.widget_select_provider, Toast.LENGTH_SHORT).show(); return@setOnClickListener }
            // Revalidate both widget ownership and account before persisting a stale setup screen.
            if (runCatching { manager.getAppWidgetInfo(id)?.provider }.getOrNull() != ComponentName(this, LimitsWidgetProvider::class.java)
                || UsageWidgetStore.read(this)?.owner != snapshot?.owner) { finish(); return@setOnClickListener }
            preferences.edit {
                if (all.isChecked) remove("provider.$id") else putStringSet("provider.$id", selected)
                putString("style.$id", if (modes.checkedRadioButtonId == bars.id) "bars" else "rings")
                putString("window.$id", choices.first { it.second.id == windows.checkedRadioButtonId }.first.key)
            }
            UsageWidgetProvider.update(this, id)
            UsageWidgetProvider.schedule(this)
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)); finish()
        }
        val scroll = ScrollView(this).apply { addView(layout, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)) }
        setContentView(scroll)
    }
}
