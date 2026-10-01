// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import ai.tokenstat.tokenstat.R

/// The ongoing "watching" notice posted while the screen viewer is up.
///
/// A screen session keeps flowing while the phone sits in a pocket, and the
/// relay meters it. Saying so on screen is the honest counterpart of the
/// Apple viewer's keep-awake picture: this device is spending something.
/// Dismissed when the viewer closes. If notifications are not granted the
/// post is skipped rather than requested; viewing never depends on it.
object ScreenViewing {
    private const val CHANNEL = "screen-viewing"
    private const val ID = 41

    fun show(context: Context, hostLabel: String) {
        if (ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, L10n.text("android.screenviewing.screen_viewing.8cc15f2a"), NotificationManager.IMPORTANCE_LOW)
        )
        manager.notify(
            ID,
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(L10n.text("android.screenviewing.watching_0.816f94dd", "${hostLabel}"))
                .setContentText(L10n.text("android.screenviewing.the_screen_session_is_live_and_using_data.5f595ae6"))
                .setOngoing(true)
                .build(),
        )
    }

    fun hide(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(ID)
    }
}
