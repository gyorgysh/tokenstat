// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.os.Build
import android.widget.ScrollView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import ai.tokenstat.tokenstat.R

/** Keep widget setup controls clear of system bars and display cutouts. */
internal fun ScrollView.applyWidgetConfigurationInsets() {
    setBackgroundColor(context.getColor(R.color.ts_widget_surface))
    clipToPadding = false
    // Older releases fit the content to the system windows themselves.
    if (Build.VERSION.SDK_INT >= 35) {
        ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
            val safe = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            insets
        }
    }
}
